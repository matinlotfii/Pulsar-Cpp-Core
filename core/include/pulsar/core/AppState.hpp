#pragma once

#include <array>
#include <cstdint>
#include <mutex>
#include <string>

namespace pulsar::core {

struct CameraControls {
  double zoom = 1.0;
  int focus = 0;
  int brightness = 60;
  double exposureUs = 29000.0;
  double gainDb = 6.0;
  bool autoExposure = false;
  std::string whiteBalance = "Manual";
  std::string enhance = "Low";
  int rotation = 0;
  bool frozen = false;
};

struct DisplayControls {
  std::string mainDisplayMode = "3D";
  bool swapEyes = false;
  int gapPx = 0;
  bool mirrorLeft = false;
  bool mirrorRight = false;
  std::string stereoMode = "SBS";
  bool stereoAlignEnabled = false;
  double stereoAlignX = 0.0;
  double stereoAlignY = 0.0;
  double stereoAlignXRatio = 0.0;
  double stereoAlignYRatio = 0.0;
  int targetFps = 60;
};

struct RecordingControls {
  bool active = false;
  std::string outputDirectory = "recordings";
  std::string lastFile;
  uint64_t elapsedSeconds = 0;
};

struct RobotControls {
  std::array<int, 6> motorPositions{0, 0, 0, 0, 0, 0};
};

struct SystemSnapshot {
  double memoryUsedPercent = 0.0;
  double cpuLoad = 0.0;
  uint64_t processRssBytes = 0;
  uint64_t uptimeSeconds = 0;
  std::string version = "1.0.0";
};

struct StateSnapshot {
  std::array<CameraControls, 2> cameras;
  DisplayControls display;
  RecordingControls recording;
  RobotControls robot;
  SystemSnapshot system;
  uint64_t revision = 0;
};

class AppState {
 public:
  StateSnapshot snapshot() const;
  CameraControls camera(size_t index) const;
  DisplayControls display() const;
  RecordingControls recording() const;
  RobotControls robot() const;

  bool updateCamera(size_t index, const CameraControls& value);
  void updateDisplay(const DisplayControls& value);
  void updateRecording(const RecordingControls& value);
  void updateRobot(const RobotControls& value);
  void updateSystem(const SystemSnapshot& value);

 private:
  mutable std::mutex mutex_;
  StateSnapshot state_;
};

}  // namespace pulsar::core
