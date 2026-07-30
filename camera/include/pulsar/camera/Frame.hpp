#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace pulsar::camera {

struct Frame {
  uint32_t width = 0;
  uint32_t height = 0;
  uint64_t id = 0;
  uint64_t timestampNs = 0;
  std::shared_ptr<const std::vector<uint8_t>> rgb;
  std::shared_ptr<const std::vector<uint8_t>> jpeg;
};

struct CameraStatus {
  bool online = false;
  uint32_t slot = 0;
  double fps = 0.0;
  std::string label;
  std::string model;
  std::string serial;
  std::string error;
  std::shared_ptr<const Frame> frame;
};

}  // namespace pulsar::camera
