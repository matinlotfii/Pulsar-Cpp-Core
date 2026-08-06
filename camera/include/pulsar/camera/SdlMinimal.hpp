#pragma once

#include <cstdint>

extern "C" {
struct SDL_Window;
struct SDL_Renderer;
struct SDL_Texture;
struct SDL_Rect { int x; int y; int w; int h; };
struct SDL_RendererInfo {
  const char* name;
  uint32_t flags;
  uint32_t num_texture_formats;
  uint32_t texture_formats[16];
  int max_texture_width;
  int max_texture_height;
};
enum SDL_RendererFlip { SDL_FLIP_NONE = 0x00000000, SDL_FLIP_HORIZONTAL = 0x00000001, SDL_FLIP_VERTICAL = 0x00000002 };

int SDL_InitSubSystem(uint32_t flags);
void SDL_QuitSubSystem(uint32_t flags);
const char* SDL_GetError(void);
int SDL_SetHint(const char* name, const char* value);
int SDL_GetNumVideoDisplays(void);
const char* SDL_GetDisplayName(int displayIndex);
int SDL_GetDisplayBounds(int displayIndex, SDL_Rect* rect);
SDL_Window* SDL_CreateWindow(const char* title, int x, int y, int w, int h, uint32_t flags);
int SDL_SetWindowFullscreen(SDL_Window* window, uint32_t flags);
void SDL_DestroyWindow(SDL_Window* window);
SDL_Renderer* SDL_CreateRenderer(SDL_Window* window, int index, uint32_t flags);
void SDL_DestroyRenderer(SDL_Renderer* renderer);
int SDL_GetRendererInfo(SDL_Renderer* renderer, SDL_RendererInfo* info);
int SDL_RenderFlush(SDL_Renderer* renderer);
int SDL_GetRendererOutputSize(SDL_Renderer* renderer, int* w, int* h);
int SDL_SetRenderDrawColor(SDL_Renderer* renderer, uint8_t r, uint8_t g, uint8_t b, uint8_t a);
int SDL_RenderClear(SDL_Renderer* renderer);
void SDL_RenderPresent(SDL_Renderer* renderer);
SDL_Texture* SDL_CreateTexture(SDL_Renderer* renderer, uint32_t format, int access, int w, int h);
void SDL_DestroyTexture(SDL_Texture* texture);
int SDL_UpdateTexture(SDL_Texture* texture, const SDL_Rect* rect, const void* pixels, int pitch);
int SDL_RenderCopyEx(SDL_Renderer* renderer, SDL_Texture* texture, const SDL_Rect* srcrect,
                     const SDL_Rect* dstrect, double angle, const void* center, SDL_RendererFlip flip);
void* SDL_GL_GetProcAddress(const char* proc);
int SDL_GL_BindTexture(SDL_Texture* texture, float* texw, float* texh);
int SDL_GL_UnbindTexture(SDL_Texture* texture);
}

inline constexpr uint32_t SDL_INIT_VIDEO = 0x00000020u;
inline constexpr uint32_t SDL_WINDOW_FULLSCREEN_DESKTOP = 0x00001001u;
inline constexpr uint32_t SDL_WINDOW_SHOWN = 0x00000004u;
inline constexpr uint32_t SDL_WINDOW_BORDERLESS = 0x00000010u;
inline constexpr uint32_t SDL_WINDOW_ALLOW_HIGHDPI = 0x00002000u;
inline constexpr uint32_t SDL_RENDERER_SOFTWARE = 0x00000001u;
inline constexpr uint32_t SDL_RENDERER_ACCELERATED = 0x00000002u;
inline constexpr uint32_t SDL_RENDERER_PRESENTVSYNC = 0x00000004u;
inline constexpr uint32_t SDL_PIXELFORMAT_RGB24 = 0x17101803u;
inline constexpr int SDL_TEXTUREACCESS_STREAMING = 1;
inline constexpr const char* SDL_HINT_RENDER_SCALE_QUALITY = "SDL_RENDER_SCALE_QUALITY";
inline constexpr const char* SDL_HINT_RENDER_DRIVER = "SDL_RENDER_DRIVER";
