#include "pulsar/camera/CameraDevice.hpp"

#include "DxImageProc.h"
#include "pulsar/camera/JpegEncoder.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <iostream>
#include <memory>
#include <mutex>
#include <thread>

namespace pulsar::camera {
namespace {

std::mutex gSdkMutex;

bool available(GX_PORT_HANDLE port, const char* node) {
  GX_NODE_ACCESS_MODE mode = GX_NODE_ACCESS_MODE_NI;
  if (GXGetNodeAccessMode(port, node, &mode) != GX_STATUS_SUCCESS) return false;
  return mode == GX_NODE_ACCESS_MODE_RO || mode == GX_NODE_ACCESS_MODE_WO || mode == GX_NODE_ACCESS_MODE_RW;
}

bool setEnum(GX_PORT_HANDLE port, const char* node, const char* value) {
  return available(port, node) && GXSetEnumValueByString(port, node, value) == GX_STATUS_SUCCESS;
}

bool setBool(GX_PORT_HANDLE port, const char* node, bool value) {
  return available(port, node) && GXSetBoolValue(port, node, value) == GX_STATUS_SUCCESS;
}

bool setFloat(GX_PORT_HANDLE port, const char* node, double value) {
  if (!available(port, node)) return false;
  GX_FLOAT_VALUE range{};
  if (GXGetFloatValue(port, node, &range) != GX_STATUS_SUCCESS) return false;
  return GXSetFloatValue(port, node, std::clamp(value, range.dMin, range.dMax)) == GX_STATUS_SUCCESS;
}

bool setInt(GX_PORT_HANDLE port, const char* node, int64_t value) {
  if (!available(port, node)) return false;
  GX_INT_VALUE range{};
  if (GXGetIntValue(port, node, &range) != GX_STATUS_SUCCESS) return false;
  int64_t clamped = std::clamp(value, range.nMin, range.nMax);
  if (range.nInc > 1) clamped = range.nMin + ((clamped - range.nMin) / range.nInc) * range.nInc;
  return GXSetIntValue(port, node, clamped) == GX_STATUS_SUCCESS;
}

std::string getString(GX_DEV_HANDLE device, const char* node) {
  GX_STRING_VALUE value{};
  return GXGetStringValue(device, node, &value) == GX_STATUS_SUCCESS ? value.strCurValue : std::string{};
}

bool bayer8(uint64_t f) {
  return f == GX_PIXEL_FORMAT_BAYER_GR8 || f == GX_PIXEL_FORMAT_BAYER_RG8 ||
         f == GX_PIXEL_FORMAT_BAYER_GB8 || f == GX_PIXEL_FORMAT_BAYER_BG8;
}

bool bayer16(uint64_t f) {
  return f == GX_PIXEL_FORMAT_BAYER_GR10 || f == GX_PIXEL_FORMAT_BAYER_RG10 ||
         f == GX_PIXEL_FORMAT_BAYER_GB10 || f == GX_PIXEL_FORMAT_BAYER_BG10 ||
         f == GX_PIXEL_FORMAT_BAYER_GR12 || f == GX_PIXEL_FORMAT_BAYER_RG12 ||
         f == GX_PIXEL_FORMAT_BAYER_GB12 || f == GX_PIXEL_FORMAT_BAYER_BG12 ||
         f == GX_PIXEL_FORMAT_BAYER_GR14 || f == GX_PIXEL_FORMAT_BAYER_RG14 ||
         f == GX_PIXEL_FORMAT_BAYER_GB14 || f == GX_PIXEL_FORMAT_BAYER_BG14 ||
         f == GX_PIXEL_FORMAT_BAYER_GR16 || f == GX_PIXEL_FORMAT_BAYER_RG16 ||
         f == GX_PIXEL_FORMAT_BAYER_GB16 || f == GX_PIXEL_FORMAT_BAYER_BG16;
}

DX_PIXEL_COLOR_FILTER filterFor(uint64_t format, int64_t cameraFilter) {
  if (cameraFilter != GX_COLOR_FILTER_NONE) return static_cast<DX_PIXEL_COLOR_FILTER>(cameraFilter);
  switch (format) {
    case GX_PIXEL_FORMAT_BAYER_RG8: case GX_PIXEL_FORMAT_BAYER_RG10:
    case GX_PIXEL_FORMAT_BAYER_RG12: case GX_PIXEL_FORMAT_BAYER_RG14:
    case GX_PIXEL_FORMAT_BAYER_RG16: return BAYERRG;
    case GX_PIXEL_FORMAT_BAYER_GB8: case GX_PIXEL_FORMAT_BAYER_GB10:
    case GX_PIXEL_FORMAT_BAYER_GB12: case GX_PIXEL_FORMAT_BAYER_GB14:
    case GX_PIXEL_FORMAT_BAYER_GB16: return BAYERGB;
    case GX_PIXEL_FORMAT_BAYER_BG8: case GX_PIXEL_FORMAT_BAYER_BG10:
    case GX_PIXEL_FORMAT_BAYER_BG12: case GX_PIXEL_FORMAT_BAYER_BG14:
    case GX_PIXEL_FORMAT_BAYER_BG16: return BAYERBG;
    default: return BAYERGR;
  }
}

DX_VALID_BIT validBits(uint64_t format) {
  switch (format) {
    case GX_PIXEL_FORMAT_BAYER_GR12: case GX_PIXEL_FORMAT_BAYER_RG12:
    case GX_PIXEL_FORMAT_BAYER_GB12: case GX_PIXEL_FORMAT_BAYER_BG12: return DX_BIT_4_11;
    case GX_PIXEL_FORMAT_BAYER_GR14: case GX_PIXEL_FORMAT_BAYER_RG14:
    case GX_PIXEL_FORMAT_BAYER_GB14: case GX_PIXEL_FORMAT_BAYER_BG14: return DX_BIT_6_13;
    case GX_PIXEL_FORMAT_BAYER_GR16: case GX_PIXEL_FORMAT_BAYER_RG16:
    case GX_PIXEL_FORMAT_BAYER_GB16: case GX_PIXEL_FORMAT_BAYER_BG16: return DX_BIT_8_15;
    default: return DX_BIT_2_9;
  }
}

uint64_t nowNs() {
  return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(
      std::chrono::steady_clock::now().time_since_epoch()).count());
}

bool controlsEqual(const core::CameraControls& a, const core::CameraControls& b) {
  return a.brightness == b.brightness && a.autoExposure == b.autoExposure &&
         std::abs(a.exposureUs - b.exposureUs) < 0.1 && std::abs(a.gainDb - b.gainDb) < 0.01 &&
         a.whiteBalance == b.whiteBalance && a.enhance == b.enhance;
}

}  // namespace

