#pragma once

#include "pulsar/camera/Frame.hpp"
#include "pulsar/camera/GpuBayerPipeline.hpp"
#include "pulsar/core/AppState.hpp"
#include "GxIAPI.h"

#include <array>
#include <atomic>
#include <cstddef>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace pulsar::camera {

// One-shot startup barrier for best-effort software phase alignment.
// This does not replace a shared hardware trigger; it only releases the two
// independent GXStreamOn calls together so free-running cameras start as
// closely as the host scheduler and USB stack permit.
class SoftwareStartGate {
 public:
  bool arriveAndWait(uint32_t slot, std::chrono::milliseconds timeout);

 private:
  std::mutex mutex_;
  std::condition_variable cv_;
  std::array<bool, 2> arrived_{{false, false}};
  bool released_ = false;
  bool paired_ = false;
};

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
  using PreviewDemandProvider = std::function<bool()>;

  CameraDevice(
      uint32_t slot,
      uint32_t sdkIndex,
      std::string serialSelector,
      std::string label,
      bool mockMode,
      uint32_t maxWidth,
      uint32_t maxHeight,
      int sensorScale,
      int targetFps,
      int previewFps,
      int jpegQuality,
      std::filesystem::path profilePath,
      bool profileEnabled,
      bool profileVerify,
      bool profileRequired,
      double whiteBalanceRed,
      double whiteBalanceGreen,
      double whiteBalanceBlue,
      ControlProvider controls,
      PreviewDemandProvider previewDemand,
      std::shared_ptr<SoftwareStartGate> startGate);

  ~CameraDevice();

  CameraDevice(const CameraDevice&) = delete;
  CameraDevice& operator=(const CameraDevice&) = delete;

  void start();
  void stop();

  CameraStatus snapshot() const;

  bool waitForFrame(
      uint64_t previousId,
      CameraStatus& out,
      int timeoutMs) const;

  void notifyPreviewDemand();

 private:
  void loop();
  void mockLoop();
  void previewLoop();

  bool connect();
  bool configure();
  bool importGalaxyProfile();

  void elevateThreadPriority() const;
  void close();

  void applyControls(
      const core::CameraControls& controls,
      bool force);

  bool convert(
      PGX_FRAME_BUFFER frame,
      std::vector<uint8_t>& rgb);

  void publish(
      uint32_t width,
      uint32_t height,
      const std::vector<uint8_t>& rgb,
      bool online,
      FrameTiming timing = {});

  void publish(
      uint32_t width,
      uint32_t height,
      const uint8_t* rgb,
      std::size_t rgbBytes,
      bool online,
      FrameTiming timing = {});

  std::shared_ptr<std::vector<uint8_t>> acquirePublishBuffer(
      std::size_t requiredBytes);

  void publishOwned(
      uint32_t width,
      uint32_t height,
      std::shared_ptr<std::vector<uint8_t>> rgb,
      bool online,
      FrameTiming timing = {});

  void fail(const std::string& message);

  uint32_t slot_;
  uint32_t sdkIndex_;

  std::string serialSelector_;
  std::string label_;

  bool mockMode_;

  uint32_t maxWidth_;
  uint32_t maxHeight_;

  int sensorScale_;
  int targetFps_;
  int previewFps_;
  int jpegQuality_;

  std::filesystem::path profilePath_;
  bool profileEnabled_;
  bool profileVerify_;
  bool profileRequired_;
  bool profileImported_ = false;

  int configuredSensorScale_ = 1;

  double whiteBalanceRed_;
  double whiteBalanceGreen_;
  double whiteBalanceBlue_;

  ControlProvider controls_;
  PreviewDemandProvider previewDemand_;
  std::shared_ptr<SoftwareStartGate> startGate_;

  GX_DEV_HANDLE device_ = nullptr;

  int64_t colorFilter_ = GX_COLOR_FILTER_NONE;

  std::vector<uint8_t> raw8_;
  std::vector<uint8_t> rgb_;
  std::vector<uint8_t> gpuRgb_;
  std::vector<uint8_t> resized_;
  std::vector<uint8_t> previewResized_;

  // Reuse published RGB storage once no consumer references an older frame.
  // This removes a multi-megabyte allocation from every camera frame while
  // preserving immutable shared ownership for renderer/preview consumers.
  std::array<std::shared_ptr<std::vector<uint8_t>>, 4> publishRgbPool_{};
  size_t publishRgbPoolNext_ = 0;

  std::unique_ptr<GpuBayerPipeline> gpuPipeline_;
  bool gpuRequested_ = false;
  bool gpuDisabledAfterFailure_ = false;

  core::CameraControls appliedControls_;
  bool controlsApplied_ = false;

  std::shared_ptr<const std::vector<uint8_t>> lastJpeg_;

  std::thread previewWorker_;
  mutable std::mutex previewMutex_;
  std::condition_variable previewCv_;
  std::shared_ptr<const Frame> previewPending_;

  std::atomic<bool> running_{false};
  std::thread worker_;

  mutable std::mutex mutex_;
  mutable std::condition_variable frameCv_;

  CameraStatus status_;
};

}  // namespace pulsar::camera
