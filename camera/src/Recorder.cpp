#include "pulsar/camera/Recorder.hpp"

#include "pulsar/camera/JpegEncoder.hpp"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cerrno>
#include <ctime>
#include <fstream>
#include <iomanip>
#include <sstream>
#include <vector>
#include <sys/wait.h>
#include <unistd.h>

namespace pulsar::camera {

Recorder::Recorder(CameraManager& cameras, core::AppState& state, std::filesystem::path dataRoot)
    : cameras_(cameras), state_(state), dataRoot_(std::move(dataRoot)) {}
Recorder::~Recorder() { stop(); }

std::filesystem::path Recorder::nextFile(const std::string& extension) const {
  const auto now = std::chrono::system_clock::now();
  const std::time_t time = std::chrono::system_clock::to_time_t(now);
  std::tm tm{};
  localtime_r(&time, &tm);
  std::ostringstream name;
  const auto millis = std::chrono::duration_cast<std::chrono::milliseconds>(now.time_since_epoch()).count() % 1000;
  name << "pulsar-" << std::put_time(&tm, "%Y%m%d-%H%M%S")
       << '-' << std::setw(3) << std::setfill('0') << millis << extension;
  return dataRoot_ / "recordings" / name.str();
}

bool Recorder::start() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (running_) return true;
  std::filesystem::create_directories(dataRoot_ / "recordings");
  const auto output = nextFile(".mp4");
  running_ = true;
  auto recording = state_.recording();
  recording.active = true;
  recording.lastFile = output.string();
  recording.elapsedSeconds = 0;
  state_.updateRecording(recording);
  worker_ = std::thread(&Recorder::loop, this, output);
  return true;
}

void Recorder::stop() {
  running_ = false;
  if (worker_.joinable()) worker_.join();
  auto recording = state_.recording();
  recording.active = false;
  state_.updateRecording(recording);
}

bool Recorder::compose(std::vector<uint8_t>& output, uint32_t width, uint32_t height) {
  const auto left = cameras_.snapshot(0);
  const auto right = cameras_.snapshot(1);
  if (!left.frame || !right.frame || !left.frame->rgb || !right.frame->rgb) return false;
  std::vector<uint8_t> scaledLeft;
  std::vector<uint8_t> scaledRight;
  const uint32_t half = width / 2u;
  resizeRgbBilinearInto(left.frame->rgb->data(), left.frame->width, left.frame->height, half, height, scaledLeft);
  resizeRgbBilinearInto(right.frame->rgb->data(), right.frame->width, right.frame->height, width - half, height, scaledRight);
  output.resize(static_cast<size_t>(width) * height * 3u);
  for (uint32_t y = 0; y < height; ++y) {
    auto* row = output.data() + static_cast<size_t>(y) * width * 3u;
    std::copy_n(scaledLeft.data() + static_cast<size_t>(y) * half * 3u, static_cast<size_t>(half) * 3u, row);
    std::copy_n(scaledRight.data() + static_cast<size_t>(y) * (width - half) * 3u,
                static_cast<size_t>(width - half) * 3u, row + static_cast<size_t>(half) * 3u);
  }
  return true;
}

void Recorder::loop(std::filesystem::path output) {
  constexpr uint32_t width = 1280;
  constexpr uint32_t height = 360;
  constexpr int fps = 30;

  int descriptors[2]{};
  if (::pipe(descriptors) != 0) {
    running_ = false;
    auto recording = state_.recording();
    recording.active = false;
    state_.updateRecording(recording);
    return;
  }
  const pid_t child = ::fork();
  if (child == 0) {
    ::dup2(descriptors[0], STDIN_FILENO);
    ::close(descriptors[0]);
    ::close(descriptors[1]);
    const std::string size = std::to_string(width) + "x" + std::to_string(height);
    const std::string rate = std::to_string(fps);
    ::execlp("ffmpeg", "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
             "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", size.c_str(),
             "-r", rate.c_str(), "-i", "-", "-an", "-c:v", "libx264",
             "-preset", "ultrafast", "-crf", "18", "-pix_fmt", "yuv420p",
             output.c_str(), static_cast<char*>(nullptr));
    _exit(127);
  }
  ::close(descriptors[0]);
  if (child < 0) {
    ::close(descriptors[1]);
    running_ = false;
    auto recording = state_.recording();
    recording.active = false;
    state_.updateRecording(recording);
    return;
  }

  FILE* pipe = ::fdopen(descriptors[1], "w");
  if (pipe == nullptr) {
    ::close(descriptors[1]);
    ::kill(child, SIGTERM);
    ::waitpid(child, nullptr, 0);
    running_ = false;
    auto recording = state_.recording();
    recording.active = false;
    state_.updateRecording(recording);
    return;
  }

  std::vector<uint8_t> frame;
  auto next = std::chrono::steady_clock::now();
  const auto started = next;
  while (running_) {
    if (compose(frame, width, height) &&
        std::fwrite(frame.data(), 1, frame.size(), pipe) != frame.size()) {
      break;
    }
    const auto now = std::chrono::steady_clock::now();
    auto recording = state_.recording();
    recording.elapsedSeconds = static_cast<uint64_t>(
        std::chrono::duration_cast<std::chrono::seconds>(now - started).count());
    state_.updateRecording(recording);
    next += std::chrono::milliseconds(1000 / fps);
    std::this_thread::sleep_until(next);
  }
  std::fclose(pipe);
  ::waitpid(child, nullptr, 0);
  running_ = false;
  auto recording = state_.recording();
  recording.active = false;
  state_.updateRecording(recording);
}

std::string Recorder::snapshot() {
  std::filesystem::create_directories(dataRoot_ / "recordings");
  const auto output = nextFile(".jpg");
  std::vector<uint8_t> rgb;
  if (!compose(rgb, 1920, 540)) return {};
  const auto jpeg = encodeJpeg(rgb.data(), 1920, 540, 92);
  std::ofstream file(output, std::ios::binary);
  file.write(reinterpret_cast<const char*>(jpeg.data()), static_cast<std::streamsize>(jpeg.size()));
  return file ? output.string() : std::string{};
}

}  // namespace pulsar::camera