GalaxyRuntime::GalaxyRuntime(bool enabled) {
  if (!enabled) return;
  std::lock_guard<std::mutex> lock(gSdkMutex);
  if (GXInitLib() != GX_STATUS_SUCCESS) return;
  initialized_ = true;
  if (GXUpdateAllDeviceList(&deviceCount_, 1000) != GX_STATUS_SUCCESS) deviceCount_ = 0;
}

GalaxyRuntime::~GalaxyRuntime() {
  if (!initialized_) return;
  std::lock_guard<std::mutex> lock(gSdkMutex);
  GXCloseLib();
}

CameraDevice::CameraDevice(uint32_t slot, uint32_t sdkIndex, std::string serialSelector,
                           std::string label, bool mockMode, uint32_t maxWidth, uint32_t maxHeight,
                           int targetFps, int previewFps, int jpegQuality,
                           ControlProvider controls)
    : slot_(slot), sdkIndex_(sdkIndex), serialSelector_(std::move(serialSelector)),
      label_(std::move(label)), mockMode_(mockMode),
      maxWidth_(maxWidth), maxHeight_(maxHeight), targetFps_(targetFps),
      previewFps_(previewFps), jpegQuality_(jpegQuality), controls_(std::move(controls)) {
  status_.slot = slot_;
  status_.label = label_;
}

CameraDevice::~CameraDevice() { stop(); }

void CameraDevice::start() {
  if (running_.exchange(true)) return;
  worker_ = std::thread(&CameraDevice::loop, this);
}

void CameraDevice::stop() {
  running_ = false;
  if (worker_.joinable()) worker_.join();
  close();
  std::lock_guard<std::mutex> lock(mutex_);
  status_.online = false;
}

