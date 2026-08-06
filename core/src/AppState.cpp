#include "pulsar/core/AppState.hpp"

#include <algorithm>

namespace pulsar::core {
namespace {

CameraControls sanitize(CameraControls value) {
  value.zoom = std::clamp(value.zoom, 1.0, 8.0);
  value.focus = std::clamp(value.focus, -100, 100);
  value.brightness = std::clamp(value.brightness, 0, 100);
  value.exposureUs = std::clamp(value.exposureUs, 40.0, 1000000.0);
  value.gainDb = std::clamp(value.gainDb, 0.0, 24.0);
  value.rotation = ((value.rotation % 360) + 360) % 360;
  if (value.whiteBalance != "Auto" && value.whiteBalance != "Warm" &&
      value.whiteBalance != "Cool" && value.whiteBalance != "Manual") {
    value.whiteBalance = "Auto";
  }
  if (value.enhance != "Low" && value.enhance != "Medium" && value.enhance != "High") {
    value.enhance = "Medium";
  }
  return value;
}

DisplayControls sanitize(DisplayControls value) {
  auto sanitizeMode = [](std::string& mode) {
    if (mode != "2D" && mode != "3D") mode = "3D";
  };
  sanitizeMode(value.mainDisplayMode);
  for (auto& mode : value.outputModes) {
    sanitizeMode(mode);
  }
  value.mainDisplayMode = value.outputModes[0];
  for (auto& volume : value.outputVolumes) volume = std::clamp(volume, 0, 125);
  value.gapPx = std::clamp(value.gapPx, 0, 200);
  value.stereoAlignX = std::clamp(value.stereoAlignX, -4096.0, 4096.0);
  value.stereoAlignY = std::clamp(value.stereoAlignY, -4096.0, 4096.0);
  value.stereoAlignXRatio = std::clamp(value.stereoAlignXRatio, -0.35, 0.35);
  value.stereoAlignYRatio = std::clamp(value.stereoAlignYRatio, -0.35, 0.35);
  value.targetFps = std::clamp(value.targetFps, 24, 120);
  if (value.stereoMode == "Line Interleaved") {
    value.stereoMode = "LineInterleaved";
  }
  if (value.stereoMode != "SBS" && value.stereoMode != "LineInterleaved") {
    value.stereoMode = "SBS";
  }
  return value;
}

}  // namespace

StateSnapshot AppState::snapshot() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return state_;
}

CameraControls AppState::camera(size_t index) const {
  std::lock_guard<std::mutex> lock(mutex_);
  return state_.cameras.at(index);
}

DisplayControls AppState::display() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return state_.display;
}

RecordingControls AppState::recording() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return state_.recording;
}

RobotControls AppState::robot() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return state_.robot;
}

bool AppState::updateCamera(size_t index, const CameraControls& value) {
  if (index >= state_.cameras.size()) {
    return false;
  }
  std::lock_guard<std::mutex> lock(mutex_);
  state_.cameras[index] = sanitize(value);
  ++state_.revision;
  return true;
}

void AppState::updateDisplay(const DisplayControls& value) {
  std::lock_guard<std::mutex> lock(mutex_);
  state_.display = sanitize(value);
  ++state_.revision;
}

void AppState::updateRecording(const RecordingControls& value) {
  std::lock_guard<std::mutex> lock(mutex_);
  state_.recording = value;
  ++state_.revision;
}

void AppState::updateRobot(const RobotControls& value) {
  std::lock_guard<std::mutex> lock(mutex_);
  state_.robot = value;
  ++state_.revision;
}

void AppState::updateSystem(const SystemSnapshot& value) {
  std::lock_guard<std::mutex> lock(mutex_);
  state_.system = value;
}

}  // namespace pulsar::core
