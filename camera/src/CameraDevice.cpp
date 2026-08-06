#include "pulsar/camera/CameraDevice.hpp"

#include "DxImageProc.h"
#include "pulsar/camera/JpegEncoder.hpp"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cctype>
#include <cstring>
#include <initializer_list>
#include <iostream>
#include <memory>
#include <mutex>
#include <pthread.h>
#include <sched.h>
#include <sys/resource.h>
#include <thread>

namespace pulsar::camera {
namespace {

constexpr DX_BAYER_CONVERT_TYPE kRealtimeConvertMode = RAW2RGB_NEIGHBOUR;
constexpr uint32_t kAcquisitionBufferCount = 3;

std::mutex gSdkMutex;

bool available(GX_PORT_HANDLE port, const char* node) {
  GX_NODE_ACCESS_MODE mode = GX_NODE_ACCESS_MODE_NI;
  if (GXGetNodeAccessMode(port, node, &mode) != GX_STATUS_SUCCESS) return false;
  return mode == GX_NODE_ACCESS_MODE_RO || mode == GX_NODE_ACCESS_MODE_WO || mode == GX_NODE_ACCESS_MODE_RW;
}

bool setEnum(GX_PORT_HANDLE port, const char* node, const char* value) {
  return available(port, node) &&
         GXSetEnumValueByString(port, node, value) == GX_STATUS_SUCCESS;
}

bool setEnumValue(GX_PORT_HANDLE port, const char* node, int64_t value) {
  return available(port, node) &&
         GXSetEnumValue(port, node, value) == GX_STATUS_SUCCESS;
}

bool setEnumOneOf(GX_PORT_HANDLE port, const char* node, std::initializer_list<const char*> values) {
  for (const char* value : values) {
    if (setEnum(port, node, value)) return true;
  }
  return false;
}

bool setFloat(GX_PORT_HANDLE port, const char* node, double value) {
  if (!available(port, node)) return false;
  GX_FLOAT_VALUE range{};
  if (GXGetFloatValue(port, node, &range) != GX_STATUS_SUCCESS) return false;
  return GXSetFloatValue(port, node, std::clamp(value, range.dMin, range.dMax)) == GX_STATUS_SUCCESS;
}

bool setCommand(GX_PORT_HANDLE port, const char* node) {
  return available(port, node) && GXSetCommandValue(port, node) == GX_STATUS_SUCCESS;
}

void setBalanceRatio(GX_PORT_HANDLE port, const char* selector, double ratio) {
  if (!setEnum(port, "BalanceRatioSelector", selector)) return;
  setFloat(port, "BalanceRatio", ratio);
}

bool setBool(GX_PORT_HANDLE port, const char* node, bool value) {
  return available(port, node) && GXSetBoolValue(port, node, value) == GX_STATUS_SUCCESS;
}

bool setInt(GX_PORT_HANDLE port, const char* node, int64_t value) {
  if (!available(port, node)) return false;
  GX_INT_VALUE range{};
  if (GXGetIntValue(port, node, &range) != GX_STATUS_SUCCESS) return false;
  int64_t clamped = std::clamp(value, range.nMin, range.nMax);
  if (range.nInc > 1) clamped = range.nMin + ((clamped - range.nMin) / range.nInc) * range.nInc;
  return GXSetIntValue(port, node, clamped) == GX_STATUS_SUCCESS;
}

bool getInt(GX_PORT_HANDLE port, const char* node, GX_INT_VALUE& value) {
  return available(port, node) && GXGetIntValue(port, node, &value) == GX_STATUS_SUCCESS;
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

void bestEffortRealtime(int niceValue, int priority) {
  ::setpriority(PRIO_PROCESS, 0, niceValue);
  sched_param params{};
  params.sched_priority = priority;
  pthread_setschedparam(pthread_self(), SCHED_RR, &params);
}

uint64_t steadyNs(std::chrono::steady_clock::time_point point) {
  return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(
      point.time_since_epoch()).count());
}

uint64_t nowNs() {
  return steadyNs(std::chrono::steady_clock::now());
}

bool envEnabled(const char* name, bool fallback) {
  const char* value = std::getenv(name);
  if (value == nullptr || *value == '\0') return fallback;
  return std::strcmp(value, "1") == 0 || std::strcmp(value, "true") == 0 ||
         std::strcmp(value, "yes") == 0 || std::strcmp(value, "on") == 0;
}

int envInt(const char* name, int fallback, int minimum, int maximum) {
  const char* value = std::getenv(name);
  if (value == nullptr || *value == '\0') return fallback;
  char* end = nullptr;
  const long parsed = std::strtol(value, &end, 10);
  if (end == value || *end != '\0') return fallback;
  return std::clamp(static_cast<int>(parsed), minimum, maximum);
}

bool controlsEqual(const core::CameraControls& a, const core::CameraControls& b) {
  return a.brightness == b.brightness && a.autoExposure == b.autoExposure &&
         std::abs(a.exposureUs - b.exposureUs) < 0.1 && std::abs(a.gainDb - b.gainDb) < 0.01 &&
         a.whiteBalance == b.whiteBalance && a.enhance == b.enhance;
}

std::string lowerAscii(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(), [](unsigned char ch) {
    return static_cast<char>(std::tolower(ch));
  });
  return value;
}

bool gpuRequestedForSlot(uint32_t slot) {
  const char* raw = std::getenv("PULSAR_GPU_PIPELINE");
  // CUDA is the production path. CPU fallback remains automatic when this
  // binary was built without CUDA or initialization fails.
  if (raw == nullptr) return true;

  const std::string mode = lowerAscii(raw);
  if (mode == "1" || mode == "on" || mode == "true" || mode == "both") return true;
  if (slot == 0 && mode == "left") return true;
  if (slot == 1 && mode == "right") return true;
  return false;
}

std::pair<uint32_t, uint32_t> fitOutputSize(
    uint32_t width,
    uint32_t height,
    uint32_t maxWidth,
    uint32_t maxHeight) {
  const double scale = std::min({
      1.0,
      static_cast<double>(maxWidth) / static_cast<double>(width),
      static_cast<double>(maxHeight) / static_cast<double>(height)});
  return {
      std::max<uint32_t>(1, static_cast<uint32_t>(width * scale)),
      std::max<uint32_t>(1, static_cast<uint32_t>(height * scale))};
}

std::shared_ptr<const PixelBuffer> copyPixelBuffer(
    const uint8_t* data,
    std::size_t bytes) {
  if (data == nullptr || bytes == 0) return {};
  auto storage = std::shared_ptr<uint8_t>(
      new uint8_t[bytes], std::default_delete<uint8_t[]>());
  std::memcpy(storage.get(), data, bytes);
  auto buffer = std::make_shared<PixelBuffer>();
  buffer->storage = std::move(storage);
  buffer->byteCount = bytes;
  return buffer;
}

bool gpuPatternFor(
    uint64_t format,
    int64_t cameraFilter,
    BayerPattern& pattern) {
  const DX_PIXEL_COLOR_FILTER filter = filterFor(format, cameraFilter);
  switch (filter) {
    case BAYERRG:
      pattern = BayerPattern::Rggb;
      return true;
    case BAYERBG:
      pattern = BayerPattern::Bggr;
      return true;
    case BAYERGB:
      pattern = BayerPattern::Gbrg;
      return true;
    case BAYERGR:
      pattern = BayerPattern::Grbg;
      return true;
    default:
      return false;
  }
}

}  // namespace