CameraStatus CameraDevice::snapshot() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return status_;
}

bool CameraDevice::waitForFrame(uint64_t previousId, CameraStatus& out, int timeoutMs) const {
  std::unique_lock<std::mutex> lock(mutex_);
  frameCv_.wait_for(lock, std::chrono::milliseconds(timeoutMs), [&] {
    return !running_ || (status_.frame && status_.frame->id != previousId);
  });
  out = status_;
  return out.frame && out.frame->id != previousId;
}

void CameraDevice::loop() {
  if (mockMode_) {
    mockLoop();
    return;
  }

  PGX_FRAME_BUFFER buffer = nullptr;
  uint64_t frames = 0;
  auto fpsStart = std::chrono::steady_clock::now();
  while (running_) {
    if (device_ == nullptr && !connect()) {
      std::this_thread::sleep_for(std::chrono::milliseconds(700));
      continue;
    }
    const auto desired = controls_();
    applyControls(desired, false);

    const GX_STATUS status = GXDQBuf(device_, &buffer, 1000);
    if (status != GX_STATUS_SUCCESS || buffer == nullptr) {
      fail(status == GX_STATUS_TIMEOUT ? "camera timeout; reconnecting" : "camera read failed; reconnecting");
      close();
      std::this_thread::sleep_for(std::chrono::milliseconds(250));
      continue;
    }
    if (buffer->nStatus == GX_FRAME_STATUS_SUCCESS && convert(buffer, rgb_)) {
      publish(buffer->nWidth, buffer->nHeight, rgb_, true);
      ++frames;
    }
    GXQBuf(device_, buffer);
    buffer = nullptr;

    const auto now = std::chrono::steady_clock::now();
    const std::chrono::duration<double> elapsed = now - fpsStart;
    if (elapsed.count() >= 1.0) {
      std::lock_guard<std::mutex> lock(mutex_);
      status_.fps = static_cast<double>(frames) / elapsed.count();
      frames = 0;
      fpsStart = now;
    }
  }
}

void CameraDevice::mockLoop() {
  const uint32_t width = std::min<uint32_t>(maxWidth_, 960);
  const uint32_t height = std::min<uint32_t>(maxHeight_, 540);
  std::vector<uint8_t> rgb(static_cast<size_t>(width) * height * 3u);
  uint64_t tick = 0;
  const auto interval = std::chrono::microseconds(1000000 / std::max(targetFps_, 1));
  auto next = std::chrono::steady_clock::now();
  while (running_) {
    const auto control = controls_();
    for (uint32_t y = 0; y < height; ++y) {
      for (uint32_t x = 0; x < width; ++x) {
        const size_t p = (static_cast<size_t>(y) * width + x) * 3u;
        const double nx = static_cast<double>(x) / width;
        const double ny = static_cast<double>(y) / height;
        const double phase = static_cast<double>(tick % 1000000u) * 0.035;
        const uint8_t wave = static_cast<uint8_t>(35.0 * (1.0 + std::sin(nx * 17.0 + ny * 8.0 + phase)));
        const int base = std::clamp(control.brightness * 2, 15, 210);
        if (slot_ == 0) {
          rgb[p] = static_cast<uint8_t>(std::clamp(base + static_cast<int>(wave), 0, 255));
          rgb[p + 1u] = static_cast<uint8_t>(std::clamp(35 + static_cast<int>(ny * 120), 0, 255));
          rgb[p + 2u] = static_cast<uint8_t>(std::clamp(55 + static_cast<int>(nx * 80), 0, 255));
        } else {
          rgb[p] = static_cast<uint8_t>(std::clamp(45 + static_cast<int>(ny * 90), 0, 255));
          rgb[p + 1u] = static_cast<uint8_t>(std::clamp(base + static_cast<int>(wave), 0, 255));
          rgb[p + 2u] = static_cast<uint8_t>(std::clamp(65 + static_cast<int>(nx * 100), 0, 255));
        }
        if ((x + tick * 3u) % 240u < 3u || (y + tick) % 180u < 3u) {
          rgb[p] = rgb[p + 1u] = rgb[p + 2u] = 225;
        }
      }
    }
    publish(width, height, rgb, true);
    {
      std::lock_guard<std::mutex> lock(mutex_);
      status_.model = "Pulsar Mock Camera";
      status_.serial = slot_ == 0 ? "MOCK-LEFT" : "MOCK-RIGHT";
      status_.fps = targetFps_;
    }
    ++tick;
    next += interval;
    std::this_thread::sleep_until(next);
  }
}

