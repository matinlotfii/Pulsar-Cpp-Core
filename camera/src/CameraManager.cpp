#include "pulsar/camera/CameraManager.hpp"

#include <stdexcept>

namespace pulsar::camera {

CameraManager::CameraManager(core::AppState& state, const core::Config& config)
    : state_(state), mockMode_(config.cameraMode == "mock"), runtime_(!mockMode_) {
  for (size_t i = 0; i < devices_.size(); ++i) {
    devices_[i] = std::make_unique<CameraDevice>(
        static_cast<uint32_t>(i), static_cast<uint32_t>(i + 1), config.cameraSerials[i],
        i == 0 ? "Left Camera" : "Right Camera", mockMode_,
        config.cameraMaxWidth, config.cameraMaxHeight, config.cameraFps,
        config.previewFps, config.jpegQuality, [this, i] { return state_.camera(i); });
  }
}

CameraManager::~CameraManager() { stop(); }

void CameraManager::start() {
  if (!mockMode_ && !runtime_.ok()) return;
  for (auto& device : devices_) device->start();
}

void CameraManager::stop() {
  for (auto& device : devices_) device->stop();
}

CameraStatus CameraManager::snapshot(size_t index) const {
  if (index >= devices_.size()) throw std::out_of_range("camera index");
  return devices_[index]->snapshot();
}

bool CameraManager::waitForFrame(size_t index, uint64_t previousId, CameraStatus& out, int timeoutMs) const {
  if (index >= devices_.size()) return false;
  return devices_[index]->waitForFrame(previousId, out, timeoutMs);
}

}  // namespace pulsar::camera
