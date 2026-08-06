#include "pulsar/camera/SbsRenderer.hpp"

#include "pulsar/camera/JpegEncoder.hpp"

#include "pulsar/camera/SdlMinimal.hpp"
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cctype>
#include <cstddef>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <memory>
#include <pthread.h>
#include <sched.h>
#include <string>
#include <sys/resource.h>
#include <vector>

namespace pulsar::camera {
namespace {

constexpr uint64_t kMaxStereoSkewNs = 8'000'000ULL;
constexpr auto kMaxStereoHold = std::chrono::milliseconds(18);

void elevateRendererPriority() {
  ::setpriority(PRIO_PROCESS, 0, -5);
  sched_param params{};
  params.sched_priority = 16;
  pthread_setschedparam(pthread_self(), SCHED_RR, &params);
  pthread_setname_np(pthread_self(), "pulsar-sbs");
}

using GlEnum = unsigned int;
using GlUInt = unsigned int;
using GlSize = std::ptrdiff_t;
using GlBitfield = unsigned int;
using GlBoolean = unsigned char;

constexpr GlEnum kGlPixelUnpackBuffer = 0x88ECu;
constexpr GlEnum kGlStreamDraw = 0x88E0u;
constexpr GlBitfield kGlMapWriteBit = 0x0002u;
constexpr GlBitfield kGlMapInvalidateBufferBit = 0x0008u;
constexpr GlEnum kGlTexture2d = 0x0DE1u;
constexpr GlEnum kGlRgb = 0x1907u;
constexpr GlEnum kGlUnsignedByte = 0x1401u;
constexpr GlEnum kGlUnpackAlignment = 0x0CF5u;

bool envEnabled(const char* name, bool fallback = false) {
  const char* value = std::getenv(name);
  if (value == nullptr || *value == '\0') return fallback;
  return std::strcmp(value, "1") == 0 || std::strcmp(value, "true") == 0 ||
         std::strcmp(value, "yes") == 0 || std::strcmp(value, "on") == 0;
}

std::string envString(const char* name, const char* fallback) {
  const char* value = std::getenv(name);
  return value == nullptr || *value == '\0' ? std::string{fallback} : std::string{value};
}

enum class StereoPairingMode {
  LegacyHold,
  Latest,
};

StereoPairingMode stereoPairingModeFromEnvironment() {
  std::string value = envString("PULSAR_STEREO_PAIRING_MODE", "legacy-hold");
  std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) {
    return static_cast<char>(std::tolower(c));
  });
  return value == "latest" || value == "zero-hold"
             ? StereoPairingMode::Latest
             : StereoPairingMode::LegacyHold;
}

const char* stereoPairingModeName(StereoPairingMode mode) {
  return mode == StereoPairingMode::Latest ? "latest-zero-hold" : "legacy-hold";
}

struct GlPboSlot {
  std::array<GlUInt, 2> buffers{};
  size_t next = 0;
};

struct TextureSlot {
  SDL_Texture* texture = nullptr;
  uint32_t width = 0;
  uint32_t height = 0;
  uint64_t frameId = 0;
  double lastUploadMs = 0.0;
  bool uploadedThisLoop = false;
  std::shared_ptr<const Frame> heldFrame;
  GlPboSlot pbo;
};

class GlPboUploader {
 public:
  bool initialize(SDL_Renderer* renderer, std::string& error) {
    SDL_RendererInfo info{};
    if (SDL_GetRendererInfo(renderer, &info) != 0 || info.name == nullptr) {
      error = std::string{"SDL_GetRendererInfo failed: "} + SDL_GetError();
      return false;
    }
    if (std::string{info.name} != "opengl") {
      error = std::string{"SDL renderer is '"} + info.name + "', not opengl";
      return false;
    }

    if (!load(glGenBuffers_, "glGenBuffers", error) ||
        !load(glDeleteBuffers_, "glDeleteBuffers", error) ||
        !load(glBindBuffer_, "glBindBuffer", error) ||
        !load(glBufferData_, "glBufferData", error) ||
        !load(glMapBufferRange_, "glMapBufferRange", error) ||
        !load(glUnmapBuffer_, "glUnmapBuffer", error) ||
        !load(glPixelStorei_, "glPixelStorei", error) ||
        !load(glTexSubImage2D_, "glTexSubImage2D", error)) {
      return false;
    }

    active_ = true;
    return true;
  }

  bool active() const { return active_; }
  void disable() { active_ = false; }

