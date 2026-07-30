#include "pulsar/core/Config.hpp"

#include <algorithm>
#include <cstdlib>
#include <string_view>

namespace pulsar::core {
namespace {

std::string envString(const char* name, std::string fallback) {
  const char* value = std::getenv(name);
  return value != nullptr && *value != '\0' ? value : std::move(fallback);
}

int envInt(const char* name, int fallback) {
  const char* value = std::getenv(name);
  if (value == nullptr || *value == '\0') return fallback;
  char* end = nullptr;
  const long parsed = std::strtol(value, &end, 10);
  return end != value ? static_cast<int>(parsed) : fallback;
}

bool envBool(const char* name, bool fallback) {
  const std::string value = envString(name, fallback ? "1" : "0");
  return value == "1" || value == "true" || value == "yes" || value == "on";
}

}  // namespace

Config loadConfig(int argc, char** argv) {
  Config config;
  config.host = envString("PULSAR_HOST", config.host);
  config.port = static_cast<uint16_t>(std::clamp(envInt("PULSAR_PORT", config.port), 1024, 65535));
  config.uiRoot = envString("PULSAR_UI_ROOT", config.uiRoot.string());
  config.dataRoot = envString("PULSAR_DATA_ROOT", config.dataRoot.string());
  config.cameraMode = envString("PULSAR_CAMERA_MODE", config.cameraMode);
  config.cameraSerials[0] = envString("PULSAR_LEFT_CAMERA_SERIAL", "");
  config.cameraSerials[1] = envString("PULSAR_RIGHT_CAMERA_SERIAL", "");
  config.headless = envBool("PULSAR_HEADLESS", config.headless);
  config.renderMainDisplay = envBool("PULSAR_RENDER_MAIN", config.renderMainDisplay);
  config.mainDisplayIndex = envInt("PULSAR_MAIN_DISPLAY", config.mainDisplayIndex);
  config.mainDisplayName = envString("PULSAR_MAIN_OUTPUT", config.mainDisplayName);
  config.settingsDisplayIndex = envInt("PULSAR_SETTINGS_DISPLAY", config.settingsDisplayIndex);
  config.cameraFps = std::clamp(envInt("PULSAR_CAMERA_FPS", config.cameraFps), 1, 120);
  config.previewFps = std::clamp(envInt("PULSAR_PREVIEW_FPS", config.previewFps), 1, 30);
  config.cameraMaxWidth = static_cast<uint32_t>(std::clamp(envInt("PULSAR_CAMERA_MAX_WIDTH", config.cameraMaxWidth), 320, 4096));
  config.cameraMaxHeight = static_cast<uint32_t>(std::clamp(envInt("PULSAR_CAMERA_MAX_HEIGHT", config.cameraMaxHeight), 240, 2160));
  config.jpegQuality = std::clamp(envInt("PULSAR_JPEG_QUALITY", config.jpegQuality), 50, 95);

  for (int i = 1; i < argc; ++i) {
    const std::string_view arg(argv[i]);
    if (arg == "--headless") config.headless = true;
    else if (arg == "--no-render") config.renderMainDisplay = false;
    else if (arg == "--mock") config.cameraMode = "mock";
    else if (arg == "--port" && i + 1 < argc) config.port = static_cast<uint16_t>(std::stoi(argv[++i]));
    else if (arg == "--host" && i + 1 < argc) config.host = argv[++i];
    else if (arg == "--ui-root" && i + 1 < argc) config.uiRoot = argv[++i];
    else if (arg == "--data-root" && i + 1 < argc) config.dataRoot = argv[++i];
  }
  if (config.headless) config.renderMainDisplay = false;
  return config;
}

}  // namespace pulsar::core
