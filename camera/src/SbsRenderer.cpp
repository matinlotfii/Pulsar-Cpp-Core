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
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <optional>
#include <pthread.h>
#include <sstream>
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
constexpr GlBitfield kGlMapUnsynchronizedBit = 0x0020u;
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
  std::array<GlUInt, 3> buffers{};
  std::array<size_t, 3> capacities{};
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
    const size_t bufferIndex = slot.next;
    const GlUInt buffer = slot.buffers[bufferIndex];
    glBindBuffer_(kGlPixelUnpackBuffer, buffer);

    // Allocate each PBO only when the frame size grows. The previous code
    // orphaned and reallocated a multi-megabyte buffer for every camera frame,
    // which dominated upload time on X11/PRIME. Three rotating PBOs give the
    // GPU more than two camera periods before the same storage is reused.
    if (slot.capacities[bufferIndex] < bytes) {
      glBufferData_(
          kGlPixelUnpackBuffer,
          static_cast<GlSize>(bytes),
          nullptr,
          kGlStreamDraw);
      slot.capacities[bufferIndex] = bytes;
    }

    void* mapped = glMapBufferRange_(
        kGlPixelUnpackBuffer, 0, static_cast<GlSize>(bytes),
        kGlMapWriteBit | kGlMapInvalidateBufferBit |
            kGlMapUnsynchronizedBit);
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

std::vector<std::string> splitList(const std::string& value, char delimiter) {
  std::vector<std::string> items;
  std::istringstream stream(value);
  std::string item;
  while (std::getline(stream, item, delimiter)) {
    if (!item.empty()) items.push_back(item);
  }
  return items;
}

SDL_Rect parseGeometry(const std::string& geometry) {
  SDL_Rect rect{};
  int width = 0;
  int height = 0;
  int x = 0;
  int y = 0;
  if (std::sscanf(geometry.c_str(), "%dx%d+%d+%d", &width, &height, &x, &y) == 4) {
    rect = {x, y, width, height};
  }
  return rect;
}


struct ViewerPanel {
  size_t profileIndex = 0;
  SDL_Rect rect{};
};

struct ViewerLayout {
  SDL_Rect bounds{};
  std::vector<ViewerPanel> panels;
  std::string generation;
};

std::optional<ViewerPanel> parsePanelSpec(const std::string& value) {
  const auto separator = value.find(':');
  if (separator == std::string::npos) return std::nullopt;
  char* end = nullptr;
  const unsigned long profile = std::strtoul(value.substr(0, separator).c_str(), &end, 10);
  if (end == nullptr || *end != '\0' || profile > 2) return std::nullopt;
  const SDL_Rect rect = parseGeometry(value.substr(separator + 1));
  if (rect.w <= 0 || rect.h <= 0) return std::nullopt;
  return ViewerPanel{static_cast<size_t>(profile), rect};
}

ViewerLayout loadViewerLayout(const std::filesystem::path& path,
                              const SDL_Rect& fallbackBounds) {
  ViewerLayout layout;
  layout.bounds = parseGeometry(
      envString("PULSAR_VIEWER_CANVAS_GEOMETRY", ""));
  std::string panelSpecs = envString("PULSAR_VIEWER_PANEL_SPECS", "");

  std::ifstream input(path);
  std::string line;
  while (std::getline(input, line)) {
    if (line.empty() || line[0] == '#') continue;
    const auto separator = line.find('=');
    if (separator == std::string::npos) continue;
    const std::string key = line.substr(0, separator);
    const std::string value = line.substr(separator + 1);
    if (key == "PULSAR_VIEWER_CANVAS_GEOMETRY") {
      layout.bounds = parseGeometry(value);
    } else if (key == "PULSAR_VIEWER_PANEL_SPECS") {
      panelSpecs = value;
    } else if (key == "PULSAR_VIEWER_LAYOUT_GENERATION") {
      layout.generation = value;
    }
  }

  if (layout.bounds.w <= 0 || layout.bounds.h <= 0) {
    layout.bounds = fallbackBounds;
  }
  if (layout.bounds.w <= 0 || layout.bounds.h <= 0) {
    layout.bounds = SDL_Rect{0, 0, 1, 1};
  }

  for (const auto& item : splitList(panelSpecs, ';')) {
    if (const auto panel = parsePanelSpec(item)) layout.panels.push_back(*panel);
  }
  return layout;
}