bool CameraDevice::connect() {
  close();
  std::lock_guard<std::mutex> sdkLock(gSdkMutex);
  uint32_t count = 0;
  if (GXUpdateAllDeviceList(&count, 500) != GX_STATUS_SUCCESS || count == 0 ||
      (serialSelector_.empty() && count < sdkIndex_)) {
    fail("camera not found by Galaxy SDK");
    return false;
  }
  std::string selector = serialSelector_.empty() ? std::to_string(sdkIndex_) : serialSelector_;
  GX_OPEN_PARAM open{};
  open.pszContent = selector.data();
  open.openMode = serialSelector_.empty() ? GX_OPEN_INDEX : GX_OPEN_SN;
  open.accessMode = GX_ACCESS_EXCLUSIVE;
  if (GXOpenDevice(&open, &device_) != GX_STATUS_SUCCESS) {
    device_ = nullptr;
    fail("GXOpenDevice failed");
    return false;
  }
  if (!configure() || GXStreamOn(device_) != GX_STATUS_SUCCESS) {
    fail("camera configuration or stream start failed");
    if (device_ != nullptr) GXCloseDevice(device_);
    device_ = nullptr;
    return false;
  }
  {
    std::lock_guard<std::mutex> lock(mutex_);
    status_.model = getString(device_, "DeviceModelName");
    status_.serial = getString(device_, "DeviceSerialNumber");
    status_.error.clear();
  }
  return true;
}

bool CameraDevice::configure() {
  if (available(device_, "PixelColorFilter")) {
    GX_ENUM_VALUE value{};
    if (GXGetEnumValue(device_, "PixelColorFilter", &value) == GX_STATUS_SUCCESS) {
      colorFilter_ = value.stCurValue.nCurValue;
    }
  }
  setEnum(device_, "AcquisitionMode", "Continuous");
  setEnum(device_, "TriggerMode", "Off");
  GXSetAcqusitionBufferNumber(device_, 5);
  setInt(device_, "BinningHorizontal", 1);
  setInt(device_, "BinningVertical", 1);
  setEnum(device_, "AcquisitionFrameRateMode", "On");
  setFloat(device_, "AcquisitionFrameRate", targetFps_);
  setInt(device_, "StreamTransferSize", 64 * 1024);
  setInt(device_, "StreamTransferNumberUrb", 64);
  setBool(device_, "FrameStoreCoverActive", true);
  setEnum(device_, "CoverFrameStoreMode", "On");
  applyControls(controls_(), true);
  return true;
}

void CameraDevice::close() {
  std::lock_guard<std::mutex> sdkLock(gSdkMutex);
  if (device_ != nullptr) {
    GXStreamOff(device_);
    GXCloseDevice(device_);
    device_ = nullptr;
  }
  controlsApplied_ = false;
}

void CameraDevice::applyControls(const core::CameraControls& controls, bool force) {
  if (device_ == nullptr || (!force && controlsApplied_ && controlsEqual(controls, appliedControls_))) return;
  setEnum(device_, "ExposureMode", "Timed");
  if (controls.autoExposure) {
    setEnum(device_, "ExposureAuto", "Continuous");
    setEnum(device_, "GainAuto", "Continuous");
    setInt(device_, "ExpectedGrayValue", 32 + controls.brightness * 2);
  } else {
    setEnum(device_, "ExposureAuto", "Off");
    setEnum(device_, "GainAuto", "Off");
    setFloat(device_, "ExposureTime", controls.exposureUs);
    setFloat(device_, "Gain", controls.gainDb);
  }
  setEnum(device_, "BalanceWhiteAuto", controls.whiteBalance == "Auto" ? "Continuous" : "Off");
  setBool(device_, "GammaEnable", true);
  setEnum(device_, "GammaMode", "User");
  setFloat(device_, "Gamma", controls.enhance == "High" ? 0.78 : controls.enhance == "Low" ? 1.05 : 0.92);
  setEnum(device_, "SharpnessMode", "On");
  setFloat(device_, "Sharpness", controls.enhance == "High" ? 1.6 : controls.enhance == "Low" ? 0.8 : 1.15);
  appliedControls_ = controls;
  controlsApplied_ = true;
}