  bool upload(SDL_Renderer* renderer, SDL_Texture* texture, GlPboSlot& slot,
              const uint8_t* rgb, uint32_t width, uint32_t height,
              std::string& error) {
    if (!active_ || texture == nullptr || rgb == nullptr || width == 0 || height == 0) {
      error = "invalid OpenGL PBO upload request";
      return false;
    }

    if (slot.buffers[0] == 0u || slot.buffers[1] == 0u) {
      glGenBuffers_(static_cast<int>(slot.buffers.size()), slot.buffers.data());
      if (slot.buffers[0] == 0u || slot.buffers[1] == 0u) {
        error = "glGenBuffers returned an invalid PBO";
        return false;
      }
    }

    if (SDL_RenderFlush(renderer) != 0) {
      error = std::string{"SDL_RenderFlush failed: "} + SDL_GetError();
      return false;
    }
    if (SDL_GL_BindTexture(texture, nullptr, nullptr) != 0) {
      error = std::string{"SDL_GL_BindTexture failed: "} + SDL_GetError();
      return false;
    }

    const size_t bytes = static_cast<size_t>(width) * static_cast<size_t>(height) * 3u;
    const GlUInt buffer = slot.buffers[slot.next];
    glBindBuffer_(kGlPixelUnpackBuffer, buffer);
    glBufferData_(kGlPixelUnpackBuffer, static_cast<GlSize>(bytes), nullptr, kGlStreamDraw);

    void* mapped = glMapBufferRange_(
        kGlPixelUnpackBuffer, 0, static_cast<GlSize>(bytes),
        kGlMapWriteBit | kGlMapInvalidateBufferBit);
    if (mapped == nullptr) {
      glBindBuffer_(kGlPixelUnpackBuffer, 0u);
      SDL_GL_UnbindTexture(texture);
      error = "glMapBufferRange returned null";
      return false;
    }

    std::memcpy(mapped, rgb, bytes);
    if (glUnmapBuffer_(kGlPixelUnpackBuffer) == 0u) {
      glBindBuffer_(kGlPixelUnpackBuffer, 0u);
      SDL_GL_UnbindTexture(texture);
      error = "glUnmapBuffer reported corrupted PBO data";
      return false;
    }

    // RGB24 rows are not necessarily four-byte aligned (1431 * 3 = 4293).
    glPixelStorei_(kGlUnpackAlignment, 1);
    glTexSubImage2D_(kGlTexture2d, 0, 0, 0,
                     static_cast<int>(width), static_cast<int>(height),
                     kGlRgb, kGlUnsignedByte, nullptr);
    glPixelStorei_(kGlUnpackAlignment, 4);
    glBindBuffer_(kGlPixelUnpackBuffer, 0u);
    SDL_GL_UnbindTexture(texture);

    slot.next = (slot.next + 1u) % slot.buffers.size();
    return true;
  }

  void destroy(GlPboSlot& slot) {
    if (glDeleteBuffers_ != nullptr && (slot.buffers[0] != 0u || slot.buffers[1] != 0u)) {
      glDeleteBuffers_(static_cast<int>(slot.buffers.size()), slot.buffers.data());
    }
    slot = {};
  }

 private:
  template <typename Function>
  bool load(Function& function, const char* name, std::string& error) {
    void* symbol = SDL_GL_GetProcAddress(name);
    if (symbol == nullptr) {
      error = std::string{"OpenGL symbol unavailable: "} + name;
      return false;
    }
    static_assert(sizeof(function) == sizeof(symbol));
    std::memcpy(&function, &symbol, sizeof(function));
    return true;
  }

  using GenBuffers = void (*)(int, GlUInt*);
  using DeleteBuffers = void (*)(int, const GlUInt*);
  using BindBuffer = void (*)(GlEnum, GlUInt);
  using BufferData = void (*)(GlEnum, GlSize, const void*, GlEnum);
  using MapBufferRange = void* (*)(GlEnum, GlSize, GlSize, GlBitfield);
  using UnmapBuffer = GlBoolean (*)(GlEnum);
  using PixelStorei = void (*)(GlEnum, int);
  using TexSubImage2D = void (*)(GlEnum, int, int, int, int, int, GlEnum, GlEnum, const void*);

  GenBuffers glGenBuffers_ = nullptr;
  DeleteBuffers glDeleteBuffers_ = nullptr;
  BindBuffer glBindBuffer_ = nullptr;
  BufferData glBufferData_ = nullptr;
  MapBufferRange glMapBufferRange_ = nullptr;
  UnmapBuffer glUnmapBuffer_ = nullptr;
  PixelStorei glPixelStorei_ = nullptr;
  TexSubImage2D glTexSubImage2D_ = nullptr;
  bool active_ = false;
};

struct StereoPairState {
  std::array<CameraStatus, 2> cameras{};
  bool valid = false;
  std::chrono::steady_clock::time_point lastPromote{};
};