bool SoftwareStartGate::arriveAndWait(
    uint32_t slot,
    std::chrono::milliseconds timeout) {
  if (slot >= arrived_.size()) return false;

  std::unique_lock<std::mutex> lock(mutex_);
  if (released_) return paired_;

  arrived_[slot] = true;
  if (arrived_[0] && arrived_[1]) {
    paired_ = true;
    released_ = true;
    cv_.notify_all();
    return true;
  }

  if (!cv_.wait_for(lock, timeout, [this] { return released_; })) {
    // Bounded fallback: never deadlock camera startup if the peer is absent.
    paired_ = false;
    released_ = true;
    cv_.notify_all();
  }
  return paired_;
}

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
                           int sensorScale, int targetFps, int previewFps, int jpegQuality,
                           std::filesystem::path profilePath, bool profileEnabled,
                           bool profileVerify, bool profileRequired,
                           double whiteBalanceRed, double whiteBalanceGreen, double whiteBalanceBlue,
                           ControlProvider controls, PreviewDemandProvider previewDemand,
                           std::shared_ptr<SoftwareStartGate> startGate)
    : slot_(slot), sdkIndex_(sdkIndex), serialSelector_(std::move(serialSelector)),
      label_(std::move(label)), mockMode_(mockMode),
      maxWidth_(maxWidth), maxHeight_(maxHeight), sensorScale_(sensorScale), targetFps_(targetFps),
      previewFps_(previewFps), jpegQuality_(jpegQuality), profilePath_(std::move(profilePath)),
      profileEnabled_(profileEnabled), profileVerify_(profileVerify),
      profileRequired_(profileRequired), whiteBalanceRed_(whiteBalanceRed),
      whiteBalanceGreen_(whiteBalanceGreen), whiteBalanceBlue_(whiteBalanceBlue),
      controls_(std::move(controls)), previewDemand_(std::move(previewDemand)),
      startGate_(std::move(startGate)) {
  status_.slot = slot_;
  status_.label = label_;
  gpuRequested_ = gpuRequestedForSlot(slot_);
  if (gpuRequested_) {
    gpuPipeline_ = std::make_unique<GpuBayerPipeline>();
  }
}

CameraDevice::~CameraDevice() { stop(); }

void CameraDevice::start() {
  if (running_.exchange(true)) return;
  previewWorker_ = std::thread(&CameraDevice::previewLoop, this);
  worker_ = std::thread(&CameraDevice::loop, this);
}

