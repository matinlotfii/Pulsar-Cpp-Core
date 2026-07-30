#include "pulsar/camera/JpegEncoder.hpp"

#include <algorithm>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <jpeglib.h>

namespace pulsar::camera {

void resizeRgbBilinearInto(const uint8_t* rgb, uint32_t width, uint32_t height,
                           uint32_t targetWidth, uint32_t targetHeight,
                           std::vector<uint8_t>& out) {
  if (rgb == nullptr || width == 0 || height == 0 || targetWidth == 0 || targetHeight == 0) {
    out.clear();
    return;
  }
  const size_t size = static_cast<size_t>(targetWidth) * targetHeight * 3u;
  out.resize(size);
  if (targetWidth == width && targetHeight == height) {
    std::copy(rgb, rgb + size, out.begin());
    return;
  }
  const uint32_t xScale = targetWidth > 1 ? ((width - 1u) << 16u) / (targetWidth - 1u) : 0u;
  const uint32_t yScale = targetHeight > 1 ? ((height - 1u) << 16u) / (targetHeight - 1u) : 0u;
  for (uint32_t y = 0; y < targetHeight; ++y) {
    const uint32_t fy = y * yScale;
    const uint32_t y0 = fy >> 16u;
    const uint32_t y1 = std::min(y0 + 1u, height - 1u);
    const uint32_t wy = fy & 0xffffu;
    for (uint32_t x = 0; x < targetWidth; ++x) {
      const uint32_t fx = x * xScale;
      const uint32_t x0 = fx >> 16u;
      const uint32_t x1 = std::min(x0 + 1u, width - 1u);
      const uint32_t wx = fx & 0xffffu;
      const size_t dst = (static_cast<size_t>(y) * targetWidth + x) * 3u;
      const size_t p00 = (static_cast<size_t>(y0) * width + x0) * 3u;
      const size_t p10 = (static_cast<size_t>(y0) * width + x1) * 3u;
      const size_t p01 = (static_cast<size_t>(y1) * width + x0) * 3u;
      const size_t p11 = (static_cast<size_t>(y1) * width + x1) * 3u;
      for (size_t c = 0; c < 3; ++c) {
        const uint64_t top = static_cast<uint64_t>(rgb[p00 + c]) * (65536u - wx) +
                             static_cast<uint64_t>(rgb[p10 + c]) * wx;
        const uint64_t bottom = static_cast<uint64_t>(rgb[p01 + c]) * (65536u - wx) +
                                static_cast<uint64_t>(rgb[p11 + c]) * wx;
        out[dst + c] = static_cast<uint8_t>((top * (65536u - wy) + bottom * wy) >> 32u);
      }
    }
  }
}

std::vector<uint8_t> encodeJpeg(const uint8_t* rgb, uint32_t width, uint32_t height, int quality) {
  if (rgb == nullptr || width == 0 || height == 0) return {};
  jpeg_compress_struct cinfo{};
  jpeg_error_mgr jerr{};
  cinfo.err = jpeg_std_error(&jerr);
  jpeg_create_compress(&cinfo);
  unsigned char* buffer = nullptr;
  unsigned long size = 0;
  jpeg_mem_dest(&cinfo, &buffer, &size);
  cinfo.image_width = width;
  cinfo.image_height = height;
  cinfo.input_components = 3;
  cinfo.in_color_space = JCS_RGB;
  jpeg_set_defaults(&cinfo);
  jpeg_set_quality(&cinfo, std::clamp(quality, 40, 95), TRUE);
  cinfo.dct_method = JDCT_FASTEST;
  jpeg_start_compress(&cinfo, TRUE);
  while (cinfo.next_scanline < cinfo.image_height) {
    JSAMPROW row = const_cast<JSAMPROW>(rgb + static_cast<size_t>(cinfo.next_scanline) * width * 3u);
    jpeg_write_scanlines(&cinfo, &row, 1);
  }
  jpeg_finish_compress(&cinfo);
  std::vector<uint8_t> out(buffer, buffer + size);
  jpeg_destroy_compress(&cinfo);
  std::free(buffer);
  return out;
}

std::vector<uint8_t> makeOfflineRgb(uint32_t width, uint32_t height, uint8_t phase) {
  std::vector<uint8_t> rgb(static_cast<size_t>(width) * height * 3u);
  for (uint32_t y = 0; y < height; ++y) {
    for (uint32_t x = 0; x < width; ++x) {
      const size_t p = (static_cast<size_t>(y) * width + x) * 3u;
      const bool grid = ((x / 42u) + (y / 42u)) % 2u == 0u;
      const uint8_t pulse = static_cast<uint8_t>((x + y + phase * 13u) % 70u);
      rgb[p] = static_cast<uint8_t>((grid ? 8 : 15) + pulse / 6u);
      rgb[p + 1u] = static_cast<uint8_t>((grid ? 18 : 28) + pulse / 2u);
      rgb[p + 2u] = static_cast<uint8_t>((grid ? 28 : 42) + pulse);
    }
  }
  return rgb;
}

}  // namespace pulsar::camera