struct RgbFrameView {
  const uint8_t* rgb = nullptr;
  uint32_t width = 0;
  uint32_t height = 0;
};

uint64_t frameTimestamp(const CameraStatus& camera) {
  return camera.frame ? camera.frame->timestampNs : 0ULL;
}

uint64_t hostDequeueTimestamp(const CameraStatus& camera) {
  if (!camera.frame) return 0ULL;
  return camera.frame->timing.hostDequeueNs != 0
             ? camera.frame->timing.hostDequeueNs
             : camera.frame->timestampNs;
}

double milliseconds(std::chrono::steady_clock::duration duration) {
  return std::chrono::duration<double, std::milli>(duration).count();
}

uint64_t nowNs() {
  return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(
      std::chrono::steady_clock::now().time_since_epoch()).count());
}

bool sameFrame(const CameraStatus& a, const CameraStatus& b) {
  return a.frame && b.frame && a.frame->id == b.frame->id;
}

uint64_t stereoSkew(const std::array<CameraStatus, 2>& cameras) {
  if (!cameras[0].frame || !cameras[1].frame) return UINT64_MAX;
  const uint64_t left = frameTimestamp(cameras[0]);
  const uint64_t right = frameTimestamp(cameras[1]);
  return left > right ? left - right : right - left;
}

void promoteStereoPair(StereoPairState& pair, const std::array<CameraStatus, 2>& candidate,
                       const std::chrono::steady_clock::time_point now) {
  pair.cameras = candidate;
  pair.valid = true;
  pair.lastPromote = now;
}

std::array<CameraStatus, 2> chooseStereoPair(
    StereoPairState& pair,
    const std::array<CameraStatus, 2>& latest,
    StereoPairingMode mode) {
  // Lowest-latency policy: never retain an older pair while a newer frame is
  // available. Startup phase alignment is handled separately by the camera
  // start gate. This is best-effort software synchronization, not exposure-
  // level hardware synchronization.
  if (mode == StereoPairingMode::Latest) {
    return latest;
  }

  const auto now = std::chrono::steady_clock::now();
  if (!pair.valid) {
    promoteStereoPair(pair, latest, now);
    return pair.cameras;
  }

  const bool leftNew = latest[0].frame && (!pair.cameras[0].frame || !sameFrame(latest[0], pair.cameras[0]));
  const bool rightNew = latest[1].frame && (!pair.cameras[1].frame || !sameFrame(latest[1], pair.cameras[1]));
  const bool stale = now - pair.lastPromote >= kMaxStereoHold;
  if ((leftNew || rightNew) && stereoSkew(latest) <= kMaxStereoSkewNs) {
    promoteStereoPair(pair, latest, now);
  } else if (stale && (leftNew || rightNew)) {
    promoteStereoPair(pair, latest, now);
  }
  return pair.cameras;
}

bool is2dMode(const core::DisplayControls& display) {
  return display.mainDisplayMode == "2D";
}

bool isLineInterleavedMode(const core::DisplayControls& display) {
  return display.mainDisplayMode == "3D" && display.stereoMode == "LineInterleaved";
}

int chooseDisplay(int requested, const std::string& requestedName) {
  const int count = SDL_GetNumVideoDisplays();
  if (requested >= 0 && requested < count) return requested;
  if (!requestedName.empty()) {
    for (int i = 0; i < count; ++i) {
      const char* name = SDL_GetDisplayName(i);
      if (name != nullptr && (requestedName == name || std::string(name).find(requestedName) != std::string::npos)) {
        return i;
      }
    }
  }
  int best = count > 0 ? 0 : -1;
  long long bestArea = -1;
  for (int i = 0; i < count; ++i) {
    SDL_Rect bounds{};
    if (SDL_GetDisplayBounds(i, &bounds) == 0) {
      const long long area = static_cast<long long>(bounds.w) * bounds.h;
      if (area > bestArea) { best = i; bestArea = area; }
    }
  }
  return best;
}

SDL_Texture* makeTexture(SDL_Renderer* renderer, uint32_t width, uint32_t height) {
  return SDL_CreateTexture(renderer, SDL_PIXELFORMAT_RGB24, SDL_TEXTUREACCESS_STREAMING,
                           static_cast<int>(width), static_cast<int>(height));
}

int uploadTexturePixels(SDL_Renderer* renderer, GlPboUploader* uploader,
                        TextureSlot& slot, const uint8_t* rgb,
                        uint32_t width, uint32_t height) {
  if (uploader != nullptr && uploader->active()) {
    std::string error;
    if (uploader->upload(renderer, slot.texture, slot.pbo, rgb, width, height, error)) {
      return 0;
    }
    std::cerr << "SBS Renderer: OpenGL PBO upload disabled; SDL fallback active: "
              << error << '\n';
    uploader->disable();
  }

  return SDL_UpdateTexture(
      slot.texture, nullptr, rgb, static_cast<int>(width * 3u));
}

