#pragma once

#include "pulsar/camera/CameraManager.hpp"
#include "pulsar/core/AppState.hpp"
#include "pulsar/core/Config.hpp"

#include <atomic>
#include <thread>

namespace pulsar::camera {

class SbsRenderer {
 public:
  SbsRenderer(CameraManager& cameras, core::AppState& state, const core::Config& config);
  ~SbsRenderer();
  bool start();
  void stop();
  bool running() const { return running_; }
  int displayIndex() const { return displayIndex_; }

 private:
  void loop();
  CameraManager& cameras_;
  core::AppState& state_;
  core::Config config_;
  std::atomic<bool> running_{false};
  std::thread worker_;
  int displayIndex_ = -1;
};

}  // namespace pulsar::camera
