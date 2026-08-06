#include "pulsar/camera/GpuBayerPipeline.hpp"

namespace pulsar::camera {

struct GpuBayerPipeline::Impl {};

GpuBayerPipeline::GpuBayerPipeline() : impl_(std::make_unique<Impl>()) {}
GpuBayerPipeline::~GpuBayerPipeline() = default;

bool GpuBayerPipeline::compiledWithCuda() { return false; }

bool GpuBayerPipeline::stageInput(
    const uint8_t*,
    std::size_t,
    std::string& error) {
  error = "CUDA support was not compiled into this build";
  return false;
}

bool GpuBayerPipeline::stageInputDirectToDevice(
    const uint8_t*,
    std::size_t,
    std::string& error) {
  error = "CUDA support was not compiled into this build";
  return false;
}

bool GpuBayerPipeline::processStaged(
    uint32_t,
    uint32_t,
    BayerPattern,
    uint32_t,
    uint32_t,
    const uint8_t*&,
    std::size_t&,
    GpuBayerTimings&,
    std::string& error) {
  error = "CUDA support was not compiled into this build";
  return false;
}

bool GpuBayerPipeline::initialize(std::string& error) {
  error = "CUDA support was not compiled into this build";
  return false;
}

bool GpuBayerPipeline::process(
    const uint8_t*,
    uint32_t,
    uint32_t,
    BayerPattern,
    uint32_t,
    uint32_t,
    std::vector<uint8_t>&,
    GpuBayerTimings&,
    std::string& error) {
  error = "CUDA support was not compiled into this build";
  return false;
}

}  // namespace pulsar::camera
