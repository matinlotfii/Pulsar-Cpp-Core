#pragma once

#include "pulsar/camera/CameraDevice.hpp"
#include "pulsar/core/AppState.hpp"
#include "pulsar/core/Config.hpp"

#include <array>
#include <memory>

namespace pulsar::camera {

class CameraManager {
 public:
  CameraManager(core::AppState& state, const core::Config& config);
  ~CameraManager();
  void start();
  void stop();
  CameraStatus snapshot(size_t index) const;
  bool waitForFrame(size_t index, uint64_t previousId, CameraStatus& out, int timeoutMs) const;
  bool usingMock() const { return mockMode_; }
  bool sdkReady() const { return runtime_.ok(); }

 private:
  core::AppState& state_;
  bool mockMode_;
  GalaxyRuntime runtime_;
  std::array<std::unique_ptr<CameraDevice>, 2> devices_;
};

}  // namespace pulsar::camera