SDL_Rect cropForZoom(uint32_t width, uint32_t height, double zoom) {
  zoom = std::clamp(zoom, 1.0, 8.0);
  const int w = std::max(1, static_cast<int>(width / zoom));
  const int h = std::max(1, static_cast<int>(height / zoom));
  return {static_cast<int>((width - w) / 2u), static_cast<int>((height - h) / 2u), w, h};
}

SDL_Rect cropForZoomAndAlign(uint32_t width, uint32_t height, double zoom, double alignXRatio, double alignYRatio) {
  SDL_Rect crop = cropForZoom(width, height, zoom);
  const int maxX = std::max(0, static_cast<int>(width) - crop.w);
  const int maxY = std::max(0, static_cast<int>(height) - crop.h);
  const int shiftX = static_cast<int>(std::lround(-alignXRatio * crop.w));
  const int shiftY = static_cast<int>(std::lround(-alignYRatio * crop.h));
  crop.x = std::clamp(crop.x + shiftX, 0, maxX);
  crop.y = std::clamp(crop.y + shiftY, 0, maxY);
  return crop;
}

std::pair<double, double> stereoAlignRatios(const core::DisplayControls& display, size_t cameraIndex) {
  if (!display.stereoAlignEnabled) return {0.0, 0.0};
  const double direction = cameraIndex == 0 ? -0.5 : 0.5;
  return {display.stereoAlignXRatio * direction, display.stereoAlignYRatio * direction};
}

RgbFrameView chooseFrame(TextureSlot& slot, const CameraStatus& camera, const core::CameraControls& controls,
                         uint8_t offlinePhase, std::vector<uint8_t>& offline) {
  std::shared_ptr<const Frame> selected = camera.frame;
  if (controls.frozen && slot.heldFrame) selected = slot.heldFrame;
  else if (selected) slot.heldFrame = selected;

  if (selected && selected->rgb && !selected->rgb->empty()) {
    return {selected->rgb->data(), selected->width, selected->height};
  }

  offline = makeOfflineRgb(960, 540, offlinePhase);
  return {offline.data(), 960, 540};
}

void cropAndScaleRgb(const RgbFrameView& source, double zoom, uint32_t targetWidth, uint32_t targetHeight,
                     std::vector<uint8_t>& cropped, std::vector<uint8_t>& scaled,
                     double alignXRatio = 0.0, double alignYRatio = 0.0) {
  if (source.rgb == nullptr || source.width == 0 || source.height == 0) {
    scaled.clear();
    return;
  }

  const SDL_Rect crop = cropForZoomAndAlign(source.width, source.height, zoom, alignXRatio, alignYRatio);
  if (crop.w == static_cast<int>(source.width) && crop.h == static_cast<int>(source.height)) {
    resizeRgbBilinearInto(source.rgb, source.width, source.height, targetWidth, targetHeight, scaled);
    return;
  }

  cropped.resize(static_cast<size_t>(crop.w) * crop.h * 3u);
  for (int row = 0; row < crop.h; ++row) {
    const size_t srcOffset =
        (static_cast<size_t>(crop.y + row) * source.width + static_cast<size_t>(crop.x)) * 3u;
    const size_t dstOffset = static_cast<size_t>(row) * static_cast<size_t>(crop.w) * 3u;
    std::copy_n(source.rgb + srcOffset, static_cast<size_t>(crop.w) * 3u, cropped.data() + dstOffset);
  }
  resizeRgbBilinearInto(cropped.data(), static_cast<uint32_t>(crop.w), static_cast<uint32_t>(crop.h),
                        targetWidth, targetHeight, scaled);
}

void mirrorRgb(std::vector<uint8_t>& rgb, uint32_t width, uint32_t height) {
  if (rgb.empty() || width == 0 || height == 0) return;
  for (uint32_t y = 0; y < height; ++y) {
    uint8_t* row = rgb.data() + static_cast<size_t>(y) * width * 3u;
    for (uint32_t x = 0; x < width / 2u; ++x) {
      uint8_t* left = row + static_cast<size_t>(x) * 3u;
      uint8_t* right = row + static_cast<size_t>(width - 1u - x) * 3u;
      for (size_t c = 0; c < 3u; ++c) std::swap(left[c], right[c]);
    }
  }
}