bool sameLayout(const ViewerLayout& left, const ViewerLayout& right) {
  if (left.bounds.x != right.bounds.x || left.bounds.y != right.bounds.y ||
      left.bounds.w != right.bounds.w || left.bounds.h != right.bounds.h ||
      left.panels.size() != right.panels.size()) {
    return false;
  }
  for (size_t i = 0; i < left.panels.size(); ++i) {
    const auto& a = left.panels[i];
    const auto& b = right.panels[i];
    if (a.profileIndex != b.profileIndex || a.rect.x != b.rect.x ||
        a.rect.y != b.rect.y || a.rect.w != b.rect.w ||
        a.rect.h != b.rect.h) {
      return false;
    }
  }
  return true;
}

std::string outputModeFor(const core::DisplayControls& display, size_t profileIndex) {
  if (profileIndex < display.outputModes.size()) {
    const auto& mode = display.outputModes[profileIndex];
    if (mode == "2D" || mode == "3D") return mode;
  }
  return profileIndex == 0 ? display.mainDisplayMode : "3D";
}

bool is2dMode(const core::DisplayControls& display, size_t profileIndex) {
  return outputModeFor(display, profileIndex) == "2D";
}

bool isLineInterleavedMode(const core::DisplayControls& display, size_t profileIndex) {
  return outputModeFor(display, profileIndex) == "3D" &&
         display.stereoMode == "LineInterleaved";
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

void prepareFrameTexture(
    SDL_Renderer* renderer,
    GlPboUploader* uploader,
    TextureSlot& slot,
    const CameraStatus& camera,
    const core::CameraControls& controls,
    uint8_t offlinePhase) {
  std::shared_ptr<const Frame> selected = camera.frame;
  if (controls.frozen && slot.heldFrame) {
    selected = slot.heldFrame;
  } else if (selected) {
    slot.heldFrame = selected;
  }

  if (selected && selected->rgb && !selected->rgb->empty()) {
    if (slot.texture == nullptr || slot.width != selected->width ||
        slot.height != selected->height) {
      if (slot.texture) SDL_DestroyTexture(slot.texture);
      slot.texture = makeTexture(renderer, selected->width, selected->height);
      slot.width = selected->width;
      slot.height = selected->height;
      slot.frameId = 0;
    }

    if (slot.texture && slot.frameId != selected->id) {
      const auto uploadStart = std::chrono::steady_clock::now();
      const int updateStatus = uploadTexturePixels(
          renderer,
          uploader,
          slot,
          selected->rgb->data(),
          selected->width,
          selected->height);
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
      uploadTexturePixels(
          renderer,
          uploader,
          slot,
          offline.data(),
          width,
          height);
    }
  }
}

void renderFrame(
    SDL_Renderer* renderer,
    GlPboUploader* uploader,
    TextureSlot& slot,
    const CameraStatus& camera,
    const core::CameraControls& controls,
    const SDL_Rect& destination,
    bool mirror,
    uint8_t offlinePhase,
    double alignXRatio = 0.0,
    double alignYRatio = 0.0) {
  // Normally this is already prepared once before any panel is drawn. Keep
  // the guarded call here for frozen/offline transitions and future callers.
  prepareFrameTexture(
      renderer,
      uploader,
      slot,
      camera,
      controls,
      offlinePhase);

  if (!slot.texture) return;

  SDL_Rect source = cropForZoomAndAlign(
      slot.width,
      slot.height,
      controls.zoom,
      alignXRatio,
      alignYRatio);
  const SDL_RendererFlip flip = mirror
      ? SDL_FLIP_HORIZONTAL
      : SDL_FLIP_NONE;
  SDL_RenderCopyEx(
      renderer,
      slot.texture,
      &source,
      &destination,
      static_cast<double>(controls.rotation),
      nullptr,
      flip);
}

void renderTexture(SDL_Renderer* renderer, GlPboUploader* uploader, TextureSlot& slot,
                   const std::vector<uint8_t>& rgb, uint32_t width, uint32_t height,
                   uint64_t frameKey, const SDL_Rect& destination) {
  if (slot.texture == nullptr || slot.width != width || slot.height != height) {
    if (slot.texture) SDL_DestroyTexture(slot.texture);
    slot.texture = makeTexture(renderer, width, height);
    slot.width = width;
    slot.height = height;
    slot.frameId = 0;
  }
  if (!slot.texture || rgb.empty()) return;
  if (slot.frameId != frameKey) {
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
    slot.frameId = frameKey;
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
  SDL_SetHint("SDL_RENDER_VSYNC", "0");
  SDL_SetHint("SDL_RENDER_BATCHING", "1");
  SDL_SetHint("SDL_VIDEO_X11_NET_WM_BYPASS_COMPOSITOR", "1");
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

  SDL_Rect fallbackBounds{};
  SDL_GetDisplayBounds(displayIndex_, &fallbackBounds);
  const std::filesystem::path layoutPath =
      config_.dataRoot / "viewer-layout.env";
  ViewerLayout viewerLayout = loadViewerLayout(layoutPath, fallbackBounds);
  SDL_Rect bounds = viewerLayout.bounds;
  std::vector<ViewerPanel> panels = viewerLayout.panels;

  SDL_Window* window = SDL_CreateWindow(
      "Pulsar Multi-Output Viewer", bounds.x, bounds.y, bounds.w, bounds.h,
      SDL_WINDOW_BORDERLESS | SDL_WINDOW_SHOWN | SDL_WINDOW_ALLOW_HIGHDPI);
  if (!window) {
    std::cerr << "SDL window creation failed: " << SDL_GetError() << '\n';
    SDL_QuitSubSystem(SDL_INIT_VIDEO);
    running_ = false;
    return;
  }
  std::cerr << "SBS Renderer: viewer-layout-ready=1 dynamic=1 canvas="
            << bounds.w << "x" << bounds.h << "+" << bounds.x << "+" << bounds.y
            << " panels=" << panels.size()
            << " shared-texture-upload=1 profiles=3" << '\n';
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

  const int swapIntervalStatus = SDL_GL_SetSwapInterval(0);
  std::cerr << "SBS Renderer: explicit-swap-interval=0 status="
            << swapIntervalStatus;
  if (swapIntervalStatus != 0) {
    std::cerr << " error=" << SDL_GetError();
  }
  std::cerr << '\n';

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
  auto nextLayoutCheck = reportStart;
  std::filesystem::file_time_type layoutWriteTime{};
  try {
    if (std::filesystem::exists(layoutPath)) {
      layoutWriteTime = std::filesystem::last_write_time(layoutPath);
    }
  } catch (...) {
  }

  const bool eventDriven = envEnabled("PULSAR_RENDER_EVENT_DRIVEN", true);
  std::array<uint64_t, 2> lastRenderedFrameIds{{0, 0}};
  auto nextIdleRedraw = reportStart;

  while (running_) {
    const auto loopNow = std::chrono::steady_clock::now();
    bool layoutChanged = false;
    if (loopNow >= nextLayoutCheck) {
      nextLayoutCheck = loopNow + std::chrono::milliseconds(200);
      bool changed = false;
      std::filesystem::file_time_type currentWrite{};
      try {
        if (std::filesystem::exists(layoutPath)) {
          currentWrite = std::filesystem::last_write_time(layoutPath);
          changed = currentWrite != layoutWriteTime;
        }
      } catch (...) {
      }
      if (changed) {
        ViewerLayout updated = loadViewerLayout(layoutPath, viewerLayout.bounds);
        layoutWriteTime = currentWrite;
        if (!sameLayout(viewerLayout, updated)) {
          viewerLayout = std::move(updated);
          bounds = viewerLayout.bounds;
          panels = viewerLayout.panels;
          SDL_SetWindowPosition(window, bounds.x, bounds.y);
          SDL_SetWindowSize(window, bounds.w, bounds.h);
          layoutChanged = true;
          std::cerr << "SBS Renderer: live-layout-update=1 canvas="
                    << bounds.w << "x" << bounds.h << "+" << bounds.x << "+" << bounds.y
                    << " panels=" << panels.size() << '\n';
        }
      }
    }
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

    // PULSAR_DEGRADED_MONO_FALLBACK_V1
    // If one USB camera is unavailable, duplicate the healthy camera onto all
    // physical outputs. True stereo resumes automatically when both return.
    auto renderPair = paired;
    auto renderControls = state.cameras;
    const bool degradedMono =
        static_cast<bool>(paired[0].frame) !=
        static_cast<bool>(paired[1].frame);

    if (!renderPair[0].frame && renderPair[1].frame) {
      renderPair[0] = renderPair[1];
      renderControls[0] = renderControls[1];
    } else if (!renderPair[1].frame && renderPair[0].frame) {
      renderPair[1] = renderPair[0];
      renderControls[1] = renderControls[0];
    }

    const uint64_t leftFrameId = renderPair[0].frame
        ? renderPair[0].frame->id
        : 0ULL;
    const uint64_t rightFrameId = renderPair[1].frame
        ? renderPair[1].frame->id
        : 0ULL;
    const bool frameChanged =
        leftFrameId != lastRenderedFrameIds[0] ||
        rightFrameId != lastRenderedFrameIds[1];
    const bool idleRedrawDue = loopNow >= nextIdleRedraw;

    if (eventDriven && !frameChanged && !layoutChanged && !idleRedrawDue) {
      CameraStatus waited{};
      bool ready = false;

      if (latest[0].frame) {
        ready = cameras_.waitForFrame(
            0,
            latest[0].frame->id,
            waited,
            1);
      }

      if (!ready && latest[1].frame) {
        ready = cameras_.waitForFrame(
            1,
            latest[1].frame->id,
            waited,
            1);
      }

      if (!ready && !latest[0].frame && !latest[1].frame) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
      }

      continue;
    }

    nextIdleRedraw = loopNow + std::chrono::milliseconds(50);

    // Upload each camera texture once before drawing any monitor/glass panel.
    // The same GPU textures are then reused for all active outputs.
    prepareFrameTexture(
        renderer, uploader, textures[0], renderPair[0], renderControls[0], 0u);
    prepareFrameTexture(
        renderer, uploader, textures[1], renderPair[1], renderControls[1], 23u);

    SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
    SDL_RenderClear(renderer);

    const uint64_t compositeKey =
        (leftFrameId * 0x9E3779B185EBCA87ULL) ^ rightFrameId;

    for (const auto& viewerPanel : panels) {
      const size_t profileIndex = viewerPanel.profileIndex;
      if (profileIndex >= 3) continue;
      const SDL_Rect panel = viewerPanel.rect;
      const int gap = std::clamp(
          state.display.gapPx, 0, std::max(0, panel.w / 4));
      const int halfWidth = std::max(1, (panel.w - gap) / 2);
      std::array<SDL_Rect, 2> destinations{{
          {panel.x, panel.y, halfWidth, panel.h},
          {panel.x + halfWidth + gap, panel.y,
           panel.w - halfWidth - gap, panel.h},
      }};
      std::array<size_t, 2> sourceIndex{{0, 1}};
      if (state.display.swapEyes) std::swap(sourceIndex[0], sourceIndex[1]);

      if (is2dMode(state.display, profileIndex)) {
        const size_t cameraIndex = state.display.swapEyes ? 1u : 0u;
        const bool mirror = cameraIndex == 0
                                ? state.display.mirrorLeft
                                : state.display.mirrorRight;
        const auto [alignXRatio, alignYRatio] =
            stereoAlignRatios(state.display, cameraIndex);
        renderFrame(
            renderer, uploader, textures[cameraIndex], renderPair[cameraIndex],
            renderControls[cameraIndex], panel, mirror,
            static_cast<uint8_t>(cameraIndex * 23u),
            alignXRatio, alignYRatio);
      } else if (isLineInterleavedMode(state.display, profileIndex)) {
        composeLineInterleaved(
            textures[0], textures[1], renderPair, renderControls, state.display,
            static_cast<uint32_t>(panel.w), static_cast<uint32_t>(panel.h),
            lineInterleaved, leftOffline, rightOffline, leftCrop, rightCrop,
            leftScaled, rightScaled);
        renderTexture(
            renderer, uploader, composite, lineInterleaved,
            static_cast<uint32_t>(panel.w), static_cast<uint32_t>(panel.h),
            compositeKey, panel);
      } else {
        for (size_t side = 0; side < 2; ++side) {
          const size_t cameraIndex = sourceIndex[side];
          const bool mirror = cameraIndex == 0
                                  ? state.display.mirrorLeft
                                  : state.display.mirrorRight;
          const auto [alignXRatio, alignYRatio] =
              stereoAlignRatios(state.display, cameraIndex);
          renderFrame(
              renderer, uploader, textures[cameraIndex], renderPair[cameraIndex],
              renderControls[cameraIndex], destinations[side], mirror,
              static_cast<uint8_t>(cameraIndex * 23u),
              alignXRatio, alignYRatio);
        }
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
    lastRenderedFrameIds = {{leftFrameId, rightFrameId}};
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
                << " degraded-mono=" << (degradedMono ? 1 : 0)
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
