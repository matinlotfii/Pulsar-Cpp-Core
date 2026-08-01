#pragma once

#include "pulsar/camera/CameraManager.hpp"
#include "pulsar/camera/Recorder.hpp"
#include "pulsar/core/AppState.hpp"
#include "pulsar/core/Config.hpp"

#include <atomic>
#include <cstdint>
#include <condition_variable>
#include <filesystem>
#include <mutex>
#include <string>

namespace pulsar::ui {

class HttpServer {
 public:
 HttpServer(core::AppState& state, camera::CameraManager& cameras,
             camera::Recorder& recorder, const core::Config& config);
  bool run(std::atomic<bool>& running);

 private:
  void handleClient(int clientFd);
  void handleStream(int clientFd, size_t cameraIndex);
  std::string stateJson() const;
  std::string camerasJson() const;
  std::string cameraJson(size_t index) const;
  void serveStatic(int clientFd, const std::string& requestPath) const;

  core::AppState& state_;
  camera::CameraManager& cameras_;
  camera::Recorder& recorder_;
  std::string host_;
  uint16_t port_;
  std::filesystem::path uiRoot_;
  std::atomic<bool>* runningSignal_ = nullptr;
  mutable std::atomic<size_t> activeClients_{0};
  mutable std::mutex clientsMutex_;
  mutable std::condition_variable clientsCv_;
};

}  // namespace pulsar::ui