void CameraDevice::stop() {
  running_ = false;
  previewCv_.notify_all();
  if (worker_.joinable()) worker_.join();
  if (previewWorker_.joinable()) previewWorker_.join();
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

void CameraDevice::notifyPreviewDemand() {
  previewCv_.notify_all();
}

void CameraDevice::loop() {
  elevateThreadPriority();
  if (mockMode_) {
    mockLoop();
    return;
  }

  // Low-latency policy: dequeue every frame currently waiting in the SDK,
  // keep only the newest successful frame, return all SDK buffers immediately,
  // then process the private raw copy. This prevents a growing backlog.
  std::array<PGX_FRAME_BUFFER, kAcquisitionBufferCount> readyBuffers{};
  std::vector<uint8_t> rawCopy;
  GX_FRAME_BUFFER copiedFrame{};

  uint64_t processedFrames = 0;
  uint64_t reportProcessedFrames = 0;
  uint64_t reportAcquiredFrames = 0;
  uint64_t reportDroppedStaleFrames = 0;

  double dequeueMsSum = 0.0;
  double rawCopyMsSum = 0.0;
  double convertMsSum = 0.0;
  double publishMsSum = 0.0;
  double totalMsSum = 0.0;
  double totalMsMax = 0.0;

  uint64_t reportGpuFrames = 0;
  double gpuH2dMsSum = 0.0;
  double gpuDebayerMsSum = 0.0;
  double gpuResizeMsSum = 0.0;
  double gpuD2hMsSum = 0.0;
  double gpuTotalMsSum = 0.0;
  double gpuTotalMsMax = 0.0;

  auto fpsStart = std::chrono::steady_clock::now();
  auto reportStart = fpsStart;

  while (running_) {
    if (device_ == nullptr && !connect()) {
      std::this_thread::sleep_for(std::chrono::milliseconds(700));
      continue;
    }

    const auto desired = controls_();
    applyControls(desired, false);

    readyBuffers.fill(nullptr);
    uint32_t readyCount = 0;
    const auto dequeueStart = std::chrono::steady_clock::now();
    const GX_STATUS dequeueStatus =
        GXDQAllBufs(device_, readyBuffers.data(),
                    static_cast<uint32_t>(readyBuffers.size()),
                    &readyCount, 1000);
    const auto dequeueEnd = std::chrono::steady_clock::now();

    if (dequeueStatus != GX_STATUS_SUCCESS || readyCount == 0) {
      fail(dequeueStatus == GX_STATUS_TIMEOUT
               ? "camera timeout; reconnecting"
               : "camera read failed; reconnecting");
      close();
      std::this_thread::sleep_for(std::chrono::milliseconds(250));
      continue;
    }

    reportAcquiredFrames += readyCount;

    PGX_FRAME_BUFFER newest = nullptr;
    for (uint32_t i = readyCount; i > 0; --i) {
      PGX_FRAME_BUFFER candidate = readyBuffers[i - 1];
      if (candidate != nullptr &&
          candidate->nStatus == GX_FRAME_STATUS_SUCCESS &&
          candidate->pImgBuf != nullptr && candidate->nImgSize > 0) {
        newest = candidate;
        break;
      }
    }

    const uint64_t staleNow = readyCount > 1 ? readyCount - 1u : 0u;
    reportDroppedStaleFrames += staleNow;

    bool havePrivateFrame = false;
    bool gpuInputStaged = false;
    std::string gpuStageError;
    const auto copyStart = std::chrono::steady_clock::now();
    if (newest != nullptr) {
      copiedFrame = *newest;

      const bool canStageGpu =
          gpuRequested_ && !gpuDisabledAfterFailure_ &&
          gpuPipeline_ != nullptr && bayer8(newest->nPixelFormat);

      if (canStageGpu && gpuPipeline_->stageInput(
                             static_cast<const uint8_t*>(newest->pImgBuf),
                             static_cast<std::size_t>(newest->nImgSize),
                             gpuStageError)) {
        copiedFrame.pImgBuf = nullptr;
        gpuInputStaged = true;
        havePrivateFrame = true;
      } else {
        if (canStageGpu) {
          gpuDisabledAfterFailure_ = true;
          std::cerr << label_
                    << ": GPU pinned-input staging failed; CPU fallback active: "
                    << gpuStageError << '\n';
        }

        rawCopy.resize(static_cast<size_t>(newest->nImgSize));
        std::memcpy(rawCopy.data(), newest->pImgBuf, rawCopy.size());
        copiedFrame.pImgBuf = rawCopy.data();
        havePrivateFrame = true;
      }
    }
    const auto copyEnd = std::chrono::steady_clock::now();

    // Return all Galaxy SDK buffers before CPU debayer/resize starts so the
    // camera can continue acquiring into its fixed buffer pool.
    if (GXQAllBufs(device_) != GX_STATUS_SUCCESS) {
      fail("camera buffer requeue failed; reconnecting");
      close();
      std::this_thread::sleep_for(std::chrono::milliseconds(250));
      continue;
    }

    bool published = false;
    GpuBayerTimings gpuTimings{};
    auto convertEnd = copyEnd;
    auto publishEnd = copyEnd;
    if (havePrivateFrame) {
      FrameTiming timing{};
      timing.cameraFrameId = copiedFrame.nFrameID;
      timing.cameraTimestamp = copiedFrame.nTimestamp;
      timing.hostDequeueNs = steadyNs(dequeueEnd);
      timing.hostRawCopyDoneNs = steadyNs(copyEnd);

      if (gpuRequested_ && !gpuDisabledAfterFailure_ && gpuPipeline_ != nullptr &&
          bayer8(copiedFrame.nPixelFormat)) {
        BayerPattern pattern = BayerPattern::Rggb;
        const uint32_t sourceWidth = static_cast<uint32_t>(copiedFrame.nWidth);
        const uint32_t sourceHeight = static_cast<uint32_t>(copiedFrame.nHeight);
        const auto [outputWidth, outputHeight] =
            fitOutputSize(sourceWidth, sourceHeight, maxWidth_, maxHeight_);
        std::string gpuError;
        std::shared_ptr<const PixelBuffer> gpuOutput;

        if (gpuInputStaged &&
            gpuPatternFor(copiedFrame.nPixelFormat, colorFilter_, pattern) &&
            gpuPipeline_->processStaged(
                sourceWidth,
                sourceHeight,
                pattern,
                outputWidth,
                outputHeight,
                gpuOutput,
                gpuTimings,
                gpuError)) {
          convertEnd = std::chrono::steady_clock::now();
          timing.hostDebayerDoneNs = steadyNs(convertEnd);
          publish(
              outputWidth,
              outputHeight,
              std::move(gpuOutput),
              true,
              timing);
          publishEnd = std::chrono::steady_clock::now();
          published = true;
          ++reportGpuFrames;
          gpuH2dMsSum += gpuTimings.hostToDeviceMs;
          gpuDebayerMsSum += gpuTimings.debayerMs;
          gpuResizeMsSum += gpuTimings.resizeMs;
          gpuD2hMsSum += gpuTimings.deviceToHostMs;
          gpuTotalMsSum += gpuTimings.totalMs;
          gpuTotalMsMax = std::max(gpuTotalMsMax, gpuTimings.totalMs);
        } else {
          const bool outputPoolBusy =
              gpuError == "all CUDA output buffers are still in use";
          if (outputPoolBusy) {
            // A slow UI/recorder consumer must not permanently disable CUDA.
            // Drop this stale frame and retry the GPU path on the next capture.
            std::cerr << label_
                      << ": CUDA output pool busy; dropping one frame\n";
          } else {
            gpuDisabledAfterFailure_ = true;
            std::cerr << label_ << ": GPU pipeline disabled; CPU fallback active: "
                      << (gpuError.empty() ? "unsupported Bayer pattern" : gpuError)
                      << '\n';
          }
        }
      }

      // A staged GPU frame no longer owns a CPU raw copy. If GPU processing
      // fails, drop this one frame; the next iteration uses CPU fallback after
      // gpuDisabledAfterFailure_ has been set.
      if (!published && !gpuInputStaged) {
        const bool converted = convert(&copiedFrame, rgb_);
        convertEnd = std::chrono::steady_clock::now();
        if (converted) {
          timing.hostDebayerDoneNs = steadyNs(convertEnd);
          publish(static_cast<uint32_t>(copiedFrame.nWidth),
                  static_cast<uint32_t>(copiedFrame.nHeight), rgb_, true, timing);
          publishEnd = std::chrono::steady_clock::now();
          published = true;
        }
      }

      if (published) {
        ++processedFrames;
        ++reportProcessedFrames;
      }
    }

    const auto now = std::chrono::steady_clock::now();
    const auto ms = [](auto duration) {
      return std::chrono::duration<double, std::milli>(duration).count();
    };

    if (published) {
      const double dequeueMs = ms(dequeueEnd - dequeueStart);
      const double copyMs = ms(copyEnd - copyStart);
      const double convertMs = ms(convertEnd - copyEnd);
      const double publishMs = ms(publishEnd - convertEnd);
      const double totalMs = ms(publishEnd - dequeueEnd);
      dequeueMsSum += dequeueMs;
      rawCopyMsSum += copyMs;
      convertMsSum += convertMs;
      publishMsSum += publishMs;
      totalMsSum += totalMs;
      totalMsMax = std::max(totalMsMax, totalMs);
    }

    const std::chrono::duration<double> fpsElapsed = now - fpsStart;
    if (fpsElapsed.count() >= 1.0) {
      std::lock_guard<std::mutex> lock(mutex_);
      status_.fps = static_cast<double>(processedFrames) / fpsElapsed.count();
      processedFrames = 0;
      fpsStart = now;
    }

    const std::chrono::duration<double> reportElapsed = now - reportStart;
    if (reportElapsed.count() >= 2.0) {
      const double divisor = static_cast<double>(std::max<uint64_t>(1, reportProcessedFrames));
      std::cerr << label_ << ": latency-stats"
                << " pipeline="
                << (reportGpuFrames == reportProcessedFrames && reportGpuFrames > 0
                        ? "gpu"
                        : (reportGpuFrames > 0 ? "mixed" : "cpu"))
                << " output-fps="
                << (static_cast<double>(reportProcessedFrames) / reportElapsed.count())
                << " acquired-fps="
                << (static_cast<double>(reportAcquiredFrames) / reportElapsed.count())
                << " stale-dropped=" << reportDroppedStaleFrames
                << " dequeue-wait-ms=" << (dequeueMsSum / divisor)
                << " raw-copy-ms=" << (rawCopyMsSum / divisor)
                << " process-ms=" << (convertMsSum / divisor)
                << " publish-ms=" << (publishMsSum / divisor)
                << " host-pipeline-ms=" << (totalMsSum / divisor)
                << " host-pipeline-max-ms=" << totalMsMax;

      if (reportGpuFrames > 0) {
        const double gpuDivisor = static_cast<double>(reportGpuFrames);
        std::cerr << " gpu-h2d-ms=" << (gpuH2dMsSum / gpuDivisor)
                  << " gpu-debayer-ms=" << (gpuDebayerMsSum / gpuDivisor)
                  << " gpu-resize-ms=" << (gpuResizeMsSum / gpuDivisor)
                  << " gpu-d2h-ms=" << (gpuD2hMsSum / gpuDivisor)
                  << " gpu-total-ms=" << (gpuTotalMsSum / gpuDivisor)
                  << " gpu-total-max-ms=" << gpuTotalMsMax;
      }
      std::cerr << '\n';

      reportProcessedFrames = 0;
      reportAcquiredFrames = 0;
      reportDroppedStaleFrames = 0;
      dequeueMsSum = 0.0;
      rawCopyMsSum = 0.0;
      convertMsSum = 0.0;
      publishMsSum = 0.0;
      totalMsSum = 0.0;
      totalMsMax = 0.0;
      reportGpuFrames = 0;
      gpuH2dMsSum = 0.0;
      gpuDebayerMsSum = 0.0;
      gpuResizeMsSum = 0.0;
      gpuD2hMsSum = 0.0;
      gpuTotalMsSum = 0.0;
      gpuTotalMsMax = 0.0;
      reportStart = now;
    }
  }
}

void CameraDevice::mockLoop() {
  elevateThreadPriority();
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

void CameraDevice::previewLoop() {
  pthread_setname_np(pthread_self(), slot_ == 0 ? "pulsar-jpg-l" : "pulsar-jpg-r");
  bestEffortRealtime(-4, 10);

  const auto interval = std::chrono::milliseconds(1000 / std::max(previewFps_, 1));
  auto next = std::chrono::steady_clock::now();
  uint64_t encodedId = 0;

  while (running_) {
    {
      std::unique_lock<std::mutex> lock(previewMutex_);
      previewCv_.wait(lock, [&] {
        return !running_ || ((previewDemand_ == nullptr || previewDemand_()) && previewPending_ && previewPending_->id != encodedId);
      });
    }
    if (!running_) break;
    if (previewDemand_ != nullptr && !previewDemand_()) {
      std::lock_guard<std::mutex> lock(previewMutex_);
      lastJpeg_.reset();
      continue;
    }

    std::this_thread::sleep_until(next);
    if (!running_) break;

    std::shared_ptr<const Frame> frame;
    {
      std::lock_guard<std::mutex> lock(previewMutex_);
      frame = previewPending_;
    }
    if (!frame || !frame->rgb || frame->rgb->empty()) continue;

    uint32_t jpegWidth = frame->width;
    uint32_t jpegHeight = frame->height;
    const uint8_t* jpegData = frame->rgb->data();
    const double jpegScale = std::min({1.0, 960.0 / std::max<uint32_t>(1, frame->width),
                                       540.0 / std::max<uint32_t>(1, frame->height)});
    if (jpegScale < 0.999) {
      jpegWidth = std::max<uint32_t>(1, static_cast<uint32_t>(std::lround(frame->width * jpegScale)));
      jpegHeight = std::max<uint32_t>(1, static_cast<uint32_t>(std::lround(frame->height * jpegScale)));
      resizeRgbBilinearInto(frame->rgb->data(), frame->width, frame->height, jpegWidth, jpegHeight, previewResized_);
      jpegData = previewResized_.data();
    }

    auto jpeg = std::make_shared<std::vector<uint8_t>>(encodeJpeg(jpegData, jpegWidth, jpegHeight, jpegQuality_));
    {
      std::lock_guard<std::mutex> lock(previewMutex_);
      lastJpeg_ = std::move(jpeg);
    }
    encodedId = frame->id;
    next = std::chrono::steady_clock::now() + interval;
  }
}

bool CameraDevice::connect() {
  close();

  // Open and configure SDK devices one at a time. The global lock is released
  // before the shared start gate so the peer camera can reach the barrier.
  {
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
    if (!configure()) {
      fail("camera configuration failed");
      GXCloseDevice(device_);
      device_ = nullptr;
      return false;
    }
  }

  const bool softwareSync = envEnabled("PULSAR_SOFTWARE_START_SYNC", false);
  bool pairedStart = false;
  if (softwareSync && startGate_ != nullptr) {
    const int timeoutMs = envInt(
        "PULSAR_SOFTWARE_START_SYNC_TIMEOUT_MS", 5000, 250, 15000);
    pairedStart = startGate_->arriveAndWait(
        slot_, std::chrono::milliseconds(timeoutMs));
  }

  const auto streamOnStart = std::chrono::steady_clock::now();
  GX_STATUS streamStatus = GX_STATUS_ERROR;
  {
    // Keep SDK calls serialized for safety. Because both cameras are already
    // configured and released from the same gate, the two StreamOn calls now
    // run back-to-back instead of being separated by complete camera/GPU init.
    std::lock_guard<std::mutex> sdkLock(gSdkMutex);
    streamStatus = GXStreamOn(device_);
  }
  const auto streamOnEnd = std::chrono::steady_clock::now();
  if (streamStatus != GX_STATUS_SUCCESS) {
    fail("camera stream start failed");
    std::lock_guard<std::mutex> sdkLock(gSdkMutex);
    GXCloseDevice(device_);
    device_ = nullptr;
    return false;
  }

  std::cerr << label_
            << ": software-start-sync="
            << (softwareSync ? (pairedStart ? "paired" : "fallback") : "off")
            << " stream-on-call-ms="
            << std::chrono::duration<double, std::milli>(streamOnEnd - streamOnStart).count()
            << " stream-on-host-ns=" << steadyNs(streamOnEnd) << '\n';

  GX_INT_VALUE configuredWidth{};
  GX_INT_VALUE configuredHeight{};
  const bool haveWidth = getInt(device_, "Width", configuredWidth);
  const bool haveHeight = getInt(device_, "Height", configuredHeight);
  {
    std::lock_guard<std::mutex> lock(mutex_);
    status_.model = getString(device_, "DeviceModelName");
    status_.serial = getString(device_, "DeviceSerialNumber");
    status_.error.clear();
  }
  std::cerr << label_ << ": configured sensor="
            << (haveWidth ? std::to_string(configuredWidth.nCurValue) : std::string{"?"}) << "x"
            << (haveHeight ? std::to_string(configuredHeight.nCurValue) : std::string{"?"})
            << " sensor-scale=" << configuredSensorScale_
            << " render-max=" << maxWidth_ << "x" << maxHeight_ << '\n';

  if (gpuRequested_) {
    if (!GpuBayerPipeline::compiledWithCuda()) {
      gpuDisabledAfterFailure_ = true;
      std::cerr << label_ << ": GPU pipeline requested but CUDA was not compiled; CPU fallback active\n";
    } else if (gpuPipeline_ != nullptr && !gpuDisabledAfterFailure_) {
      std::string gpuError;
      if (gpuPipeline_->initialize(gpuError)) {
        std::cerr << label_ << ": GPU pipeline ready (CUDA/NPP, canary mode)\n";
      } else {
        gpuDisabledAfterFailure_ = true;
        std::cerr << label_ << ": GPU pipeline initialization failed; CPU fallback active: "
                  << gpuError << '\n';
      }
    }
  }
  return true;
}

bool CameraDevice::importGalaxyProfile() {
  if (!profileEnabled_) return false;

  if (profilePath_.empty()) {
    std::cerr << label_ << ": GalaxyView profile path is empty\n";
    return false;
  }

  std::error_code pathError;
  std::filesystem::path resolvedPath = profilePath_;
  if (resolvedPath.is_relative()) {
    resolvedPath = std::filesystem::absolute(resolvedPath, pathError);
  }

  if (pathError || !std::filesystem::is_regular_file(resolvedPath)) {
    std::cerr << label_ << ": GalaxyView profile not found: "
              << resolvedPath.string() << '\n';
    return false;
  }

  const std::string profileFile = resolvedPath.string();
  const GX_STATUS status =
      GXImportConfigFile(device_, profileFile.c_str(), profileVerify_);

  if (status != GX_STATUS_SUCCESS) {
    std::cerr << label_ << ": GXImportConfigFile failed for "
              << profileFile << " (status=" << static_cast<int>(status) << ")\n";
    return false;
  }

  profileImported_ = true;
  configuredSensorScale_ = 1;
  std::cerr << label_ << ": imported GalaxyView profile " << profileFile
            << " (verify=" << (profileVerify_ ? "on" : "off") << ")\n";
  return true;
}

bool CameraDevice::configure() {
  profileImported_ = false;
  controlsApplied_ = false;

  if (profileEnabled_) {
    if (!importGalaxyProfile() && profileRequired_) {
      std::cerr << label_ << ": required GalaxyView profile could not be loaded\n";
      return false;
    }
  }

  if (!profileImported_) {
    if (setEnumOneOf(device_, "UserSetSelector", {"Default", "UserSet0"})) {
      setCommand(device_, "UserSetLoad");
    }

    setEnum(device_, "AcquisitionMode", "Continuous");
    setEnum(device_, "TriggerMode", "Off");
    setEnumOneOf(device_, "RegionSelector", {"Region0", "Region1"});
    setEnum(device_, "RegionMode", "Off");

    // Configure the sensor/transport resolution before streaming. This is a
    // real camera ROI, not a post-capture resize, so USB never carries the
    // unused 12 MP frame when the target is 1920x1080.
    configuredSensorScale_ = std::clamp(sensorScale_, 1, 4);
    setEnumOneOf(device_, "BinningHorizontalMode", {"Average", "Sum"});
    setEnumOneOf(device_, "BinningVerticalMode", {"Average", "Sum"});
    setInt(device_, "BinningHorizontal", configuredSensorScale_);
    setInt(device_, "BinningVertical", configuredSensorScale_);
    setInt(device_, "DecimationHorizontal", 1);
    setInt(device_, "DecimationVertical", 1);
    setInt(device_, "SensorDecimationHorizontal", 1);
    setInt(device_, "SensorDecimationVertical", 1);
    setBool(device_, "CenterX", false);
    setBool(device_, "CenterY", false);
    setInt(device_, "OffsetX", 0);
    setInt(device_, "OffsetY", 0);

    GX_INT_VALUE widthMax{};
    GX_INT_VALUE heightMax{};
    if (getInt(device_, "WidthMax", widthMax)) {
      setInt(device_, "Width", std::min<int64_t>(
          static_cast<int64_t>(maxWidth_), widthMax.nCurValue));
    }
    if (getInt(device_, "HeightMax", heightMax)) {
      setInt(device_, "Height", std::min<int64_t>(
          static_cast<int64_t>(maxHeight_), heightMax.nCurValue));
    }

    // Center the ROI after its dimensions are set; Offset range depends on
    // the current Width/Height on Galaxy cameras.
    GX_INT_VALUE offsetX{};
    GX_INT_VALUE offsetY{};
    if (getInt(device_, "OffsetX", offsetX)) setInt(device_, "OffsetX", offsetX.nMax / 2);
    if (getInt(device_, "OffsetY", offsetY)) setInt(device_, "OffsetY", offsetY.nMax / 2);

    setEnumValue(device_, "AcquisitionFrameRateMode", 1);
    setFloat(device_, "AcquisitionFrameRate", static_cast<double>(targetFps_));

    setInt(device_, "StreamTransferSize", 64 * 1024);
    setInt(device_, "StreamTransferNumberUrb", 32);
    setBool(device_, "FrameStoreCoverActive", true);
    setEnum(device_, "CoverFrameStoreMode", "On");
    applyControls(controls_(), true);
  }

  // Low-latency stream policy. These are host/transport settings only and
  // intentionally override the persistence file's OldestFirst queue policy.
  const char* streamBufferMode = "unchanged";
  if (setEnum(device_, "StreamBufferHandlingMode", "NewestOnly")) {
    streamBufferMode = "NewestOnly";
  } else if (setEnum(device_, "StreamBufferHandlingMode", "OldestFirstOverwrite")) {
    streamBufferMode = "OldestFirstOverwrite";
  }

  if (GXSetAcqusitionBufferNumber(device_, kAcquisitionBufferCount) != GX_STATUS_SUCCESS) {
    std::cerr << label_ << ": warning: could not set acquisition buffer count\n";
  }
  std::cerr << label_ << ": low-latency stream-buffer-mode="
            << streamBufferMode << " acquisition-buffers="
            << kAcquisitionBufferCount << '\n';

  // Read the Bayer filter after profile import, because the profile may
  // change PixelFormat or related color settings.
  colorFilter_ = GX_COLOR_FILTER_NONE;
  if (available(device_, "PixelColorFilter")) {
    GX_ENUM_VALUE value{};
    if (GXGetEnumValue(device_, "PixelColorFilter", &value) == GX_STATUS_SUCCESS) {
      colorFilter_ = value.stCurValue.nCurValue;
    }
  }

  return true;
}

void CameraDevice::elevateThreadPriority() const {
  pthread_setname_np(pthread_self(), slot_ == 0 ? "pulsar-cam-l" : "pulsar-cam-r");
  bestEffortRealtime(-6, 18);
}

void CameraDevice::close() {
  std::lock_guard<std::mutex> sdkLock(gSdkMutex);
  if (device_ != nullptr) {
    GXStreamOff(device_);
    GXCloseDevice(device_);
    device_ = nullptr;
  }
  controlsApplied_ = false;
  profileImported_ = false;
}

void CameraDevice::applyControls(const core::CameraControls& controls, bool force) {
  // An explicitly enabled GalaxyView profile remains authoritative. The
  // low-latency default disables profiles so ROI/FPS/exposure come from env/UI.
  if (profileImported_) return;

  if (device_ == nullptr ||
      (!force && controlsApplied_ && controlsEqual(controls, appliedControls_))) {
    return;
  }

  setEnum(device_, "ExposureMode", "Timed");
  const double frameBudgetUs = 1'000'000.0 / static_cast<double>(std::max(1, targetFps_));
  const double maximumExposureUs = std::max(40.0, frameBudgetUs - 1'500.0);
  setFloat(device_, "AutoExposureTimeMin", 40.0);
  setFloat(device_, "AutoExposureTimeMax", maximumExposureUs);

  if (controls.autoExposure) {
    if (!setEnumOneOf(device_, "ExposureAuto", {"Continuous", "Once"})) {
      setEnumValue(device_, "ExposureAuto", 1);
    }
  } else {
    if (!setEnum(device_, "ExposureAuto", "Off")) setEnumValue(device_, "ExposureAuto", 0);
    setFloat(device_, "ExposureTime", std::min(controls.exposureUs, maximumExposureUs));
  }

  setEnum(device_, "GainAuto", "Off");
  setEnumOneOf(device_, "GainSelector", {"AnalogAll", "All"});
  setFloat(device_, "Gain", controls.gainDb);

  // Prefer a real brightness node. If this camera exposes only BlackLevel, use
  // a restrained mapping so the UI control remains functional without crushing
  // highlights or blacks.
  if (!setFloat(device_, "Brightness", static_cast<double>(controls.brightness))) {
    setEnumValue(device_, "BlackLevelAuto", 0);
    const double blackLevel = 1.0 +
        (static_cast<double>(controls.brightness) - 60.0) * 0.08;
    setFloat(device_, "BlackLevel", std::max(0.0, blackLevel));
  }

  if (controls.whiteBalance == "Auto") {
    if (!setEnumOneOf(device_, "BalanceWhiteAuto", {"Continuous", "Once"})) {
      setEnumValue(device_, "BalanceWhiteAuto", 1);
    }
  } else {
    if (!setEnum(device_, "BalanceWhiteAuto", "Off")) setEnumValue(device_, "BalanceWhiteAuto", 0);
    double red = whiteBalanceRed_;
    double green = whiteBalanceGreen_;
    double blue = whiteBalanceBlue_;
    if (controls.whiteBalance == "Warm") {
      red *= 1.12;
      blue *= 0.88;
    } else if (controls.whiteBalance == "Cool") {
      red *= 0.88;
      blue *= 1.12;
    }
    setBalanceRatio(device_, "Red", red);
    setBalanceRatio(device_, "Green", green);
    setBalanceRatio(device_, "Blue", blue);
  }

  const bool lowEnhance = controls.enhance == "Low";
  setBool(device_, "GammaEnable", !lowEnhance);
  if (!lowEnhance) {
    setEnum(device_, "GammaMode", "User");
    setFloat(device_, "Gamma", controls.enhance == "High" ? 0.92 : 0.98);
  }
  setEnum(device_, "SharpnessMode", lowEnhance ? "Off" : "On");
  if (!lowEnhance) {
    setFloat(device_, "Sharpness", controls.enhance == "High" ? 1.0 : 0.5);
  }

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
    return DxRaw8toRGB24(frame->pImgBuf, rgb.data(), width, height, kRealtimeConvertMode,
                         filterFor(format, colorFilter_), false) == DX_OK;
  }
  if (bayer16(format)) {
    raw8_.resize(pixels);
    if (DxRaw16toRaw8(frame->pImgBuf, raw8_.data(), width, height, validBits(format)) != DX_OK) return false;
    return DxRaw8toRGB24(raw8_.data(), rgb.data(), width, height, kRealtimeConvertMode,
                         filterFor(format, colorFilter_), false) == DX_OK;
  }
  fail("unsupported camera pixel format");
  return false;
}

void CameraDevice::publish(
    uint32_t width,
    uint32_t height,
    const std::vector<uint8_t>& rgb,
    bool online,
    FrameTiming timing) {
  publish(width, height, rgb.data(), rgb.size(), online, timing);
}

void CameraDevice::publish(
    uint32_t width,
    uint32_t height,
    const uint8_t* rgb,
    std::size_t rgbBytes,
    bool online,
    FrameTiming timing) {
  publish(width, height, copyPixelBuffer(rgb, rgbBytes), online, timing);
}

void CameraDevice::publish(
    uint32_t width,
    uint32_t height,
    std::shared_ptr<const PixelBuffer> rgb,
    bool online,
    FrameTiming timing) {
  const std::size_t requiredBytes =
      static_cast<std::size_t>(width) * static_cast<std::size_t>(height) * 3u;
  if (!rgb || rgb->data() == nullptr || rgb->size() < requiredBytes) {
    fail("publish received an incomplete RGB frame");
    return;
  }

  const double scale = std::min({
      1.0,
      static_cast<double>(maxWidth_) / static_cast<double>(width),
      static_cast<double>(maxHeight_) / static_cast<double>(height)});
  const uint32_t outWidth =
      std::max<uint32_t>(1, static_cast<uint32_t>(width * scale));
  const uint32_t outHeight =
      std::max<uint32_t>(1, static_cast<uint32_t>(height * scale));

  std::shared_ptr<const PixelBuffer> publishedRgb = std::move(rgb);
  if (outWidth != width || outHeight != height) {
    resizeRgbBilinearInto(
        publishedRgb->data(), width, height, outWidth, outHeight, resized_);
    publishedRgb = copyPixelBuffer(resized_.data(), resized_.size());
  }

  std::shared_ptr<const std::vector<uint8_t>> currentJpeg;
  {
    std::lock_guard<std::mutex> lock(previewMutex_);
    currentJpeg = lastJpeg_;
  }

  auto frame = std::make_shared<Frame>();
  frame->width = outWidth;
  frame->height = outHeight;
  timing.hostPublishDoneNs = nowNs();
  frame->timestampNs = timing.hostPublishDoneNs;
  frame->timing = timing;
  frame->rgb = std::move(publishedRgb);
  frame->jpeg = std::move(currentJpeg);

  {
    std::lock_guard<std::mutex> lock(mutex_);
    frame->id = status_.frame ? status_.frame->id + 1u : 1u;
    status_.online = online;
    status_.error.clear();
    status_.frame = frame;
  }
  {
    std::lock_guard<std::mutex> lock(previewMutex_);
    previewPending_ = frame;
  }
  previewCv_.notify_one();
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
