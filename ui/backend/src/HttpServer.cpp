#include "pulsar/ui/HttpServer.hpp"

#include "pulsar/camera/JpegEncoder.hpp"

#include <arpa/inet.h>
#include <algorithm>
#include <array>
#include <cerrno>
#include <chrono>
#include <cctype>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <fcntl.h>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <iterator>
#include <map>
#include <netinet/in.h>
#include <optional>
#include <poll.h>
#include <regex>
#include <signal.h>
#include <sstream>
#include <string_view>
#include <sys/socket.h>
#include <sys/wait.h>
#include <thread>
#include <unordered_map>
#include <unistd.h>
#include <vector>

namespace pulsar::ui {
namespace {

struct Request {
  std::string method;
  std::string path;
  std::string query;
  std::string body;
};

struct WifiUsageSession {
  std::string connectedAt;
  uint64_t baseTotalBytes = 0;
  uint64_t lastSessionBytes = 0;
  uint64_t lastTotalBytes = 0;
};

std::mutex wifiUsageMutex;
std::string activeWifiUsageKey;
std::unordered_map<std::string, WifiUsageSession> wifiUsageSessions;

struct StereoAutoAlignRuntime {
  std::mutex mutex;
  bool enabled = false;
  bool active = false;
  std::string trigger = "Hold Button";
  double xOffset = 0.0;
  double yOffset = 0.0;
  double xRatio = 0.0;
  double yRatio = 0.0;
  int quality = 0;
  int samples = 0;
  std::string status = "Idle";
  std::string message = "Hold Align to match both views.";
};

struct StereoAlignmentEstimate {
  bool ok = false;
  double xOffset = 0.0;
  double yOffset = 0.0;
  int quality = 0;
  std::string message = "Waiting for stereo frames.";
};

StereoAutoAlignRuntime stereoAutoAlignRuntime;

bool sendAll(int fd, const void* data, size_t size) {
  const auto* bytes = static_cast<const uint8_t*>(data);
  while (size > 0) {
    const ssize_t sent = ::send(fd, bytes, size, MSG_NOSIGNAL);
    if (sent <= 0) return false;
    bytes += sent;
    size -= static_cast<size_t>(sent);
  }
  return true;
}

bool sendAll(int fd, const std::string& data) { return sendAll(fd, data.data(), data.size()); }

std::string lower(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
  return value;
}

std::optional<Request> readRequest(int fd) {
  std::string buffer;
  buffer.reserve(8192);
  std::array<char, 4096> chunk{};
  size_t headerEnd = std::string::npos;
  while (buffer.size() < 2u * 1024u * 1024u) {
    const ssize_t count = ::recv(fd, chunk.data(), chunk.size(), 0);
    if (count <= 0) return std::nullopt;
    buffer.append(chunk.data(), static_cast<size_t>(count));
    headerEnd = buffer.find("\r\n\r\n");
    if (headerEnd != std::string::npos) break;
  }
  if (headerEnd == std::string::npos) return std::nullopt;

  std::istringstream headers(buffer.substr(0, headerEnd));
  Request request;
  std::string version;
  headers >> request.method >> request.path >> version;
  if (request.method.empty() || request.path.empty()) return std::nullopt;

  size_t contentLength = 0;
  std::string line;
  std::getline(headers, line);
  while (std::getline(headers, line)) {
    if (!line.empty() && line.back() == '\r') line.pop_back();
    const auto colon = line.find(':');
    if (colon == std::string::npos) continue;
    const std::string key = lower(line.substr(0, colon));
    if (key == "content-length") {
      try { contentLength = static_cast<size_t>(std::stoull(line.substr(colon + 1))); } catch (...) { return std::nullopt; }
    }
  }
  const size_t bodyStart = headerEnd + 4;
  while (buffer.size() - bodyStart < contentLength && buffer.size() < 2u * 1024u * 1024u) {
    const ssize_t count = ::recv(fd, chunk.data(), chunk.size(), 0);
    if (count <= 0) return std::nullopt;
    buffer.append(chunk.data(), static_cast<size_t>(count));
  }
  if (buffer.size() - bodyStart < contentLength) return std::nullopt;
  request.body = buffer.substr(bodyStart, contentLength);
  const auto query = request.path.find('?');
  if (query != std::string::npos) {
    request.query = request.path.substr(query + 1);
    request.path.resize(query);
  }
  return request;
}

std::string escapeJson(std::string_view input) {
  std::string out;
  out.reserve(input.size() + 8);
  for (char c : input) {
    switch (c) {
      case '\\': out += "\\\\"; break;
      case '"': out += "\\\""; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default: out += c; break;
    }
  }
  return out;
}

std::string trim(std::string value) {
  const auto first = value.find_first_not_of(" \t\r\n");
  if (first == std::string::npos) return {};
  const auto last = value.find_last_not_of(" \t\r\n");
  return value.substr(first, last - first + 1);
}

std::string isoTimestampNow() {
  const std::time_t now = std::time(nullptr);
  std::tm utc{};
  gmtime_r(&now, &utc);
  std::ostringstream timestamp;
  timestamp << std::put_time(&utc, "%Y-%m-%dT%H:%M:%SZ");
  return timestamp.str();
}

std::string unescapeJson(std::string_view input) {
  std::string out;
  out.reserve(input.size());
  for (size_t i = 0; i < input.size(); ++i) {
    const char c = input[i];
    if (c != '\\' || i + 1 >= input.size()) {
      out.push_back(c);
      continue;
    }
    const char next = input[++i];
    switch (next) {
      case '\\': out.push_back('\\'); break;
      case '"': out.push_back('"'); break;
      case '/': out.push_back('/'); break;
      case 'b': out.push_back('\b'); break;
      case 'f': out.push_back('\f'); break;
      case 'n': out.push_back('\n'); break;
      case 'r': out.push_back('\r'); break;
      case 't': out.push_back('\t'); break;
      default: out.push_back(next); break;
    }
  }
  return out;
}

std::optional<double> jsonNumber(const std::string& body, const std::string& key) {
  const std::regex pattern("\\\"" + key + "\\\"\\s*:\\s*(-?[0-9]+(?:\\.[0-9]+)?)");
  std::smatch match;
  if (!std::regex_search(body, match, pattern)) return std::nullopt;
  try { return std::stod(match[1].str()); } catch (...) { return std::nullopt; }
}

std::optional<bool> jsonBool(const std::string& body, const std::string& key) {
  const std::regex pattern("\\\"" + key + "\\\"\\s*:\\s*(true|false)");
  std::smatch match;
  if (!std::regex_search(body, match, pattern)) return std::nullopt;
  return match[1].str() == "true";
}

std::optional<std::string> jsonString(const std::string& body, const std::string& key) {
  const std::regex pattern("\\\"" + key + "\\\"\\s*:\\s*\\\"((?:\\\\.|[^\\\\\\\"])*)\\\"");
  std::smatch match;
  if (!std::regex_search(body, match, pattern)) return std::nullopt;
  return unescapeJson(match[1].str());
}

std::string mimeFor(const std::filesystem::path& path) {
  const std::string ext = lower(path.extension().string());
  if (ext == ".html") return "text/html; charset=utf-8";
  if (ext == ".js" || ext == ".mjs") return "text/javascript; charset=utf-8";
  if (ext == ".css") return "text/css; charset=utf-8";
  if (ext == ".json") return "application/json; charset=utf-8";
  if (ext == ".svg") return "image/svg+xml";
  if (ext == ".png") return "image/png";
  if (ext == ".jpg" || ext == ".jpeg") return "image/jpeg";
  if (ext == ".woff2") return "font/woff2";
  return "application/octet-stream";
}

void response(int fd, std::string_view status, std::string_view contentType,
              const void* body, size_t size, std::string_view extra = {}) {
  std::ostringstream header;
  header << "HTTP/1.1 " << status << "\r\n"
         << "Content-Type: " << contentType << "\r\n"
         << "Content-Length: " << size << "\r\n"
         << "Cache-Control: no-store\r\n"
         << "X-Content-Type-Options: nosniff\r\n"
         << "Connection: close\r\n" << extra << "\r\n";
  if (!sendAll(fd, header.str())) return;
  if (size > 0) sendAll(fd, body, size);
}

void textResponse(int fd, std::string_view status, std::string_view contentType, const std::string& body) {
  response(fd, status, contentType, body.data(), body.size());
}

int cameraIndexFromPath(const std::string& path, std::string_view suffix = {}) {
  if (path.size() < 10 || path.rfind("/camera/", 0) != 0) return -1;
  const char value = path[8];
  if (value != '0' && value != '1') return -1;
  if (!suffix.empty() && path.substr(9) != suffix) return -1;
  return value - '0';
}

int apiCameraIndex(const std::string& path) {
  if (path == "/api/camera/0") return 0;
  if (path == "/api/camera/1") return 1;
  return -1;
}

bool queryHasValue(const std::string& query, std::string_view key, std::string_view value) {
  if (query.empty()) return false;
  std::istringstream stream(query);
  std::string item;
  while (std::getline(stream, item, '&')) {
    const auto equals = item.find('=');
    const std::string itemKey = equals == std::string::npos ? item : item.substr(0, equals);
    const std::string itemValue = equals == std::string::npos ? "" : item.substr(equals + 1);
    if (itemKey == key && itemValue == value) return true;
  }
  return false;
}

std::optional<std::string> queryValue(const std::string& query, std::string_view key) {
  if (query.empty()) return std::nullopt;
  std::istringstream stream(query);
  std::string item;
  while (std::getline(stream, item, '&')) {
    const auto equals = item.find('=');
    const std::string itemKey = equals == std::string::npos ? item : item.substr(0, equals);
    const std::string itemValue = equals == std::string::npos ? "" : item.substr(equals + 1);
    if (itemKey == key) return itemValue;
  }
  return std::nullopt;
}

std::string stereoTriggerLabel(std::string_view triggerValue) {
  if (triggerValue == "pedal") return "Pedal";
  if (triggerValue == "zoom") return "Hardware Zoom";
  if (triggerValue == "manual") return "Manual";
  return "Hold Button";
}

std::vector<uint8_t> makeStereoGrayPreview(const camera::Frame& frame, uint32_t targetWidth = 96, uint32_t targetHeight = 54) {
  std::vector<uint8_t> preview;
  if (!frame.rgb || frame.width == 0 || frame.height == 0 || targetWidth == 0 || targetHeight == 0) return preview;
  preview.resize(static_cast<size_t>(targetWidth) * targetHeight);
  const auto& rgb = *frame.rgb;
  for (uint32_t y = 0; y < targetHeight; ++y) {
    const uint32_t sourceY = std::min(frame.height - 1, static_cast<uint32_t>((static_cast<uint64_t>(y) * frame.height) / targetHeight));
    for (uint32_t x = 0; x < targetWidth; ++x) {
      const uint32_t sourceX = std::min(frame.width - 1, static_cast<uint32_t>((static_cast<uint64_t>(x) * frame.width) / targetWidth));
      const size_t index = (static_cast<size_t>(sourceY) * frame.width + sourceX) * 3;
      if (index + 2 >= rgb.size()) continue;
      const double gray = rgb[index] * 0.2126 + rgb[index + 1] * 0.7152 + rgb[index + 2] * 0.0722;
      preview[static_cast<size_t>(y) * targetWidth + x] = static_cast<uint8_t>(std::clamp(gray, 0.0, 255.0));
    }
  }
  return preview;
}

double stereoTextureScore(const std::vector<uint8_t>& image, int width, int height) {
  if (image.empty() || width <= 2 || height <= 2) return 0.0;
  double total = 0.0;
  size_t samples = 0;
  for (int y = 1; y < height - 1; y += 2) {
    for (int x = 1; x < width - 1; x += 2) {
      const size_t index = static_cast<size_t>(y) * width + x;
      total += std::abs(static_cast<int>(image[index]) - static_cast<int>(image[index + 1]));
      total += std::abs(static_cast<int>(image[index]) - static_cast<int>(image[index + width]));
      samples += 2;
    }
  }
  return samples == 0 ? 0.0 : total / static_cast<double>(samples);
}

double stereoSadScore(const std::vector<uint8_t>& left, const std::vector<uint8_t>& right, int width, int height, int dx, int dy) {
  const int marginX = 8;
  const int marginY = 6;
  const int startX = marginX + std::max(0, -dx);
  const int endX = width - marginX - std::max(0, dx);
  const int startY = marginY + std::max(0, -dy);
  const int endY = height - marginY - std::max(0, dy);
  if (endX - startX < 12 || endY - startY < 12) return 1e18;

  double total = 0.0;
  size_t samples = 0;
  for (int y = startY; y < endY; ++y) {
    for (int x = startX; x < endX; ++x) {
      const size_t leftIndex = static_cast<size_t>(y) * width + x;
      const size_t rightIndex = static_cast<size_t>(y + dy) * width + (x + dx);
      total += std::abs(static_cast<int>(left[leftIndex]) - static_cast<int>(right[rightIndex]));
      ++samples;
    }
  }
  return samples == 0 ? 1e18 : total / static_cast<double>(samples);
}

StereoAlignmentEstimate estimateStereoAlignment(const camera::CameraStatus& leftStatus, const camera::CameraStatus& rightStatus) {
  StereoAlignmentEstimate estimate;
  if (!leftStatus.online || !rightStatus.online || !leftStatus.frame || !rightStatus.frame) {
    estimate.message = "Waiting for live stereo frames.";
    return estimate;
  }
  if (!leftStatus.frame->rgb || !rightStatus.frame->rgb) {
    estimate.message = "Stereo preview frames are not ready yet.";
    return estimate;
  }

  constexpr int sampleWidth = 144;
  constexpr int sampleHeight = 81;
  constexpr int searchX = 10;
  constexpr int searchY = 6;

  const auto left = makeStereoGrayPreview(*leftStatus.frame, sampleWidth, sampleHeight);
  const auto right = makeStereoGrayPreview(*rightStatus.frame, sampleWidth, sampleHeight);
  if (left.empty() || right.empty()) {
    estimate.message = "Stereo preview frames are empty.";
    return estimate;
  }

  const double texture = std::min(stereoTextureScore(left, sampleWidth, sampleHeight), stereoTextureScore(right, sampleWidth, sampleHeight));
  if (texture < 10.0) {
    estimate.message = "Scene detail is too low for precise auto alignment.";
    return estimate;
  }

  std::vector<double> scores(static_cast<size_t>((searchX * 2 + 1) * (searchY * 2 + 1)), 1e18);
  const auto scoreIndex = [=](int dx, int dy) {
    return static_cast<size_t>((dy + searchY) * (searchX * 2 + 1) + (dx + searchX));
  };

  double bestScore = 1e18;
  double secondScore = 1e18;
  int bestDx = 0;
  int bestDy = 0;
  const double baselineScore = stereoSadScore(left, right, sampleWidth, sampleHeight, 0, 0);

  for (int dy = -searchY; dy <= searchY; ++dy) {
    for (int dx = -searchX; dx <= searchX; ++dx) {
      const double score = stereoSadScore(left, right, sampleWidth, sampleHeight, dx, dy);
      scores[scoreIndex(dx, dy)] = score;
      if (score < bestScore) {
        secondScore = bestScore;
        bestScore = score;
        bestDx = dx;
        bestDy = dy;
      } else if (score < secondScore) {
        secondScore = score;
      }
    }
  }

  auto subPixelOffset = [&](int centerDx, int centerDy, bool horizontal) {
    const int axisLimit = horizontal ? searchX : searchY;
    const int axisValue = horizontal ? centerDx : centerDy;
    if (axisValue <= -axisLimit || axisValue >= axisLimit) return 0.0;
    const double center = scores[scoreIndex(centerDx, centerDy)];
    const double negative = scores[scoreIndex(horizontal ? centerDx - 1 : centerDx, horizontal ? centerDy : centerDy - 1)];
    const double positive = scores[scoreIndex(horizontal ? centerDx + 1 : centerDx, horizontal ? centerDy : centerDy + 1)];
    const double denominator = negative - 2.0 * center + positive;
    if (std::abs(denominator) < 1e-9) return 0.0;
    return std::clamp(0.5 * (negative - positive) / denominator, -1.0, 1.0);
  };

  const double refinedDx = static_cast<double>(bestDx) + subPixelOffset(bestDx, bestDy, true);
  const double refinedDy = static_cast<double>(bestDy) + subPixelOffset(bestDx, bestDy, false);

  const double baseline = std::max(1.0, baselineScore);
  const double improvement = std::clamp((baseline - bestScore) / baseline, 0.0, 1.0);
  const double uniqueness = secondScore >= 1e17 ? 0.0 : std::clamp((secondScore - bestScore) / std::max(1.0, secondScore), 0.0, 1.0);
  const double textureWeight = std::clamp(texture / 28.0, 0.0, 1.0);
  const int quality = static_cast<int>(std::round(std::clamp(42.0 + improvement * 34.0 + uniqueness * 15.0 + textureWeight * 8.0, 0.0, 99.0)));

  estimate.ok = quality >= 55;
  estimate.xOffset = -refinedDx * static_cast<double>(leftStatus.frame->width) / sampleWidth;
  estimate.yOffset = -refinedDy * static_cast<double>(leftStatus.frame->height) / sampleHeight;
  estimate.quality = quality;
  estimate.message = estimate.ok ? "Stereo views aligned from live frames." : "Auto alignment confidence is too low. Hold steady and try again.";
  return estimate;
}

void applyStereoAutoAlignSample(StereoAutoAlignRuntime& runtime, camera::CameraManager& cameras) {
  const auto left = cameras.snapshot(0);
  const auto right = cameras.snapshot(1);
  const auto estimate = estimateStereoAlignment(left, right);

  std::lock_guard<std::mutex> lock(runtime.mutex);
  if (!runtime.enabled) return;
  if (!estimate.ok) {
    runtime.quality = estimate.quality;
    runtime.status = runtime.active ? "Searching" : (runtime.samples > 0 ? "Locked" : "Ready");
    runtime.message = estimate.message;
    return;
  }

  const double blend = runtime.samples == 0 ? 1.0 : 0.42;
  const double estimateXRatio = left.frame && left.frame->width > 0 ? estimate.xOffset / static_cast<double>(left.frame->width) : 0.0;
  const double estimateYRatio = left.frame && left.frame->height > 0 ? estimate.yOffset / static_cast<double>(left.frame->height) : 0.0;
  runtime.xOffset = runtime.xOffset * (1.0 - blend) + estimate.xOffset * blend;
  runtime.yOffset = runtime.yOffset * (1.0 - blend) + estimate.yOffset * blend;
  runtime.xRatio = runtime.xRatio * (1.0 - blend) + estimateXRatio * blend;
  runtime.yRatio = runtime.yRatio * (1.0 - blend) + estimateYRatio * blend;
  runtime.quality = runtime.samples == 0 ? estimate.quality : static_cast<int>(std::round(runtime.quality * (1.0 - blend) + estimate.quality * blend));
  runtime.samples = std::min(runtime.samples + 1, 9999);
  runtime.status = runtime.active ? "Tracking" : "Locked";
  runtime.message = runtime.active ? "Hold Align to keep refining live stereo overlap." : "Auto alignment locked.";
}

void syncStereoAutoAlignDisplayState(core::AppState& state) {
  core::DisplayControls display = state.display();
  {
    std::lock_guard<std::mutex> lock(stereoAutoAlignRuntime.mutex);
    display.stereoAlignEnabled = stereoAutoAlignRuntime.enabled && stereoAutoAlignRuntime.samples > 0;
    display.stereoAlignX = stereoAutoAlignRuntime.xOffset;
    display.stereoAlignY = stereoAutoAlignRuntime.yOffset;
    display.stereoAlignXRatio = stereoAutoAlignRuntime.xRatio;
    display.stereoAlignYRatio = stereoAutoAlignRuntime.yRatio;
  }
  state.updateDisplay(display);
}

std::string stereoAutoAlignJson() {
  std::lock_guard<std::mutex> lock(stereoAutoAlignRuntime.mutex);
  std::ostringstream json;
  json << "{\"enabled\":" << (stereoAutoAlignRuntime.enabled ? "true" : "false")
       << ",\"active\":" << (stereoAutoAlignRuntime.active ? "true" : "false")
       << ",\"trigger\":\"" << escapeJson(stereoAutoAlignRuntime.trigger) << "\""
       << ",\"xOffset\":" << std::fixed << std::setprecision(2) << stereoAutoAlignRuntime.xOffset
       << ",\"yOffset\":" << std::fixed << std::setprecision(2) << stereoAutoAlignRuntime.yOffset
       << ",\"xRatio\":" << std::fixed << std::setprecision(6) << stereoAutoAlignRuntime.xRatio
       << ",\"yRatio\":" << std::fixed << std::setprecision(6) << stereoAutoAlignRuntime.yRatio
       << ",\"quality\":" << stereoAutoAlignRuntime.quality
       << ",\"samples\":" << stereoAutoAlignRuntime.samples
       << ",\"status\":\"" << escapeJson(stereoAutoAlignRuntime.status) << "\""
       << ",\"message\":\"" << escapeJson(stereoAutoAlignRuntime.message) << "\"}";
  return json.str();
}

std::string runCommand(const std::vector<std::string>& args, std::chrono::milliseconds timeout) {
  if (args.empty()) throw std::runtime_error("No command was specified.");

  int pipefd[2];
  if (::pipe(pipefd) != 0) throw std::runtime_error(std::string("pipe failed: ") + std::strerror(errno));

  const pid_t pid = ::fork();
  if (pid < 0) {
    ::close(pipefd[0]);
    ::close(pipefd[1]);
    throw std::runtime_error(std::string("fork failed: ") + std::strerror(errno));
  }

  if (pid == 0) {
    ::dup2(pipefd[1], STDOUT_FILENO);
    ::dup2(pipefd[1], STDERR_FILENO);
    ::close(pipefd[0]);
    ::close(pipefd[1]);

    std::vector<char*> argv;
    argv.reserve(args.size() + 1);
    for (const auto& arg : args) argv.push_back(const_cast<char*>(arg.c_str()));
    argv.push_back(nullptr);
    ::execvp(argv[0], argv.data());
    _exit(127);
  }

  ::close(pipefd[1]);
  const int flags = ::fcntl(pipefd[0], F_GETFL, 0);
  if (flags >= 0) ::fcntl(pipefd[0], F_SETFL, flags | O_NONBLOCK);

  std::string output;
  std::array<char, 4096> buffer{};
  bool pipeOpen = true;
  bool childExited = false;
  int status = 0;
  const auto deadline = std::chrono::steady_clock::now() + timeout;

  while (pipeOpen || !childExited) {
    const auto now = std::chrono::steady_clock::now();
    if (now >= deadline && !childExited) {
      ::kill(pid, SIGKILL);
      ::waitpid(pid, &status, 0);
      if (pipeOpen) ::close(pipefd[0]);
      throw std::runtime_error("Command timed out.");
    }

    const auto remaining =
        std::max(1, static_cast<int>(std::chrono::duration_cast<std::chrono::milliseconds>(deadline - now).count()));
    pollfd descriptor{pipefd[0], static_cast<short>(POLLIN | POLLHUP), 0};
    const int ready = pipeOpen ? ::poll(&descriptor, 1, remaining) : 0;
    if (ready > 0 && pipeOpen) {
      while (true) {
        const ssize_t count = ::read(pipefd[0], buffer.data(), buffer.size());
        if (count > 0) {
          output.append(buffer.data(), static_cast<size_t>(count));
          continue;
        }
        if (count == 0) {
          ::close(pipefd[0]);
          pipeOpen = false;
        }
        if (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
          ::close(pipefd[0]);
          pipeOpen = false;
        }
        break;
      }
    }

    if (!childExited) {
      const pid_t waited = ::waitpid(pid, &status, WNOHANG);
      if (waited == pid) childExited = true;
    }
  }

  const std::string detail = trim(output);
  if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
    throw std::runtime_error(detail.empty() ? "Command failed." : detail);
  }
  return output;
}

std::string resolveNmcliCommand() {
  static std::mutex mutex;
  static std::string cached;
  std::lock_guard<std::mutex> lock(mutex);
  if (!cached.empty()) return cached;

  std::vector<std::string> candidates;
  if (const char* envPath = std::getenv("PULSAR_NMCLI_PATH"); envPath != nullptr && *envPath != '\0') {
    candidates.emplace_back(envPath);
  }
  candidates.emplace_back("/snap/bin/network-manager.nmcli");
  candidates.emplace_back("/usr/bin/nmcli");
  candidates.emplace_back("nmcli");

  for (const auto& candidate : candidates) {
    try {
      runCommand({candidate, "--version"}, std::chrono::seconds(5));
      cached = candidate;
      return cached;
    } catch (...) {
    }
  }
  throw std::runtime_error("No compatible nmcli command was found.");
}

std::string runNmcli(const std::vector<std::string>& args, std::chrono::milliseconds timeout = std::chrono::seconds(15)) {
  std::vector<std::string> command{resolveNmcliCommand()};
  command.insert(command.end(), args.begin(), args.end());
  return runCommand(command, timeout);
}

std::vector<std::string> splitNmcliFields(const std::string& line) {
  std::vector<std::string> parts;
  std::string current;
  bool escaping = false;
  for (char character : line) {
    if (escaping) {
      current.push_back(character);
      escaping = false;
      continue;
    }
    if (character == '\\') {
      escaping = true;
      continue;
    }
    if (character == ':') {
      parts.push_back(trim(current));
      current.clear();
      continue;
    }
    current.push_back(character);
  }
  parts.push_back(trim(current));
  return parts;
}

std::string normalizeSecurity(const std::string& value) {
  return value == "--" ? "" : value;
}

std::string normalizeSsid(const std::string& value, std::string fallback = "Hidden network") {
  return value.empty() ? fallback : value;
}

int toSignalNumber(const std::string& value) {
  try {
    return std::clamp(std::stoi(value), 0, 100);
  } catch (...) {
    return 0;
  }
}

std::vector<std::pair<std::string, std::string>> parseNmcliKeyValueOutput(const std::string& output) {
  std::vector<std::pair<std::string, std::string>> entries;
  std::istringstream stream(output);
  std::string line;
  while (std::getline(stream, line)) {
    line = trim(line);
    if (line.empty()) continue;
    const auto separator = line.find(':');
    if (separator == std::string::npos) continue;
    entries.emplace_back(line.substr(0, separator), trim(line.substr(separator + 1)));
  }
  return entries;
}

std::vector<std::string> valuesForKeyPrefix(const std::vector<std::pair<std::string, std::string>>& entries,
                                            std::string_view prefix) {
  std::vector<std::string> values;
  for (const auto& [key, value] : entries) {
    if (key.rfind(prefix.data(), 0) == 0 && !value.empty()) values.push_back(value);
  }
  return values;
}

std::string valueForKey(const std::vector<std::pair<std::string, std::string>>& entries, std::string_view key) {
  for (const auto& [candidate, value] : entries) {
    if (candidate == key) return value;
  }
  return {};
}

uint64_t readStatistic(const std::string& deviceName, const char* statName) {
  std::ifstream input("/sys/class/net/" + deviceName + "/statistics/" + statName);
  uint64_t value = 0;
  input >> value;
  return value;
}

struct WifiUsage {
  uint64_t rxBytes = 0;
  uint64_t txBytes = 0;
  uint64_t totalBytes = 0;
  uint64_t sessionBytes = 0;
  std::string connectedAt;
};

WifiUsage getWifiUsage(const std::string& deviceName, const std::string& ssid) {
  const uint64_t rxBytes = readStatistic(deviceName, "rx_bytes");
  const uint64_t txBytes = readStatistic(deviceName, "tx_bytes");
  const uint64_t totalBytes = rxBytes + txBytes;
  const std::string usageKey = deviceName + ":" + ssid;

  std::lock_guard<std::mutex> lock(wifiUsageMutex);
  auto iterator = wifiUsageSessions.find(usageKey);
  if (activeWifiUsageKey != usageKey || iterator == wifiUsageSessions.end()) {
    wifiUsageSessions.clear();
    iterator = wifiUsageSessions.emplace(usageKey, WifiUsageSession{isoTimestampNow(), totalBytes, 0, totalBytes}).first;
    activeWifiUsageKey = usageKey;
  }

  auto& session = iterator->second;
  const uint64_t stableTotalBytes = std::max(totalBytes, session.lastTotalBytes);
  const uint64_t stableSessionBytes = std::max<uint64_t>(
      0, std::max(stableTotalBytes - session.baseTotalBytes, session.lastSessionBytes));
  session.lastTotalBytes = stableTotalBytes;
  session.lastSessionBytes = stableSessionBytes;

  return WifiUsage{rxBytes, txBytes, stableTotalBytes, stableSessionBytes, session.connectedAt};
}

void resetWifiUsage() {
  std::lock_guard<std::mutex> lock(wifiUsageMutex);
  activeWifiUsageKey.clear();
  wifiUsageSessions.clear();
}

struct WifiDeviceInfo {
  bool found = false;
  std::string device;
  std::string state;
  std::string connection;
};

WifiDeviceInfo getWifiDevice() {
  const std::string output = runNmcli({"-t", "-f", "DEVICE,TYPE,STATE,CONNECTION", "device", "status"});
  std::istringstream stream(output);
  std::string line;
  while (std::getline(stream, line)) {
    line = trim(line);
    if (line.empty()) continue;
    const auto parts = splitNmcliFields(line);
    if (parts.size() < 4 || parts[1] != "wifi") continue;
    return WifiDeviceInfo{true, parts[0], parts[2], parts[3]};
  }
  return {};
}

struct WifiNetworkInfo {
  std::string id;
  std::string ssid;
  std::string bssid;
  int signal = 0;
  std::string security;
  bool requiresPassword = false;
  bool isConnected = false;
  std::string channel;
  std::string frequency;
  std::string rate;
};

std::vector<WifiNetworkInfo> scanWifiNetworks(const std::string& deviceName, bool refresh) {
  if (refresh) {
    try {
      runNmcli({"device", "wifi", "rescan", "ifname", deviceName}, std::chrono::seconds(10));
    } catch (...) {
    }
  }

  const std::string output = runNmcli(
      {"-t", "-f", "IN-USE,SSID,BSSID,SIGNAL,SECURITY,CHAN,FREQ,RATE", "device", "wifi", "list", "ifname", deviceName});
  std::unordered_map<std::string, size_t> indexByKey;
  std::vector<WifiNetworkInfo> networks;
  size_t hiddenCount = 0;

  std::istringstream stream(output);
  std::string line;
  while (std::getline(stream, line)) {
    line = trim(line);
    if (line.empty()) continue;
    auto parts = splitNmcliFields(line);
    parts.resize(8);
    const std::string ssid = normalizeSsid(parts[1], "");
    const std::string security = normalizeSecurity(parts[4]);
    const std::string key = !ssid.empty() ? ssid : (!parts[2].empty() ? parts[2] : ("hidden-" + std::to_string(hiddenCount++)));
    WifiNetworkInfo network;
    network.id = key;
    network.ssid = normalizeSsid(parts[1]);
    network.bssid = parts[2];
    network.signal = toSignalNumber(parts[3]);
    network.security = security;
    network.requiresPassword = !security.empty();
    network.isConnected = parts[0] == "*";
    network.channel = parts[5];
    network.frequency = parts[6];
    network.rate = parts[7];

    const auto existing = indexByKey.find(key);
    if (existing == indexByKey.end()) {
      indexByKey.emplace(key, networks.size());
      networks.push_back(std::move(network));
      continue;
    }

    auto& current = networks[existing->second];
    if (network.isConnected || (!current.isConnected && network.signal > current.signal)) current = std::move(network);
  }

  std::sort(networks.begin(), networks.end(), [](const WifiNetworkInfo& left, const WifiNetworkInfo& right) {
    if (left.isConnected != right.isConnected) return left.isConnected;
    return left.signal > right.signal;
  });
  return networks;
}

std::string getSavedWifiPassword(const std::string& connectionName) {
  if (connectionName.empty()) return {};
  try {
    return trim(runNmcli({"-s", "-g", "802-11-wireless-security.psk", "connection", "show", connectionName}));
  } catch (...) {
    return {};
  }
}

std::string wifiConnectionDetailsJson(const std::string& deviceName) {
  const std::string output = runNmcli({"-t",
                                       "-f",
                                       "GENERAL.CONNECTION,IP4.ADDRESS,IP4.GATEWAY,IP4.DNS,IP6.ADDRESS,IP6.GATEWAY,IP6.DNS",
                                       "device",
                                       "show",
                                       deviceName});
  const auto entries = parseNmcliKeyValueOutput(output);
  const auto connectionName = valueForKey(entries, "GENERAL.CONNECTION");
  const auto ipv4 = valuesForKeyPrefix(entries, "IP4.ADDRESS");
  const auto ipv6 = valuesForKeyPrefix(entries, "IP6.ADDRESS");
  const auto dns = valuesForKeyPrefix(entries, "IP4.DNS");
  const auto dns6 = valuesForKeyPrefix(entries, "IP6.DNS");

  std::ostringstream json;
  json << "{\"connection\":\"" << escapeJson(connectionName) << "\",\"ipv4\":[";
  for (size_t i = 0; i < ipv4.size(); ++i) {
    if (i) json << ',';
    json << '"' << escapeJson(ipv4[i]) << '"';
  }
  json << "],\"ipv6\":[";
  for (size_t i = 0; i < ipv6.size(); ++i) {
    if (i) json << ',';
    json << '"' << escapeJson(ipv6[i]) << '"';
  }
  json << "],\"dns\":[";
  bool firstDns = true;
  for (const auto& value : dns) {
    if (!firstDns) json << ',';
    json << '"' << escapeJson(value) << '"';
    firstDns = false;
  }
  for (const auto& value : dns6) {
    if (!firstDns) json << ',';
    json << '"' << escapeJson(value) << '"';
    firstDns = false;
  }
  json << "],\"gateway4\":\"" << escapeJson(valueForKey(entries, "IP4.GATEWAY")) << "\",\"gateway6\":\""
       << escapeJson(valueForKey(entries, "IP6.GATEWAY")) << "\",\"password\":\""
       << escapeJson(getSavedWifiPassword(connectionName)) << "\"}";
  return json.str();
}

std::string wifiUsageJson(const std::string& deviceName, const std::string& ssid) {
  const auto usage = getWifiUsage(deviceName, ssid);
  std::ostringstream json;
  json << "{\"rxBytes\":" << usage.rxBytes << ",\"txBytes\":" << usage.txBytes << ",\"totalBytes\":" << usage.totalBytes
       << ",\"sessionBytes\":" << usage.sessionBytes << ",\"connectedAt\":\"" << usage.connectedAt << "\"}";
  return json.str();
}

std::string wifiSnapshotJson(bool refresh) {
  const auto wifiDevice = getWifiDevice();
  if (!wifiDevice.found) {
    resetWifiUsage();
    return "{\"available\":false,\"device\":null,\"state\":\"missing\",\"connected\":false,\"ssid\":null,"
           "\"signal\":0,\"security\":\"\",\"details\":null,\"usage\":null,\"networks\":[]}";
  }

  const auto networks = scanWifiNetworks(wifiDevice.device, refresh);
  std::optional<WifiNetworkInfo> activeNetwork;
  for (const auto& network : networks) {
    if (network.isConnected) {
      activeNetwork = network;
      break;
    }
  }
  if (!activeNetwork.has_value() && !wifiDevice.connection.empty()) {
    activeNetwork = WifiNetworkInfo{wifiDevice.connection, wifiDevice.connection, "", 0, "", false, true, "", "", ""};
  }

  if (!activeNetwork.has_value() || activeNetwork->ssid.empty()) resetWifiUsage();

  std::ostringstream json;
  json << "{\"available\":true,\"device\":\"" << escapeJson(wifiDevice.device) << "\",\"state\":\""
       << escapeJson(wifiDevice.state) << "\",\"connected\":"
       << (activeNetwork.has_value() && !activeNetwork->ssid.empty() ? "true" : "false") << ",\"ssid\":";
  if (activeNetwork.has_value() && !activeNetwork->ssid.empty()) json << '"' << escapeJson(activeNetwork->ssid) << '"';
  else json << "null";
  json << ",\"signal\":" << (activeNetwork.has_value() ? activeNetwork->signal : 0) << ",\"security\":\""
       << escapeJson(activeNetwork.has_value() ? activeNetwork->security : "") << "\",\"details\":";
  if (activeNetwork.has_value() && !activeNetwork->ssid.empty()) json << wifiConnectionDetailsJson(wifiDevice.device);
  else json << "null";
  json << ",\"usage\":";
  if (activeNetwork.has_value() && !activeNetwork->ssid.empty()) json << wifiUsageJson(wifiDevice.device, activeNetwork->ssid);
  else json << "null";
  json << ",\"networks\":[";
  for (size_t i = 0; i < networks.size(); ++i) {
    if (i) json << ',';
    const auto& network = networks[i];
    json << "{\"id\":\"" << escapeJson(network.id) << "\",\"ssid\":\"" << escapeJson(network.ssid) << "\",\"bssid\":\""
         << escapeJson(network.bssid) << "\",\"signal\":" << network.signal << ",\"security\":\""
         << escapeJson(network.security) << "\",\"requiresPassword\":" << (network.requiresPassword ? "true" : "false")
         << ",\"isConnected\":" << (network.isConnected ? "true" : "false") << ",\"channel\":\""
         << escapeJson(network.channel) << "\",\"frequency\":\"" << escapeJson(network.frequency) << "\",\"rate\":\""
         << escapeJson(network.rate) << "\"}";
  }
  json << "]}";
  return json.str();
}

std::string connectWifiJson(const std::string& ssid, const std::string& password) {
  const auto wifiDevice = getWifiDevice();
  if (!wifiDevice.found) throw std::runtime_error("No Wi-Fi adapter was detected.");

  std::vector<std::string> args{"--wait", "30", "device", "wifi", "connect", ssid, "ifname", wifiDevice.device};
  if (!password.empty()) {
    args.emplace_back("password");
    args.emplace_back(password);
  }
  runNmcli(args, std::chrono::seconds(30));
  return wifiSnapshotJson(true);
}

std::string disconnectWifiJson() {
  const auto wifiDevice = getWifiDevice();
  if (!wifiDevice.found) throw std::runtime_error("No Wi-Fi adapter was detected.");
  if (!wifiDevice.connection.empty()) {
    runNmcli({"--wait", "20", "device", "disconnect", wifiDevice.device}, std::chrono::seconds(20));
  }
  return wifiSnapshotJson(true);
}

std::string wifiSpeedTestJson() {
  const std::string snapshot = wifiSnapshotJson(false);
  if (snapshot.find("\"connected\":true") == std::string::npos) {
    throw std::runtime_error("Connect to a Wi-Fi network before running the speed test.");
  }

  const std::string latencyOutput =
      trim(runCommand({"curl", "-L", "-o", "/dev/null", "-sS", "-w", "%{time_starttransfer}",
                       "https://www.google.com/generate_204"},
                      std::chrono::seconds(20)));
  const double latencySeconds = std::stod(latencyOutput);

  const std::string speedOutput =
      trim(runCommand({"curl", "-L", "-o", "/dev/null", "-sS", "-w", "%{time_total} %{speed_download} %{size_download}",
                       "https://speed.cloudflare.com/__down?bytes=8000000"},
                      std::chrono::seconds(45)));
  std::istringstream stream(speedOutput);
  double seconds = 0;
  double bytesPerSecond = 0;
  uint64_t bytesRead = 0;
  stream >> seconds >> bytesPerSecond >> bytesRead;
  if (!stream || !std::isfinite(seconds) || !std::isfinite(bytesPerSecond)) {
    throw std::runtime_error("Download speed test failed.");
  }

  std::ostringstream json;
  json << std::fixed << std::setprecision(1)
       << "{\"latencyMs\":" << static_cast<int>(std::round(latencySeconds * 1000.0))
       << ",\"downloadMbps\":" << ((bytesPerSecond * 8.0) / 1000000.0) << ",\"transferredBytes\":" << bytesRead
       << ",\"measuredAt\":\"" << isoTimestampNow() << "\",\"source\":\"speed.cloudflare.com\"}";
  return json.str();
}

}  // namespace