void composeLineInterleaved(TextureSlot& leftSlot, TextureSlot& rightSlot,
                            const std::array<CameraStatus, 2>& paired,
                            const std::array<core::CameraControls, 2>& controls,
                            const core::DisplayControls& display,
                            uint32_t width, uint32_t height,
                            std::vector<uint8_t>& output,
                            std::vector<uint8_t>& leftOffline,
                            std::vector<uint8_t>& rightOffline,
                            std::vector<uint8_t>& leftCrop,
                            std::vector<uint8_t>& rightCrop,
                            std::vector<uint8_t>& leftScaled,
                            std::vector<uint8_t>& rightScaled) {
  const auto leftSource = chooseFrame(leftSlot, paired[0], controls[0], 0u, leftOffline);
  const auto rightSource = chooseFrame(rightSlot, paired[1], controls[1], 23u, rightOffline);
  const auto [leftAlignXRatio, leftAlignYRatio] = stereoAlignRatios(display, 0);
  const auto [rightAlignXRatio, rightAlignYRatio] = stereoAlignRatios(display, 1);
  cropAndScaleRgb(leftSource, controls[0].zoom, width, height, leftCrop, leftScaled, leftAlignXRatio, leftAlignYRatio);
  cropAndScaleRgb(rightSource, controls[1].zoom, width, height, rightCrop, rightScaled, rightAlignXRatio, rightAlignYRatio);

  if (display.mirrorLeft) mirrorRgb(leftScaled, width, height);
  if (display.mirrorRight) mirrorRgb(rightScaled, width, height);

  output.resize(static_cast<size_t>(width) * height * 3u);
  for (uint32_t y = 0; y < height; ++y) {
    const uint8_t* sourceRow = (y % 2u == 0u) ? leftScaled.data() : rightScaled.data();
    const size_t offset = static_cast<size_t>(y) * width * 3u;
    std::copy_n(sourceRow + offset, static_cast<size_t>(width) * 3u, output.data() + offset);
  }
}

void renderFrame(SDL_Renderer* renderer, GlPboUploader* uploader, TextureSlot& slot,
                 const CameraStatus& camera, const core::CameraControls& controls,
                 const SDL_Rect& destination,
                 bool mirror, uint8_t offlinePhase, double alignXRatio = 0.0, double alignYRatio = 0.0) {
  std::shared_ptr<const Frame> selected = camera.frame;
  if (controls.frozen && slot.heldFrame) selected = slot.heldFrame;
  else if (selected) slot.heldFrame = selected;

  if (selected && selected->rgb && !selected->rgb->empty()) {
    if (slot.texture == nullptr || slot.width != selected->width || slot.height != selected->height) {
      if (slot.texture) SDL_DestroyTexture(slot.texture);
      slot.texture = makeTexture(renderer, selected->width, selected->height);
      slot.width = selected->width;
      slot.height = selected->height;
      slot.frameId = 0;
    }
    if (slot.texture && slot.frameId != selected->id) {
      const auto uploadStart = std::chrono::steady_clock::now();
      const int updateStatus = uploadTexturePixels(
          renderer, uploader, slot, selected->rgb->data(),
          selected->width, selected->height);
      const auto uploadEnd = std::chrono::steady_clock::now();
      slot.lastUploadMs = milliseconds(uploadEnd - uploadStart);
      slot.uploadedThisLoop = true;
      if (updateStatus == 0) {
        slot.frameId = selected->id;
      } else {
        std::cerr << "SDL texture update failed: " << SDL_GetError() << '\n';
      }
    }
  } else if (slot.texture == nullptr) {
    const uint32_t width = 960;
    const uint32_t height = 540;
    const auto offline = makeOfflineRgb(width, height, offlinePhase);
    slot.texture = makeTexture(renderer, width, height);
    slot.width = width;
    slot.height = height;
    if (slot.texture) {
      uploadTexturePixels(renderer, uploader, slot, offline.data(), width, height);
    }
  }

  if (!slot.texture) return;
  SDL_Rect source = cropForZoomAndAlign(slot.width, slot.height, controls.zoom, alignXRatio, alignYRatio);
  const SDL_RendererFlip flip = mirror ? SDL_FLIP_HORIZONTAL : SDL_FLIP_NONE;
  SDL_RenderCopyEx(renderer, slot.texture, &source, &destination,
                   static_cast<double>(controls.rotation), nullptr, flip);
}

