#include "pulsar/camera/GpuBayerPipeline.hpp"

#include <cuda_runtime.h>
#include <npp.h>
#include <nppi_color_conversion.h>
#include <nppi_geometry_transforms.h>

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <sstream>
#include <string>
#include <vector>

namespace pulsar::camera {
namespace {

std::string cudaErrorText(const char* operation, cudaError_t status) {
  std::ostringstream out;
  out << operation << " failed: " << cudaGetErrorString(status)
      << " (" << static_cast<int>(status) << ')';
  return out.str();
}

std::string nppErrorText(const char* operation, NppStatus status) {
  std::ostringstream out;
  out << operation << " failed with NPP status " << static_cast<int>(status);
  return out.str();
}

NppiBayerGridPosition toNppPattern(BayerPattern pattern) {
  switch (pattern) {
    case BayerPattern::Rggb:
      return NPPI_BAYER_RGGB;
    case BayerPattern::Bggr:
      return NPPI_BAYER_BGGR;
    case BayerPattern::Gbrg:
      return NPPI_BAYER_GBRG;
    case BayerPattern::Grbg:
      return NPPI_BAYER_GRBG;
  }
  return NPPI_BAYER_RGGB;
}

bool elapsedMs(cudaEvent_t begin, cudaEvent_t end, double& result, std::string& error) {
  float milliseconds = 0.0F;
  const cudaError_t status = cudaEventElapsedTime(&milliseconds, begin, end);
  if (status != cudaSuccess) {
    error = cudaErrorText("cudaEventElapsedTime", status);
    return false;
  }
  result = static_cast<double>(milliseconds);
  return true;
}

}  // namespace

struct GpuBayerPipeline::Impl {
  int device = 0;
  cudaStream_t stream = nullptr;
  NppStreamContext nppContext{};

  uint8_t* deviceBayer = nullptr;
  uint8_t* deviceRgb = nullptr;
  uint8_t* deviceResized = nullptr;
  uint8_t* hostInput = nullptr;

  struct HostOutputSlot {
    std::shared_ptr<uint8_t> storage;
    size_t capacity = 0;
  };
  std::vector<HostOutputSlot> hostOutputs;
  size_t nextHostOutput = 0;

  size_t deviceBayerCapacity = 0;
  size_t deviceRgbCapacity = 0;
  size_t deviceResizedCapacity = 0;
  size_t hostInputCapacity = 0;
  size_t stagedInputBytes = 0;

  cudaEvent_t totalStart = nullptr;
  cudaEvent_t h2dDone = nullptr;
  cudaEvent_t debayerDone = nullptr;
  cudaEvent_t resizeDone = nullptr;
  cudaEvent_t d2hDone = nullptr;

  bool initialized = false;

  ~Impl() {
    if (d2hDone != nullptr) cudaEventDestroy(d2hDone);
    if (resizeDone != nullptr) cudaEventDestroy(resizeDone);
    if (debayerDone != nullptr) cudaEventDestroy(debayerDone);
    if (h2dDone != nullptr) cudaEventDestroy(h2dDone);
    if (totalStart != nullptr) cudaEventDestroy(totalStart);

    hostOutputs.clear();
    if (hostInput != nullptr) cudaFreeHost(hostInput);
    if (deviceResized != nullptr) cudaFree(deviceResized);
    if (deviceRgb != nullptr) cudaFree(deviceRgb);
    if (deviceBayer != nullptr) cudaFree(deviceBayer);
    if (stream != nullptr) cudaStreamDestroy(stream);
  }

  bool ensureDeviceBuffer(
      uint8_t*& pointer,
      size_t& capacity,
      size_t required,
      const char* label,
      std::string& error) {
    if (capacity >= required && pointer != nullptr) return true;

    if (pointer != nullptr) {
      const cudaError_t freeStatus = cudaFree(pointer);
      if (freeStatus != cudaSuccess) {
        error = cudaErrorText("cudaFree", freeStatus);
        return false;
      }
      pointer = nullptr;
      capacity = 0;
    }

    const cudaError_t status = cudaMalloc(
        reinterpret_cast<void**>(&pointer), required);
    if (status != cudaSuccess) {
      error = cudaErrorText(label, status);
      return false;
    }

    capacity = required;
    return true;
  }

