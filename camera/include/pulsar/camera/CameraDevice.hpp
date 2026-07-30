#pragma once

#include "pulsar/camera/Frame.hpp"
#include "pulsar/core/AppState.hpp"
#include "GxIAPI.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace pulsar::camera {

class GalaxyRuntime {
 public:
  explicit GalaxyRuntime(bool enabled);
  ~GalaxyRuntime();
  bool ok() const { return initialized_; }
  uint32_t deviceCount() const { return deviceCount_; }
 private:
  bool initialized_ = false;
  uint32_t deviceCount_ = 0;
};

class CameraDevice {
 public:
  using ControlProvider = std::function<core::CameraControls()>;

  CameraDevice(uint32_t slot, uint32_t sdkIndex, std::string serialSelector,
               std::string label, bool mockMode, uint32_t maxWidth, uint32_t maxHeight,
               int targetFps, int previewFps, int jpegQuality,
               ControlProvider controls);
  ~CameraDevice();

  CameraDevice(const CameraDevice&) = delete;
  CameraDevice& operator=(const CameraDevice&) = delete;

  void start();
  void stop();
  CameraStatus snapshot() const;
  bool waitForFrame(uint64_t previousId, CameraStatus& out, int timeoutMs) const;

 private:
  void loop();
  void mockLoop();
  bool connect();
  bool configure();
  void close();
  void applyControls(const core::CameraControls& controls, bool force);
  bool convert(PGX_FRAME_BUFFER frame, std::vector<uint8_t>& rgb);
  void publish(uint32_t width, uint32_t height, const std::vector<uint8_t>& rgb, bool online);
  void fail(const std::string& message);

  uint32_t slot_;
  uint32_t sdkIndex_;
  std::string serialSelector_;
  std::string label_;
  bool mockMode_;
  uint32_t maxWidth_;
  uint32_t maxHeight_;
  int targetFps_;
  int previewFps_;
  int jpegQuality_;
  ControlProvider controls_;

  GX_DEV_HANDLE device_ = nullptr;
  int64_t colorFilter_ = GX_COLOR_FILTER_NONE;
  std::vector<uint8_t> raw8_;
  std::vector<uint8_t> rgb_;
  std::vector<uint8_t> resized_;
  core::CameraControls appliedControls_;
  bool controlsApplied_ = false;
  std::shared_ptr<const std::vector<uint8_t>> lastJpeg_;
  std::chrono::steady_clock::time_point nextPreview_{};

  std::atomic<bool> running_{false};
  std::thread worker_;
  mutable std::mutex mutex_;
  mutable std::condition_variable frameCv_;
  CameraStatus status_;
};

}  // namespace pulsar::camera