void renderTexture(SDL_Renderer* renderer, GlPboUploader* uploader, TextureSlot& slot,
                   const std::vector<uint8_t>& rgb, uint32_t width, uint32_t height,
                   const SDL_Rect& destination) {
  if (slot.texture == nullptr || slot.width != width || slot.height != height) {
    if (slot.texture) SDL_DestroyTexture(slot.texture);
    slot.texture = makeTexture(renderer, width, height);
    slot.width = width;
    slot.height = height;
  }
  if (!slot.texture || rgb.empty()) return;
  const auto uploadStart = std::chrono::steady_clock::now();
  const int updateStatus =
      uploadTexturePixels(renderer, uploader, slot, rgb.data(), width, height);
  const auto uploadEnd = std::chrono::steady_clock::now();
  slot.lastUploadMs = milliseconds(uploadEnd - uploadStart);
  slot.uploadedThisLoop = true;
  if (updateStatus != 0) {
    std::cerr << "SDL composite texture update failed: " << SDL_GetError() << '\n';
    return;
  }
  SDL_RenderCopyEx(renderer, slot.texture, nullptr, &destination, 0.0, nullptr, SDL_FLIP_NONE);
}

}  // namespace

SbsRenderer::SbsRenderer(CameraManager& cameras, core::AppState& state, const core::Config& config)
    : cameras_(cameras), state_(state), config_(config) {}
SbsRenderer::~SbsRenderer() { stop(); }

bool SbsRenderer::start() {
  if (!config_.renderMainDisplay || config_.headless || running_.exchange(true)) return false;
  worker_ = std::thread(&SbsRenderer::loop, this);
  return true;
}

void SbsRenderer::stop() {
  running_ = false;
  if (worker_.joinable()) worker_.join();
}

