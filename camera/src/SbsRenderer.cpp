#include "pulsar/camera/SbsRenderer.hpp"

#include "pulsar/camera/JpegEncoder.hpp"

#include "pulsar/camera/SdlMinimal.hpp"
#include <algorithm>
#include <array>
#include <chrono>
#include <iostream>
#include <memory>
#include <string>
#include <vector>

namespace pulsar::camera {
namespace {

struct TextureSlot {
  SDL_Texture* texture = nullptr;
  uint32_t width = 0;
  uint32_t height = 0;
  uint64_t frameId = 0;
  std::shared_ptr<const Frame> heldFrame;
};

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

SDL_Rect cropForZoom(uint32_t width, uint32_t height, double zoom) {
  zoom = std::clamp(zoom, 1.0, 8.0);
  const int w = std::max(1, static_cast<int>(width / zoom));
  const int h = std::max(1, static_cast<int>(height / zoom));
  return {static_cast<int>((width - w) / 2u), static_cast<int>((height - h) / 2u), w, h};
}

void renderFrame(SDL_Renderer* renderer, TextureSlot& slot, const CameraStatus& camera,
                 const core::CameraControls& controls, const SDL_Rect& destination,
                 bool mirror, uint8_t offlinePhase) {
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
      SDL_UpdateTexture(slot.texture, nullptr, selected->rgb->data(), static_cast<int>(selected->width * 3u));
      slot.frameId = selected->id;
    }
  } else if (slot.texture == nullptr) {
    const uint32_t width = 960;
    const uint32_t height = 540;
    const auto offline = makeOfflineRgb(width, height, offlinePhase);
    slot.texture = makeTexture(renderer, width, height);
    slot.width = width;
    slot.height = height;
    if (slot.texture) SDL_UpdateTexture(slot.texture, nullptr, offline.data(), static_cast<int>(width * 3u));
  }

  if (!slot.texture) return;
  SDL_Rect source = cropForZoom(slot.width, slot.height, controls.zoom);
  const SDL_RendererFlip flip = mirror ? SDL_FLIP_HORIZONTAL : SDL_FLIP_NONE;
  SDL_RenderCopyEx(renderer, slot.texture, &source, &destination,
                   static_cast<double>(controls.rotation), nullptr, flip);
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
  SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, "1");
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
  SDL_Renderer* renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
  if (!renderer) renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_SOFTWARE);
  if (!renderer) {
    std::cerr << "SDL renderer creation failed: " << SDL_GetError() << '\n';
    SDL_DestroyWindow(window);
    SDL_QuitSubSystem(SDL_INIT_VIDEO);
    running_ = false;
    return;
  }

  std::array<TextureSlot, 2> textures{};
  while (running_) {
    int width = 0, height = 0;
    SDL_GetRendererOutputSize(renderer, &width, &height);
    const auto state = state_.snapshot();
    const int gap = std::clamp(state.display.gapPx, 0, std::max(0, width / 4));
    const int halfWidth = std::max(1, (width - gap) / 2);
    std::array<SDL_Rect, 2> destinations{{{0, 0, halfWidth, height}, {halfWidth + gap, 0, width - halfWidth - gap, height}}};
    std::array<size_t, 2> sourceIndex{{0, 1}};
    if (state.display.swapEyes) std::swap(sourceIndex[0], sourceIndex[1]);

    SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
    SDL_RenderClear(renderer);
    for (size_t side = 0; side < 2; ++side) {
      const size_t cameraIndex = sourceIndex[side];
      const auto camera = cameras_.snapshot(cameraIndex);
      const bool mirror = cameraIndex == 0 ? state.display.mirrorLeft : state.display.mirrorRight;
      renderFrame(renderer, textures[cameraIndex], camera, state.cameras[cameraIndex],
                  destinations[side], mirror, static_cast<uint8_t>(cameraIndex * 23u));
    }
    SDL_RenderPresent(renderer);
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }

  for (auto& slot : textures) if (slot.texture) SDL_DestroyTexture(slot.texture);
  SDL_DestroyRenderer(renderer);
  SDL_DestroyWindow(window);
  SDL_QuitSubSystem(SDL_INIT_VIDEO);
}

}  // namespace pulsar::camera