HttpServer::HttpServer(core::AppState& state, camera::CameraManager& cameras,
                       camera::Recorder& recorder, const core::Config& config)
    : state_(state), cameras_(cameras), recorder_(recorder), host_(config.host),
      port_(config.port), uiRoot_(config.uiRoot) {}

bool HttpServer::run(std::atomic<bool>& running) {
  runningSignal_ = &running;
  const int server = ::socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (server < 0) return false;
  int yes = 1;
  setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
  sockaddr_in address{};
  address.sin_family = AF_INET;
  address.sin_port = htons(port_);
  if (inet_pton(AF_INET, host_.c_str(), &address.sin_addr) != 1 ||
      ::bind(server, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0 ||
      ::listen(server, 32) != 0) {
    std::cerr << "HTTP server bind failed on " << host_ << ':' << port_ << ": " << std::strerror(errno) << '\n';
    ::close(server);
    return false;
  }
  std::cout << "Pulsar UI/API listening on http://" << host_ << ':' << port_ << '\n';
  while (running) {
    pollfd descriptor{server, POLLIN, 0};
    const int ready = ::poll(&descriptor, 1, 250);
    if (ready <= 0) continue;
    const int client = ::accept4(server, nullptr, nullptr, SOCK_CLOEXEC);
    if (client < 0) continue;
    timeval timeout{3, 0};
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    activeClients_.fetch_add(1);
    std::thread([this, client] {
      handleClient(client);
      ::shutdown(client, SHUT_RDWR);
      ::close(client);
      if (activeClients_.fetch_sub(1) == 1) clientsCv_.notify_all();
    }).detach();
  }
  ::close(server);
  std::unique_lock<std::mutex> lock(clientsMutex_);
  clientsCv_.wait(lock, [this] { return activeClients_.load() == 0; });
  runningSignal_ = nullptr;
  return true;
}

void HttpServer::handleClient(int fd) {
  const auto request = readRequest(fd);
  if (!request) return;
  if (request->method == "OPTIONS") {
    textResponse(fd, "204 No Content", "text/plain", "");
    return;
  }
  if (request->method == "GET" && request->path == "/health") {
    textResponse(fd, "200 OK", "application/json; charset=utf-8",
                 std::string("{\"ok\":true,\"sdkReady\":") + (cameras_.sdkReady() ? "true" : "false") +
                 ",\"mock\":" + (cameras_.usingMock() ? "true" : "false") + "}");
    return;
  }
  if (request->method == "GET" && request->path == "/api/state") {
    textResponse(fd, "200 OK", "application/json; charset=utf-8", stateJson());
    return;
  }
  if (request->method == "GET" && request->path == "/api/cameras") {
    textResponse(fd, "200 OK", "application/json; charset=utf-8", camerasJson());
    return;
  }
  if (request->method == "GET" && request->path == "/api/wifi/status") {
    try {
      textResponse(fd, "200 OK", "application/json; charset=utf-8", wifiSnapshotJson(queryHasValue(request->query, "refresh", "1")));
    } catch (const std::exception& error) {
      textResponse(fd, "200 OK", "application/json; charset=utf-8",
                   std::string("{\"available\":false,\"device\":null,\"state\":\"error\",\"connected\":false,\"ssid\":null,"
                               "\"signal\":0,\"security\":\"\",\"details\":null,\"usage\":null,\"networks\":[],\"error\":\"") +
                       escapeJson(error.what()) + "\"}");
    }
    return;
  }
  if (request->method == "GET" && request->path.rfind("/api/stereo/auto-align", 0) == 0) {
    const auto action = queryValue(request->query, "action");
    const auto enabledValue = queryValue(request->query, "enabled");
    const auto holdValue = queryValue(request->query, "active");
    const auto triggerValue = queryValue(request->query, "trigger");
    bool shouldSample = false;
    {
      std::lock_guard<std::mutex> lock(stereoAutoAlignRuntime.mutex);
      if (action && *action == "enable") {
        stereoAutoAlignRuntime.enabled = enabledValue && *enabledValue == "1";
        if (!stereoAutoAlignRuntime.enabled) {
          stereoAutoAlignRuntime.active = false;
          stereoAutoAlignRuntime.status = "Disabled";
          stereoAutoAlignRuntime.message = "Enable Auto Align to calibrate live stereo.";
        } else {
          stereoAutoAlignRuntime.status = stereoAutoAlignRuntime.samples > 0 ? "Locked" : "Ready";
          stereoAutoAlignRuntime.message = stereoAutoAlignRuntime.samples > 0 ? "Auto alignment ready. Hold Align to refine." : "Auto Align enabled. Hold Align to calibrate.";
          shouldSample = true;
        }
      } else if (action && *action == "trigger" && triggerValue) {
        stereoAutoAlignRuntime.trigger = stereoTriggerLabel(*triggerValue);
        stereoAutoAlignRuntime.message = "Auto alignment trigger updated.";
      } else if (action && *action == "hold") {
        const bool active = holdValue && *holdValue == "1";
        if (stereoAutoAlignRuntime.enabled) {
          stereoAutoAlignRuntime.active = active;
          stereoAutoAlignRuntime.status = active ? "Tracking" : (stereoAutoAlignRuntime.samples > 0 ? "Locked" : "Ready");
          stereoAutoAlignRuntime.message = active ? "Hold Align to keep refining live stereo overlap." : (stereoAutoAlignRuntime.samples > 0 ? "Auto alignment locked." : "Ready to align.");
          shouldSample = active;
        }
      } else if (action && *action == "sample") {
        shouldSample = stereoAutoAlignRuntime.enabled;
      } else if (action && *action == "reset") {
        stereoAutoAlignRuntime.active = false;
        stereoAutoAlignRuntime.xOffset = 0.0;
        stereoAutoAlignRuntime.yOffset = 0.0;
        stereoAutoAlignRuntime.xRatio = 0.0;
        stereoAutoAlignRuntime.yRatio = 0.0;
        stereoAutoAlignRuntime.quality = 0;
        stereoAutoAlignRuntime.samples = 0;
        stereoAutoAlignRuntime.status = stereoAutoAlignRuntime.enabled ? "Ready" : "Idle";
        stereoAutoAlignRuntime.message = stereoAutoAlignRuntime.enabled ? "Offsets reset. Hold Align to recalibrate." : "Hold Align to match both views.";
      } else if (stereoAutoAlignRuntime.enabled && stereoAutoAlignRuntime.active) {
        shouldSample = true;
      }
    }
    if (shouldSample) {
      applyStereoAutoAlignSample(stereoAutoAlignRuntime, cameras_);
    }
    syncStereoAutoAlignDisplayState(state_);
    textResponse(fd, "200 OK", "application/json; charset=utf-8", stereoAutoAlignJson());
    return;
  }

  const int frameIndex = cameraIndexFromPath(request->path, "/frame.jpg");
  if (request->method == "GET" && frameIndex >= 0) {
    const auto camera = cameras_.snapshot(static_cast<size_t>(frameIndex));
    std::vector<uint8_t> offline;
    const std::vector<uint8_t>* jpeg = nullptr;
    if (camera.frame && camera.frame->jpeg && !camera.frame->jpeg->empty()) jpeg = camera.frame->jpeg.get();
    else {
      const auto rgb = camera::makeOfflineRgb(960, 540, static_cast<uint8_t>(frameIndex * 31));
      offline = camera::encodeJpeg(rgb.data(), 960, 540, 80);
      jpeg = &offline;
    }
    response(fd, "200 OK", "image/jpeg", jpeg->data(), jpeg->size());
    return;
  }
  const int streamIndex = cameraIndexFromPath(request->path, "/stream.mjpg");
  if (request->method == "GET" && streamIndex >= 0) {
    handleStream(fd, static_cast<size_t>(streamIndex));
    return;
  }
  const int streamAliasIndex = cameraIndexFromPath(request->path, "/stream");
  if (request->method == "GET" && streamAliasIndex >= 0) {
    handleStream(fd, static_cast<size_t>(streamAliasIndex));
    return;
  }

  const int cameraIndex = apiCameraIndex(request->path);
  if (request->method == "POST" && cameraIndex >= 0) {
    auto controls = state_.camera(static_cast<size_t>(cameraIndex));
    if (auto value = jsonNumber(request->body, "zoom")) controls.zoom = *value;
    if (auto value = jsonNumber(request->body, "focus")) controls.focus = static_cast<int>(*value);
    if (auto value = jsonNumber(request->body, "brightness")) controls.brightness = static_cast<int>(*value);
    if (auto value = jsonNumber(request->body, "exposureUs")) controls.exposureUs = *value;
    if (auto value = jsonNumber(request->body, "gainDb")) controls.gainDb = *value;
    if (auto value = jsonBool(request->body, "autoExposure")) controls.autoExposure = *value;
    if (auto value = jsonString(request->body, "whiteBalance")) controls.whiteBalance = *value;
    if (auto value = jsonString(request->body, "enhance")) controls.enhance = *value;
    if (auto value = jsonNumber(request->body, "rotation")) controls.rotation = static_cast<int>(*value);
    if (auto value = jsonBool(request->body, "frozen")) controls.frozen = *value;
    state_.updateCamera(static_cast<size_t>(cameraIndex), controls);
    textResponse(fd, "200 OK", "application/json; charset=utf-8", cameraJson(static_cast<size_t>(cameraIndex)));
    return;
  }

  if (request->method == "POST" && request->path == "/api/display") {
    auto display = state_.display();
    if (auto value = jsonString(request->body, "mainDisplayMode")) display.mainDisplayMode = *value;
    if (auto value = jsonBool(request->body, "swapEyes")) display.swapEyes = *value;
    if (auto value = jsonNumber(request->body, "gapPx")) display.gapPx = static_cast<int>(*value);
    if (auto value = jsonBool(request->body, "mirrorLeft")) display.mirrorLeft = *value;
    if (auto value = jsonBool(request->body, "mirrorRight")) display.mirrorRight = *value;
    if (auto value = jsonString(request->body, "stereoMode")) display.stereoMode = *value;
    if (auto value = jsonNumber(request->body, "targetFps")) display.targetFps = static_cast<int>(*value);
    state_.updateDisplay(display);
    textResponse(fd, "200 OK", "application/json; charset=utf-8", stateJson());
    return;
  }
  if (request->method == "POST" && request->path == "/api/recording/start") {
    const bool ok = recorder_.start();
    textResponse(fd, ok ? "200 OK" : "500 Internal Server Error", "application/json; charset=utf-8", stateJson());
    return;
  }
  if (request->method == "POST" && request->path == "/api/recording/stop") {
    recorder_.stop();
    textResponse(fd, "200 OK", "application/json; charset=utf-8", stateJson());
    return;
  }
  if (request->method == "POST" && request->path == "/api/recording/snapshot") {
    const std::string file = recorder_.snapshot();
    textResponse(fd, file.empty() ? "503 Service Unavailable" : "200 OK", "application/json; charset=utf-8",
                 std::string("{\"file\":\"") + escapeJson(file) + "\"}");
    return;
  }
  if (request->method == "POST" && request->path == "/api/system/exit") {
    if (runningSignal_ != nullptr) runningSignal_->store(false);
    textResponse(fd, "202 Accepted", "application/json; charset=utf-8", "{\"ok\":true}");
    return;
  }
  if (request->method == "POST" && request->path == "/api/wifi/connect") {
    const std::string ssid = trim(jsonString(request->body, "ssid").value_or(""));
    if (ssid.empty()) {
      textResponse(fd, "400 Bad Request", "application/json; charset=utf-8", "{\"error\":\"Wi-Fi name is required.\"}");
      return;
    }
    try {
      textResponse(fd, "200 OK", "application/json; charset=utf-8",
                   connectWifiJson(ssid, jsonString(request->body, "password").value_or("")));
    } catch (const std::exception& error) {
      textResponse(fd, "500 Internal Server Error", "application/json; charset=utf-8",
                   std::string("{\"error\":\"") + escapeJson(error.what()) + "\"}");
    }
    return;
  }
  if (request->method == "POST" && request->path == "/api/wifi/disconnect") {
    try {
      textResponse(fd, "200 OK", "application/json; charset=utf-8", disconnectWifiJson());
    } catch (const std::exception& error) {
      textResponse(fd, "500 Internal Server Error", "application/json; charset=utf-8",
                   std::string("{\"error\":\"") + escapeJson(error.what()) + "\"}");
    }
    return;
  }
  if (request->method == "POST" && request->path == "/api/wifi/speedtest") {
    try {
      textResponse(fd, "200 OK", "application/json; charset=utf-8", wifiSpeedTestJson());
    } catch (const std::exception& error) {
      textResponse(fd, "500 Internal Server Error", "application/json; charset=utf-8",
                   std::string("{\"error\":\"") + escapeJson(error.what()) + "\"}");
    }
    return;
  }
  if (request->method == "POST" && request->path == "/api/robot") {
    auto robot = state_.robot();
    for (size_t i = 0; i < robot.motorPositions.size(); ++i) {
      if (auto value = jsonNumber(request->body, "motor" + std::to_string(i))) {
        robot.motorPositions[i] = std::clamp(static_cast<int>(*value), -10000, 10000);
      }
    }
    state_.updateRobot(robot);
    textResponse(fd, "200 OK", "application/json; charset=utf-8", stateJson());
    return;
  }

  if (request->method == "GET") {
    serveStatic(fd, request->path);
    return;
  }
  textResponse(fd, "404 Not Found", "application/json; charset=utf-8", "{\"error\":\"not found\"}");
}

void HttpServer::handleStream(int fd, size_t cameraIndex) {
  cameras_.acquirePreviewStream(cameraIndex);
  const auto releasePreview = [this, cameraIndex] {
    cameras_.releasePreviewStream(cameraIndex);
  };
  const std::string header =
      "HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=pulsarframe\r\n"
      "Cache-Control: no-store\r\nConnection: close\r\n\r\n";
  if (!sendAll(fd, header)) {
    releasePreview();
    return;
  }
  uint64_t previousFrame = 0;
  const std::vector<uint8_t>* previousJpeg = nullptr;
  std::vector<uint8_t> offline;
  while (runningSignal_ != nullptr && runningSignal_->load()) {
    camera::CameraStatus status;
    cameras_.waitForFrame(cameraIndex, previousFrame, status, 1000);
    const std::vector<uint8_t>* jpeg = nullptr;
    if (status.frame && status.frame->jpeg && !status.frame->jpeg->empty()) {
      previousFrame = status.frame->id;
      jpeg = status.frame->jpeg.get();
      if (jpeg == previousJpeg) continue;
      previousJpeg = jpeg;
    } else {
      const auto rgb = camera::makeOfflineRgb(960, 540, static_cast<uint8_t>((previousFrame++) & 0xffu));
      offline = camera::encodeJpeg(rgb.data(), 960, 540, 75);
      jpeg = &offline;
      previousJpeg = nullptr;
    }
    std::ostringstream part;
    part << "--pulsarframe\r\nContent-Type: image/jpeg\r\nContent-Length: " << jpeg->size() << "\r\n\r\n";
    if (!sendAll(fd, part.str()) || !sendAll(fd, jpeg->data(), jpeg->size()) || !sendAll(fd, "\r\n")) {
      releasePreview();
      return;
    }
  }
  releasePreview();
}

std::string HttpServer::cameraJson(size_t index) const {
  const auto status = cameras_.snapshot(index);
  const auto controls = state_.camera(index);
  std::ostringstream json;
  json << std::fixed << std::setprecision(2)
       << "{\"index\":" << index << ",\"online\":" << (status.online ? "true" : "false")
       << ",\"label\":\"" << escapeJson(status.label) << "\",\"model\":\"" << escapeJson(status.model)
       << "\",\"serial\":\"" << escapeJson(status.serial) << "\",\"error\":\"" << escapeJson(status.error)
       << "\",\"fps\":" << status.fps << ",\"width\":" << (status.frame ? status.frame->width : 0)
       << ",\"height\":" << (status.frame ? status.frame->height : 0)
       << ",\"controls\":{\"zoom\":" << controls.zoom << ",\"focus\":" << controls.focus
       << ",\"brightness\":" << controls.brightness << ",\"exposureUs\":" << controls.exposureUs
       << ",\"gainDb\":" << controls.gainDb << ",\"autoExposure\":" << (controls.autoExposure ? "true" : "false")
       << ",\"whiteBalance\":\"" << escapeJson(controls.whiteBalance) << "\",\"enhance\":\""
       << escapeJson(controls.enhance) << "\",\"rotation\":" << controls.rotation
       << ",\"frozen\":" << (controls.frozen ? "true" : "false") << "}}";
  return json.str();
}

std::string HttpServer::camerasJson() const {
  return std::string("{\"cameras\":[") + cameraJson(0) + "," + cameraJson(1) + "]}";
}

std::string HttpServer::stateJson() const {
  const auto state = state_.snapshot();
  std::ostringstream json;
  json << std::fixed << std::setprecision(2)
       << "{\"revision\":" << state.revision << ",\"cameras\":[" << cameraJson(0) << ',' << cameraJson(1)
       << "],\"display\":{\"mainDisplayMode\":\"" << escapeJson(state.display.mainDisplayMode)
       << "\",\"swapEyes\":" << (state.display.swapEyes ? "true" : "false")
       << ",\"gapPx\":" << state.display.gapPx << ",\"mirrorLeft\":" << (state.display.mirrorLeft ? "true" : "false")
       << ",\"mirrorRight\":" << (state.display.mirrorRight ? "true" : "false")
       << ",\"stereoMode\":\"" << escapeJson(state.display.stereoMode) << "\",\"targetFps\":" << state.display.targetFps
       << "},\"recording\":{\"active\":" << (state.recording.active ? "true" : "false")
       << ",\"lastFile\":\"" << escapeJson(state.recording.lastFile) << "\",\"elapsedSeconds\":" << state.recording.elapsedSeconds
       << "},\"robot\":{\"motors\":[";
  for (size_t i = 0; i < state.robot.motorPositions.size(); ++i) {
    if (i) json << ',';
    json << state.robot.motorPositions[i];
  }
  json << "]},\"system\":{\"memoryUsedPercent\":" << state.system.memoryUsedPercent
       << ",\"cpuLoad\":" << state.system.cpuLoad << ",\"processRssBytes\":" << state.system.processRssBytes
       << ",\"uptimeSeconds\":" << state.system.uptimeSeconds << ",\"version\":\"" << escapeJson(state.system.version)
       << "\"}}";
  return json.str();
}

void HttpServer::serveStatic(int fd, const std::string& requestPath) const {
  std::string relative = requestPath == "/" ? "index.html" : requestPath.substr(1);
  if (relative.find("..") != std::string::npos || relative.find('\\') != std::string::npos) {
    textResponse(fd, "403 Forbidden", "text/plain", "forbidden");
    return;
  }
  std::filesystem::path file = uiRoot_ / relative;
  if (!std::filesystem::is_regular_file(file) && file.extension().empty()) file = uiRoot_ / "index.html";
  if (!std::filesystem::is_regular_file(file)) {
    textResponse(fd, "404 Not Found", "text/plain", "not found");
    return;
  }
  std::ifstream input(file, std::ios::binary);
  std::vector<char> data((std::istreambuf_iterator<char>(input)), std::istreambuf_iterator<char>());
  response(fd, "200 OK", mimeFor(file), data.data(), data.size(),
           file.filename() == "index.html"
               ? "Content-Security-Policy: default-src 'self'; img-src 'self' data: blob:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; connect-src 'self';\r\n"
               : "");
}

}  // namespace pulsar::ui
