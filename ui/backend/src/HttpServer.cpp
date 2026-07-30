#include "pulsar/ui/HttpServer.hpp"

#include "pulsar/camera/JpegEncoder.hpp"

#include <arpa/inet.h>
#include <algorithm>
#include <array>
#include <cerrno>
#include <chrono>
#include <cctype>
#include <cmath>
#include <cstring>
#include <fcntl.h>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <iterator>
#include <netinet/in.h>
#include <optional>
#include <poll.h>
#include <regex>
#include <sstream>
#include <string_view>
#include <sys/socket.h>
#include <thread>
#include <unistd.h>
#include <vector>

namespace pulsar::ui {
namespace {

struct Request {
  std::string method;
  std::string path;
  std::string body;
};

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
  if (query != std::string::npos) request.path.resize(query);
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
  const std::regex pattern("\\\"" + key + "\\\"\\s*:\\s*\\\"([^\\\"]*)\\\"");
  std::smatch match;
  if (!std::regex_search(body, match, pattern)) return std::nullopt;
  return match[1].str();
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

}  // namespace

HttpServer::HttpServer(core::AppState& state, camera::CameraManager& cameras,
                       camera::Recorder& recorder, const core::Config& config)
    : state_(state), cameras_(cameras), recorder_(recorder), host_(config.host),
      port_(config.port), uiRoot_(config.uiRoot) {}

bool HttpServer::run(const std::atomic<bool>& running) {
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

void HttpServer::handleClient(int fd) const {
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

void HttpServer::handleStream(int fd, size_t cameraIndex) const {
  const std::string header =
      "HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=pulsarframe\r\n"
      "Cache-Control: no-store\r\nConnection: close\r\n\r\n";
  if (!sendAll(fd, header)) return;
  uint64_t previous = 0;
  std::vector<uint8_t> offline;
  while (runningSignal_ != nullptr && runningSignal_->load()) {
    camera::CameraStatus status;
    cameras_.waitForFrame(cameraIndex, previous, status, 1000);
    const std::vector<uint8_t>* jpeg = nullptr;
    if (status.frame && status.frame->jpeg && !status.frame->jpeg->empty()) {
      previous = status.frame->id;
      jpeg = status.frame->jpeg.get();
    } else {
      const auto rgb = camera::makeOfflineRgb(960, 540, static_cast<uint8_t>((previous++) & 0xffu));
      offline = camera::encodeJpeg(rgb.data(), 960, 540, 75);
      jpeg = &offline;
    }
    std::ostringstream part;
    part << "--pulsarframe\r\nContent-Type: image/jpeg\r\nContent-Length: " << jpeg->size() << "\r\n\r\n";
    if (!sendAll(fd, part.str()) || !sendAll(fd, jpeg->data(), jpeg->size()) || !sendAll(fd, "\r\n")) return;
  }
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
       << "],\"display\":{\"swapEyes\":" << (state.display.swapEyes ? "true" : "false")
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
           file.filename() == "index.html" ? "Content-Security-Policy: default-src 'self'; img-src 'self' data: blob:; style-src 'self' 'unsafe-inline'; script-src 'self'; connect-src 'self';\r\n" : "");
}

}  // namespace pulsar::ui
