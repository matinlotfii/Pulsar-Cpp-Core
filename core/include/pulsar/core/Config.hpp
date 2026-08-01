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

  // GalaxyView exported profile files.
  std::array<std::filesystem::path, 2> cameraProfilePaths{
      std::filesystem::path{"camera/profiles/FCU22080659.txt"},
      std::filesystem::path{"camera/profiles/FCU22080659.txt"}};

  // Import the GalaxyView profile before starting camera streaming.
  bool cameraProfileEnabled = true;

  // Ask Galaxy SDK to verify imported values.
  bool cameraProfileVerify = true;

  // If the profile is missing or cannot be imported,
  // do not silently start with different settings.
  bool cameraProfileRequired = true;

  bool headless = false;
  bool renderMainDisplay = true;

  int mainDisplayIndex = -1;
  std::string mainDisplayName;
  int settingsDisplayIndex = -1;

  int cameraFps = 60;
  int previewFps = 15;

  uint32_t cameraMaxWidth = 1280;
  uint32_t cameraMaxHeight = 720;
  int cameraSensorScale = 4;

  int cameraBrightness = 60;
  double cameraExposureUs = 29000.0;
  double cameraGainDb = 6.0;
  bool cameraAutoExposure = false;

  std::string cameraWhiteBalance = "Manual";
  std::string cameraEnhance = "Low";

  double cameraWhiteBalanceRed = 2.0;
  double cameraWhiteBalanceGreen = 1.0;
  double cameraWhiteBalanceBlue = 1.5;

  int jpegQuality = 88;
};

Config loadConfig(int argc, char** argv);

}  // namespace pulsar::core
