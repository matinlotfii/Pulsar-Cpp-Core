#pragma once

#include <array>
#include <cstdint>
#include <filesystem>
#include <string>

namespace pulsar::core {

struct Config {
  std::string host = "127.0.0.1";
  uint16_t port = 4173;
  std::filesystem::path uiRoot = "ui/dist";
  std::filesystem::path dataRoot = "data";
  std::string cameraMode = "real";
  std::array<std::string, 2> cameraSerials{};
  bool headless = false;
  bool renderMainDisplay = true;
  int mainDisplayIndex = -1;
  std::string mainDisplayName;
  int settingsDisplayIndex = -1;
  int cameraFps = 30;
  int previewFps = 15;
  uint32_t cameraMaxWidth = 1280;
  uint32_t cameraMaxHeight = 720;
  int jpegQuality = 88;
};

Config loadConfig(int argc, char** argv);

}  // namespace pulsar::core
