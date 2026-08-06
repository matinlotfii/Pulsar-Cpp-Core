#pragma once

#include <cstdint>
#include <vector>

namespace pulsar::camera {

void resizeRgbNearestInto(const uint8_t* rgb, uint32_t width, uint32_t height,
                          uint32_t targetWidth, uint32_t targetHeight,
                          std::vector<uint8_t>& out);

void resizeRgbBilinearInto(const uint8_t* rgb, uint32_t width, uint32_t height,
                           uint32_t targetWidth, uint32_t targetHeight,
                           std::vector<uint8_t>& out);
std::vector<uint8_t> encodeJpeg(const uint8_t* rgb, uint32_t width, uint32_t height, int quality);
std::vector<uint8_t> makeOfflineRgb(uint32_t width, uint32_t height, uint8_t phase);

}  // namespace pulsar::camera
