#pragma once

#include "pulsar/camera/CameraManager.hpp"
#include "pulsar/core/AppState.hpp"

#include <atomic>
#include <filesystem>
#include <mutex>
#include <string>
#include <thread>

namespace pulsar::camera {

class Recorder {
 public:
  Recorder(CameraManager& cameras, core::AppState& state, std::filesystem::path dataRoot);
  ~Recorder();
  bool start();
  void stop();
  bool active() const { return running_; }
  std::string snapshot();

 private:
  void loop(std::filesystem::path output);
  bool compose(std::vector<uint8_t>& rgb, uint32_t width, uint32_t height);
  std::filesystem::path nextFile(const std::string& extension) const;

  CameraManager& cameras_;
  core::AppState& state_;
  std::filesystem::path dataRoot_;
  std::atomic<bool> running_{false};
  std::thread worker_;
  mutable std::mutex mutex_;
};

}  // namespace pulsar::camera