void SbsRenderer::loop() {
  elevateRendererPriority();
  const bool pboRequested = envEnabled("PULSAR_GL_PBO_UPLOAD");
  const StereoPairingMode pairingMode = stereoPairingModeFromEnvironment();
  std::cerr << "SBS Renderer: direct-rtx-single-target=1 vsync=" << (envEnabled("PULSAR_SBS_PRESENT_VSYNC", false) ? "on" : "off") << '\n';
  std::cerr << "SBS Renderer: stereo-pairing-mode="
            << stereoPairingModeName(pairingMode) << '\n';
  SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, "1");
  if (pboRequested) SDL_SetHint(SDL_HINT_RENDER_DRIVER, "opengl");
  if (SDL_InitSubSystem(SDL_INIT_VIDEO) != 0) {
    std::cerr << "SDL video init failed: " << SDL_GetError() << '\n';
    running_ = false;
    return;
  }
  displayIndex_ = chooseDisplay(config_.mainDisplayIndex, config_.mainDisplayName);
  if (displayIndex_ < 0) {
    std::cerr << "No SDL display was found for the SBS renderer.\n";
    SDL_QuitSubSystem(SDL_INIT_VIDEO);
    running_ = false;
    return;
  }
  SDL_Rect bounds{};
  SDL_GetDisplayBounds(displayIndex_, &bounds);
  SDL_Window* window = SDL_CreateWindow("Pulsar SBS", bounds.x, bounds.y, bounds.w, bounds.h,
      SDL_WINDOW_BORDERLESS | SDL_WINDOW_SHOWN | SDL_WINDOW_ALLOW_HIGHDPI);
  if (!window) {
    std::cerr << "SDL window creation failed: " << SDL_GetError() << '\n';
    SDL_QuitSubSystem(SDL_INIT_VIDEO);
    running_ = false;
    return;
  }
  SDL_SetWindowFullscreen(window, SDL_WINDOW_FULLSCREEN_DESKTOP);
  uint32_t rendererFlags = SDL_RENDERER_ACCELERATED;
  if (envEnabled("PULSAR_SBS_PRESENT_VSYNC", false)) {
    rendererFlags |= SDL_RENDERER_PRESENTVSYNC;
  }
  SDL_Renderer* renderer = SDL_CreateRenderer(window, -1, rendererFlags);
  if (!renderer) renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_SOFTWARE);
  if (!renderer) {
    std::cerr << "SDL renderer creation failed: " << SDL_GetError() << '\n';
    SDL_DestroyWindow(window);
    SDL_QuitSubSystem(SDL_INIT_VIDEO);
    running_ = false;
    return;
  }

  SDL_RendererInfo rendererInfo{};
  if (SDL_GetRendererInfo(renderer, &rendererInfo) == 0 && rendererInfo.name != nullptr) {
    std::cerr << "SBS Renderer: backend=" << rendererInfo.name
              << " flags=" << rendererInfo.flags << '\n';
  }

  GlPboUploader pboUploader;
  if (pboRequested) {
    std::string pboError;
    if (pboUploader.initialize(renderer, pboError)) {
      std::cerr << "SBS Renderer: OpenGL PBO upload ready (double-buffered canary)\n";
    } else {
      std::cerr << "SBS Renderer: OpenGL PBO unavailable; SDL fallback active: "
                << pboError << '\n';
    }
  }
  GlPboUploader* uploader = pboUploader.active() ? &pboUploader : nullptr;

  std::array<TextureSlot, 2> textures{};
  TextureSlot composite{};
  StereoPairState stereoPair{};
  std::vector<uint8_t> leftOffline;
  std::vector<uint8_t> rightOffline;
  std::vector<uint8_t> leftCrop;
  std::vector<uint8_t> rightCrop;
  std::vector<uint8_t> leftScaled;
  std::vector<uint8_t> rightScaled;
  std::vector<uint8_t> lineInterleaved;

  uint64_t reportLoops = 0;
  uint64_t ageSamples = 0;
  uint64_t skewSamples = 0;
  uint64_t uploadSamples = 0;
  double leftAgeMsSum = 0.0;
  double rightAgeMsSum = 0.0;
  double stereoSkewMsSum = 0.0;
  double uploadMsSum = 0.0;
  double uploadMsMax = 0.0;
  double presentMsSum = 0.0;
  double presentMsMax = 0.0;
  double cameraFrameIdDeltaSum = 0.0;
  uint64_t cameraFrameIdDeltaSamples = 0;
  uint64_t heldPairLoops = 0;
  auto reportStart = std::chrono::steady_clock::now();

  while (running_) {
    for (auto& slot : textures) {
      slot.uploadedThisLoop = false;
      slot.lastUploadMs = 0.0;
    }
    composite.uploadedThisLoop = false;
    composite.lastUploadMs = 0.0;
    int width = 0, height = 0;
    SDL_GetRendererOutputSize(renderer, &width, &height);
    const auto state = state_.snapshot();
    const std::array<CameraStatus, 2> latest{{cameras_.snapshot(0), cameras_.snapshot(1)}};
    const auto paired = chooseStereoPair(stereoPair, latest, pairingMode);
    const int gap = std::clamp(state.display.gapPx, 0, std::max(0, width / 4));
    const int halfWidth = std::max(1, (width - gap) / 2);
    std::array<SDL_Rect, 2> destinations{{{0, 0, halfWidth, height}, {halfWidth + gap, 0, width - halfWidth - gap, height}}};
    std::array<size_t, 2> sourceIndex{{0, 1}};
    if (state.display.swapEyes) std::swap(sourceIndex[0], sourceIndex[1]);

    SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
    SDL_RenderClear(renderer);
    if (is2dMode(state.display)) {
      const size_t cameraIndex = state.display.swapEyes ? 1u : 0u;
      const bool mirror = cameraIndex == 0 ? state.display.mirrorLeft : state.display.mirrorRight;
      const auto [alignXRatio, alignYRatio] = stereoAlignRatios(state.display, cameraIndex);
      renderFrame(renderer, uploader, textures[cameraIndex], paired[cameraIndex], state.cameras[cameraIndex],
                  SDL_Rect{0, 0, width, height}, mirror, static_cast<uint8_t>(cameraIndex * 23u), alignXRatio, alignYRatio);
    } else if (isLineInterleavedMode(state.display)) {
      composeLineInterleaved(textures[0], textures[1], paired, state.cameras, state.display,
                             static_cast<uint32_t>(width), static_cast<uint32_t>(height),
                             lineInterleaved, leftOffline, rightOffline, leftCrop, rightCrop, leftScaled, rightScaled);
      renderTexture(renderer, uploader, composite, lineInterleaved, static_cast<uint32_t>(width), static_cast<uint32_t>(height),
                    SDL_Rect{0, 0, width, height});
    } else {
      for (size_t side = 0; side < 2; ++side) {
        const size_t cameraIndex = sourceIndex[side];
        const bool mirror = cameraIndex == 0 ? state.display.mirrorLeft : state.display.mirrorRight;
        const auto [alignXRatio, alignYRatio] = stereoAlignRatios(state.display, cameraIndex);
        renderFrame(renderer, uploader, textures[cameraIndex], paired[cameraIndex], state.cameras[cameraIndex],
                    destinations[side], mirror, static_cast<uint8_t>(cameraIndex * 23u), alignXRatio, alignYRatio);
      }
    }
    const uint64_t ageNowNs = nowNs();
    if (paired[0].frame && paired[1].frame) {
      const uint64_t leftDequeueNs = hostDequeueTimestamp(paired[0]);
      const uint64_t rightDequeueNs = hostDequeueTimestamp(paired[1]);
      if (leftDequeueNs != 0 && rightDequeueNs != 0 &&
          ageNowNs >= leftDequeueNs && ageNowNs >= rightDequeueNs) {
        leftAgeMsSum += static_cast<double>(ageNowNs - leftDequeueNs) / 1'000'000.0;
        rightAgeMsSum += static_cast<double>(ageNowNs - rightDequeueNs) / 1'000'000.0;
        ++ageSamples;

        const uint64_t skewNs = leftDequeueNs > rightDequeueNs
                                    ? leftDequeueNs - rightDequeueNs
                                    : rightDequeueNs - leftDequeueNs;
        stereoSkewMsSum += static_cast<double>(skewNs) / 1'000'000.0;
        ++skewSamples;

        const uint64_t leftCameraId = paired[0].frame->timing.cameraFrameId;
        const uint64_t rightCameraId = paired[1].frame->timing.cameraFrameId;
        if (leftCameraId != 0 && rightCameraId != 0) {
          const uint64_t delta = leftCameraId > rightCameraId
                                     ? leftCameraId - rightCameraId
                                     : rightCameraId - leftCameraId;
          cameraFrameIdDeltaSum += static_cast<double>(delta);
          ++cameraFrameIdDeltaSamples;
        }
      }
    }

    if (pairingMode == StereoPairingMode::LegacyHold &&
        ((latest[0].frame && paired[0].frame &&
          latest[0].frame->id != paired[0].frame->id) ||
         (latest[1].frame && paired[1].frame &&
          latest[1].frame->id != paired[1].frame->id))) {
      ++heldPairLoops;
    }

    for (const auto& slot : textures) {
      if (slot.uploadedThisLoop) {
        uploadMsSum += slot.lastUploadMs;
        uploadMsMax = std::max(uploadMsMax, slot.lastUploadMs);
        ++uploadSamples;
      }
    }
    if (composite.uploadedThisLoop) {
      uploadMsSum += composite.lastUploadMs;
      uploadMsMax = std::max(uploadMsMax, composite.lastUploadMs);
      ++uploadSamples;
    }

    const auto presentStart = std::chrono::steady_clock::now();
    SDL_RenderPresent(renderer);
    const auto presentEnd = std::chrono::steady_clock::now();
    const double presentMs = milliseconds(presentEnd - presentStart);
    presentMsSum += presentMs;
    presentMsMax = std::max(presentMsMax, presentMs);
    ++reportLoops;

    const std::chrono::duration<double> reportElapsed = presentEnd - reportStart;
    if (reportElapsed.count() >= 2.0) {
      const double loopDivisor = static_cast<double>(std::max<uint64_t>(1, reportLoops));
      const double ageDivisor = static_cast<double>(std::max<uint64_t>(1, ageSamples));
      const double skewDivisor = static_cast<double>(std::max<uint64_t>(1, skewSamples));
      const double uploadDivisor = static_cast<double>(std::max<uint64_t>(1, uploadSamples));
      const double frameIdDivisor =
          static_cast<double>(std::max<uint64_t>(1, cameraFrameIdDeltaSamples));

      std::cerr << "SBS Renderer: latency-stats"
                << " pairing-mode=" << stereoPairingModeName(pairingMode)
                << " loop-fps=" << (static_cast<double>(reportLoops) / reportElapsed.count())
                << " left-host-age-ms=" << (leftAgeMsSum / ageDivisor)
                << " right-host-age-ms=" << (rightAgeMsSum / ageDivisor)
                << " stereo-host-skew-ms=" << (stereoSkewMsSum / skewDivisor)
                << " camera-frame-id-delta="
                << (cameraFrameIdDeltaSum / frameIdDivisor)
                << " texture-upload-ms=" << (uploadMsSum / uploadDivisor)
                << " texture-upload-max-ms=" << uploadMsMax
                << " upload-path=" << (pboUploader.active() ? "gl-pbo" : "sdl")
                << " present-ms=" << (presentMsSum / loopDivisor)
                << " present-max-ms=" << presentMsMax
                << " held-pair-loops=" << heldPairLoops << '\n';

      reportLoops = 0;
      ageSamples = 0;
      skewSamples = 0;
      uploadSamples = 0;
      leftAgeMsSum = 0.0;
      rightAgeMsSum = 0.0;
      stereoSkewMsSum = 0.0;
      uploadMsSum = 0.0;
      uploadMsMax = 0.0;
      presentMsSum = 0.0;
      presentMsMax = 0.0;
      cameraFrameIdDeltaSum = 0.0;
      cameraFrameIdDeltaSamples = 0;
      heldPairLoops = 0;
      reportStart = presentEnd;
    }
  }

  for (auto& slot : textures) pboUploader.destroy(slot.pbo);
  pboUploader.destroy(composite.pbo);
  for (auto& slot : textures) if (slot.texture) SDL_DestroyTexture(slot.texture);
  if (composite.texture) SDL_DestroyTexture(composite.texture);
  SDL_DestroyRenderer(renderer);
  SDL_DestroyWindow(window);
  SDL_QuitSubSystem(SDL_INIT_VIDEO);
}

}  // namespace pulsar::camera