  bool ensureHostInput(size_t required, std::string& error) {
    if (hostInputCapacity >= required && hostInput != nullptr) return true;

    if (hostInput != nullptr) {
      const cudaError_t freeStatus = cudaFreeHost(hostInput);
      if (freeStatus != cudaSuccess) {
        error = cudaErrorText("cudaFreeHost(input)", freeStatus);
        return false;
      }
      hostInput = nullptr;
      hostInputCapacity = 0;
      stagedInputBytes = 0;
    }

    const cudaError_t status = cudaHostAlloc(
        reinterpret_cast<void**>(&hostInput),
        required,
        cudaHostAllocWriteCombined);
    if (status != cudaSuccess) {
      error = cudaErrorText("cudaHostAlloc(input)", status);
      return false;
    }

    hostInputCapacity = required;
    return true;
  }

  bool acquireHostOutput(
      size_t required,
      std::shared_ptr<uint8_t>& storage,
      std::string& error) {
    constexpr size_t kPreferredPoolSize = 3;
    constexpr size_t kMaximumPoolSize = 8;

    if (hostOutputs.empty()) hostOutputs.resize(kPreferredPoolSize);

    const size_t slotCount = hostOutputs.size();
    for (size_t offset = 0; offset < slotCount; ++offset) {
      const size_t index = (nextHostOutput + offset) % slotCount;
      auto& slot = hostOutputs[index];
      const bool available = !slot.storage || slot.storage.use_count() == 1;
      if (!available) continue;

      if (!slot.storage || slot.capacity < required) {
        uint8_t* pointer = nullptr;
        const cudaError_t status = cudaHostAlloc(
            reinterpret_cast<void**>(&pointer), required, cudaHostAllocDefault);
        if (status != cudaSuccess) {
          error = cudaErrorText("cudaHostAlloc(output pool)", status);
          return false;
        }
        slot.storage = std::shared_ptr<uint8_t>(pointer, [](uint8_t* value) {
          if (value != nullptr) cudaFreeHost(value);
        });
        slot.capacity = required;
      }

      storage = slot.storage;
      nextHostOutput = (index + 1u) % hostOutputs.size();
      return true;
    }

    if (hostOutputs.size() >= kMaximumPoolSize) {
      error = "all CUDA output buffers are still in use";
      return false;
    }

    HostOutputSlot slot;
    uint8_t* pointer = nullptr;
    const cudaError_t status = cudaHostAlloc(
        reinterpret_cast<void**>(&pointer), required, cudaHostAllocDefault);
    if (status != cudaSuccess) {
      error = cudaErrorText("cudaHostAlloc(extra output)", status);
      return false;
    }
    slot.storage = std::shared_ptr<uint8_t>(pointer, [](uint8_t* value) {
      if (value != nullptr) cudaFreeHost(value);
    });
    slot.capacity = required;
    hostOutputs.push_back(slot);
    storage = hostOutputs.back().storage;
    nextHostOutput = 0;
    return true;
  }
};

GpuBayerPipeline::GpuBayerPipeline() : impl_(std::make_unique<Impl>()) {}
GpuBayerPipeline::~GpuBayerPipeline() = default;

bool GpuBayerPipeline::compiledWithCuda() { return true; }

bool GpuBayerPipeline::initialize(std::string& error) {
  if (impl_->initialized) return true;

  int deviceCount = 0;
  cudaError_t status = cudaGetDeviceCount(&deviceCount);
  if (status != cudaSuccess) {
    error = cudaErrorText("cudaGetDeviceCount", status);
    return false;
  }
  if (deviceCount < 1) {
    error = "no CUDA device is available";
    return false;
  }

  impl_->device = 0;
  status = cudaSetDevice(impl_->device);
  if (status != cudaSuccess) {
    error = cudaErrorText("cudaSetDevice", status);
    return false;
  }

  cudaDeviceProp properties{};
  status = cudaGetDeviceProperties(&properties, impl_->device);
  if (status != cudaSuccess) {
    error = cudaErrorText("cudaGetDeviceProperties", status);
    return false;
  }

  status = cudaStreamCreateWithFlags(&impl_->stream, cudaStreamNonBlocking);
  if (status != cudaSuccess) {
    error = cudaErrorText("cudaStreamCreateWithFlags", status);
    return false;
  }

  impl_->nppContext = {};
  impl_->nppContext.hStream = impl_->stream;
  impl_->nppContext.nCudaDeviceId = impl_->device;
  impl_->nppContext.nMultiProcessorCount = properties.multiProcessorCount;
  impl_->nppContext.nMaxThreadsPerMultiProcessor = properties.maxThreadsPerMultiProcessor;
  impl_->nppContext.nMaxThreadsPerBlock = properties.maxThreadsPerBlock;
  impl_->nppContext.nSharedMemPerBlock = properties.sharedMemPerBlock;
  impl_->nppContext.nCudaDevAttrComputeCapabilityMajor = properties.major;
  impl_->nppContext.nCudaDevAttrComputeCapabilityMinor = properties.minor;

  unsigned int streamFlags = 0;
  status = cudaStreamGetFlags(impl_->stream, &streamFlags);
  if (status != cudaSuccess) {
    error = cudaErrorText("cudaStreamGetFlags", status);
    return false;
  }
  impl_->nppContext.nStreamFlags = streamFlags;

  cudaEvent_t* events[] = {
      &impl_->totalStart,
      &impl_->h2dDone,
      &impl_->debayerDone,
      &impl_->resizeDone,
      &impl_->d2hDone,
  };

  for (cudaEvent_t* event : events) {
    status = cudaEventCreate(event);
    if (status != cudaSuccess) {
      error = cudaErrorText("cudaEventCreate", status);
      return false;
    }
  }

  impl_->initialized = true;
  return true;
}

bool GpuBayerPipeline::stageInput(
    const uint8_t* bayer,
    std::size_t bytes,
    std::string& error) {
  error.clear();

  if (!impl_->initialized && !initialize(error)) return false;
  if (bayer == nullptr || bytes == 0) {
    error = "invalid staged Bayer input";
    return false;
  }
  if (!impl_->ensureHostInput(bytes, error)) return false;

  std::memcpy(impl_->hostInput, bayer, bytes);
  impl_->stagedInputBytes = bytes;
  return true;
}

bool GpuBayerPipeline::processStaged(
    uint32_t sourceWidth,
    uint32_t sourceHeight,
    BayerPattern pattern,
    uint32_t outputWidth,
    uint32_t outputHeight,
    std::shared_ptr<const PixelBuffer>& outputRgb,
    GpuBayerTimings& timings,
    std::string& error) {
  timings = {};
  error.clear();
  outputRgb.reset();

  if (!impl_->initialized && !initialize(error)) return false;

  if (sourceWidth == 0 || sourceHeight == 0 ||
      outputWidth == 0 || outputHeight == 0) {
    error = "invalid GPU Bayer pipeline dimensions";
    return false;
  }

  if ((sourceWidth & 1u) != 0u || (sourceHeight & 1u) != 0u) {
    error = "NPP CFA debayer requires even source width and height";
    return false;
  }

  const size_t bayerBytes =
      static_cast<size_t>(sourceWidth) * static_cast<size_t>(sourceHeight);
  const size_t fullRgbBytes = bayerBytes * 3u;
  const size_t outputBytes =
      static_cast<size_t>(outputWidth) * static_cast<size_t>(outputHeight) * 3u;

  if (impl_->hostInput == nullptr || impl_->stagedInputBytes < bayerBytes) {
    error = "no complete page-locked Bayer frame has been staged";
    return false;
  }

  if (!impl_->ensureDeviceBuffer(
          impl_->deviceBayer,
          impl_->deviceBayerCapacity,
          bayerBytes,
          "cudaMalloc(Bayer)",
          error) ||
      !impl_->ensureDeviceBuffer(
          impl_->deviceRgb,
          impl_->deviceRgbCapacity,
          fullRgbBytes,
          "cudaMalloc(full RGB)",
          error)) {
    return false;
  }

  const bool resizeRequired =
      sourceWidth != outputWidth || sourceHeight != outputHeight;
  if (resizeRequired &&
      !impl_->ensureDeviceBuffer(
          impl_->deviceResized,
          impl_->deviceResizedCapacity,
          outputBytes,
          "cudaMalloc(resized RGB)",
          error)) {
    return false;
  }

  std::shared_ptr<uint8_t> hostOutput;
  if (!impl_->acquireHostOutput(outputBytes, hostOutput, error)) return false;

  cudaError_t cudaStatus = cudaEventRecord(impl_->totalStart, impl_->stream);
  if (cudaStatus != cudaSuccess) {
    error = cudaErrorText("cudaEventRecord(totalStart)", cudaStatus);
    return false;
  }

  cudaStatus = cudaMemcpyAsync(
      impl_->deviceBayer,
      impl_->hostInput,
      bayerBytes,
      cudaMemcpyHostToDevice,
      impl_->stream);
  if (cudaStatus != cudaSuccess) {
    error = cudaErrorText("cudaMemcpyAsync(H2D Bayer)", cudaStatus);
    return false;
  }

  cudaStatus = cudaEventRecord(impl_->h2dDone, impl_->stream);
  if (cudaStatus != cudaSuccess) {
    error = cudaErrorText("cudaEventRecord(h2dDone)", cudaStatus);
    return false;
  }

  const NppiSize sourceSize{
      static_cast<int>(sourceWidth),
      static_cast<int>(sourceHeight)};
  const NppiRect sourceRoi{
      0,
      0,
      static_cast<int>(sourceWidth),
      static_cast<int>(sourceHeight)};

  const NppStatus debayerStatus = nppiCFAToRGB_8u_C1C3R_Ctx(
      impl_->deviceBayer,
      static_cast<int>(sourceWidth),
      sourceSize,
      sourceRoi,
      impl_->deviceRgb,
      static_cast<int>(sourceWidth * 3u),
      toNppPattern(pattern),
      NPPI_INTER_UNDEFINED,
      impl_->nppContext);
  if (debayerStatus != NPP_SUCCESS) {
    error = nppErrorText("nppiCFAToRGB_8u_C1C3R_Ctx", debayerStatus);
    return false;
  }

  cudaStatus = cudaEventRecord(impl_->debayerDone, impl_->stream);
  if (cudaStatus != cudaSuccess) {
    error = cudaErrorText("cudaEventRecord(debayerDone)", cudaStatus);
    return false;
  }

  uint8_t* finalDeviceRgb = impl_->deviceRgb;
  if (resizeRequired) {
    const NppiSize outputSize{
        static_cast<int>(outputWidth),
        static_cast<int>(outputHeight)};
    const NppiRect outputRoi{
        0,
        0,
        static_cast<int>(outputWidth),
        static_cast<int>(outputHeight)};

    const NppStatus resizeStatus = nppiResize_8u_C3R_Ctx(
        impl_->deviceRgb,
        static_cast<int>(sourceWidth * 3u),
        sourceSize,
        sourceRoi,
        impl_->deviceResized,
        static_cast<int>(outputWidth * 3u),
        outputSize,
        outputRoi,
        NPPI_INTER_LINEAR,
        impl_->nppContext);
    if (resizeStatus != NPP_SUCCESS) {
      error = nppErrorText("nppiResize_8u_C3R_Ctx", resizeStatus);
      return false;
    }
    finalDeviceRgb = impl_->deviceResized;
  }

  cudaStatus = cudaEventRecord(impl_->resizeDone, impl_->stream);
  if (cudaStatus != cudaSuccess) {
    error = cudaErrorText("cudaEventRecord(resizeDone)", cudaStatus);
    return false;
  }

  cudaStatus = cudaMemcpyAsync(
      hostOutput.get(),
      finalDeviceRgb,
      outputBytes,
      cudaMemcpyDeviceToHost,
      impl_->stream);
  if (cudaStatus != cudaSuccess) {
    error = cudaErrorText("cudaMemcpyAsync(D2H RGB)", cudaStatus);
    return false;
  }

  cudaStatus = cudaEventRecord(impl_->d2hDone, impl_->stream);
  if (cudaStatus != cudaSuccess) {
    error = cudaErrorText("cudaEventRecord(d2hDone)", cudaStatus);
    return false;
  }

  cudaStatus = cudaEventSynchronize(impl_->d2hDone);
  if (cudaStatus != cudaSuccess) {
    error = cudaErrorText("cudaEventSynchronize", cudaStatus);
    return false;
  }

  if (!elapsedMs(impl_->totalStart, impl_->h2dDone, timings.hostToDeviceMs, error) ||
      !elapsedMs(impl_->h2dDone, impl_->debayerDone, timings.debayerMs, error) ||
      !elapsedMs(impl_->debayerDone, impl_->resizeDone, timings.resizeMs, error) ||
      !elapsedMs(impl_->resizeDone, impl_->d2hDone, timings.deviceToHostMs, error) ||
      !elapsedMs(impl_->totalStart, impl_->d2hDone, timings.totalMs, error)) {
    return false;
  }

  auto pixels = std::make_shared<PixelBuffer>();
  pixels->storage = std::move(hostOutput);
  pixels->byteCount = outputBytes;
  outputRgb = std::move(pixels);
  return true;
}

bool GpuBayerPipeline::process(
    const uint8_t* bayer,
    uint32_t sourceWidth,
    uint32_t sourceHeight,
    BayerPattern pattern,
    uint32_t outputWidth,
    uint32_t outputHeight,
    std::vector<uint8_t>& outputRgb,
    GpuBayerTimings& timings,
    std::string& error) {
  const size_t bayerBytes =
      static_cast<size_t>(sourceWidth) * static_cast<size_t>(sourceHeight);
  if (!stageInput(bayer, bayerBytes, error)) return false;

  std::shared_ptr<const PixelBuffer> pinnedOutput;
  if (!processStaged(
          sourceWidth,
          sourceHeight,
          pattern,
          outputWidth,
          outputHeight,
          pinnedOutput,
          timings,
          error)) {
    return false;
  }

  outputRgb.assign(
      pinnedOutput->data(),
      pinnedOutput->data() + pinnedOutput->size());
  return true;
}

}  // namespace pulsar::camera