bool CameraDevice::convert(PGX_FRAME_BUFFER frame, std::vector<uint8_t>& rgb) {
  const uint32_t width = frame->nWidth;
  const uint32_t height = frame->nHeight;
  const size_t pixels = static_cast<size_t>(width) * height;
  const uint64_t format = frame->nPixelFormat;
  const auto* src = static_cast<const uint8_t*>(frame->pImgBuf);
  rgb.resize(pixels * 3u);
  if (format == GX_PIXEL_FORMAT_MONO8) {
    for (size_t i = 0; i < pixels; ++i) rgb[i * 3u] = rgb[i * 3u + 1u] = rgb[i * 3u + 2u] = src[i];
    return true;
  }
  if (format == GX_PIXEL_FORMAT_RGB8) {
    std::memcpy(rgb.data(), src, rgb.size());
    return true;
  }
  if (format == GX_PIXEL_FORMAT_BGR8) {
    for (size_t i = 0; i < pixels; ++i) {
      rgb[i * 3u] = src[i * 3u + 2u]; rgb[i * 3u + 1u] = src[i * 3u + 1u]; rgb[i * 3u + 2u] = src[i * 3u];
    }
    return true;
  }
  if (bayer8(format)) {
    return DxRaw8toRGB24(frame->pImgBuf, rgb.data(), width, height, RAW2RGB_ADAPTIVE,
                         filterFor(format, colorFilter_), false) == DX_OK;
  }
  if (bayer16(format)) {
    raw8_.resize(pixels);
    if (DxRaw16toRaw8(frame->pImgBuf, raw8_.data(), width, height, validBits(format)) != DX_OK) return false;
    return DxRaw8toRGB24(raw8_.data(), rgb.data(), width, height, RAW2RGB_ADAPTIVE,
                         filterFor(format, colorFilter_), false) == DX_OK;
  }
  fail("unsupported camera pixel format");
  return false;
}

void CameraDevice::publish(uint32_t width, uint32_t height, const std::vector<uint8_t>& rgb, bool online) {
  const double scale = std::min({1.0, static_cast<double>(maxWidth_) / width, static_cast<double>(maxHeight_) / height});
  const uint32_t outWidth = std::max<uint32_t>(1, static_cast<uint32_t>(width * scale));
  const uint32_t outHeight = std::max<uint32_t>(1, static_cast<uint32_t>(height * scale));
  const uint8_t* data = rgb.data();
  if (outWidth != width || outHeight != height) {
    resizeRgbBilinearInto(rgb.data(), width, height, outWidth, outHeight, resized_);
    data = resized_.data();
  }
  auto rgbCopy = std::make_shared<std::vector<uint8_t>>(data, data + static_cast<size_t>(outWidth) * outHeight * 3u);
  const auto now = std::chrono::steady_clock::now();
  if (!lastJpeg_ || now >= nextPreview_) {
    lastJpeg_ = std::make_shared<std::vector<uint8_t>>(encodeJpeg(rgbCopy->data(), outWidth, outHeight, jpegQuality_));
    nextPreview_ = now + std::chrono::milliseconds(1000 / std::max(previewFps_, 1));
  }
  auto frame = std::make_shared<Frame>();
  frame->width = outWidth;
  frame->height = outHeight;
  frame->timestampNs = nowNs();
  frame->rgb = std::move(rgbCopy);
  frame->jpeg = lastJpeg_;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    frame->id = status_.frame ? status_.frame->id + 1u : 1u;
    status_.online = online;
    status_.error.clear();
    status_.frame = std::move(frame);
  }
  frameCv_.notify_all();
}

void CameraDevice::fail(const std::string& message) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    status_.online = false;
    status_.fps = 0.0;
    status_.error = message;
  }
  frameCv_.notify_all();
  std::cerr << label_ << ": " << message << '\n';
}

}  // namespace pulsar::camera
