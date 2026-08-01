#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace pulsar::camera {

enum class BayerPattern {
  Rggb,
  Bggr,
  Gbrg,
  Grbg,
};

struct GpuBayerTimings {
  double hostToDeviceMs = 0.0;
  double debayerMs = 0.0;
  double resizeMs = 0.0;
  double deviceToHostMs = 0.0;
  double totalMs = 0.0;
};

class GpuBayerPipeline {
 public:
  GpuBayerPipeline();
  ~GpuBayerPipeline();

  GpuBayerPipeline(const GpuBayerPipeline&) = delete;
  GpuBayerPipeline& operator=(const GpuBayerPipeline&) = delete;

  static bool compiledWithCuda();

  bool initialize(std::string& error);

  // Copy the newest SDK frame directly into page-locked host memory while
  // the Galaxy buffer is still owned by the application.
  bool stageInput(
      const uint8_t* bayer,
      std::size_t bytes,
      std::string& error);

  // Process the most recently staged frame. The returned pointer is valid
  // until this pipeline processes another frame or is destroyed.
  bool processStaged(
      uint32_t sourceWidth,
      uint32_t sourceHeight,
      BayerPattern pattern,
      uint32_t outputWidth,
      uint32_t outputHeight,
      const uint8_t*& outputRgb,
      std::size_t& outputBytes,
      GpuBayerTimings& timings,
      std::string& error);

  bool process(
      const uint8_t* bayer,
      uint32_t sourceWidth,
      uint32_t sourceHeight,
      BayerPattern pattern,
      uint32_t outputWidth,
      uint32_t outputHeight,
      std::vector<uint8_t>& outputRgb,
      GpuBayerTimings& timings,
      std::string& error);

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace pulsar::camera
