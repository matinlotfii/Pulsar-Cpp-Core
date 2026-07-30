#include "pulsar/core/ResourceMonitor.hpp"

#include <chrono>
#include <fstream>
#include <sstream>
#include <string>
#include <unistd.h>

namespace pulsar::core {
namespace {

uint64_t readRssBytes() {
  std::ifstream input("/proc/self/statm");
  uint64_t pages = 0;
  uint64_t resident = 0;
  input >> pages >> resident;
  return resident * static_cast<uint64_t>(::sysconf(_SC_PAGESIZE));
}

double readMemoryPercent() {
  std::ifstream input("/proc/meminfo");
  std::string key;
  uint64_t value = 0;
  std::string unit;
  uint64_t total = 0;
  uint64_t available = 0;
  while (input >> key >> value >> unit) {
    if (key == "MemTotal:") total = value;
    else if (key == "MemAvailable:") available = value;
  }
  if (total == 0) return 0.0;
  return 100.0 * static_cast<double>(total - available) / static_cast<double>(total);
}

double readLoad() {
  std::ifstream input("/proc/loadavg");
  double load = 0.0;
  input >> load;
  return load;
}

uint64_t readUptime() {
  std::ifstream input("/proc/uptime");
  double seconds = 0.0;
  input >> seconds;
  return static_cast<uint64_t>(seconds);
}

}  // namespace

ResourceMonitor::ResourceMonitor(AppState& state) : state_(state) {}
ResourceMonitor::~ResourceMonitor() { stop(); }

void ResourceMonitor::start() {
  if (running_.exchange(true)) return;
  worker_ = std::thread(&ResourceMonitor::loop, this);
}

void ResourceMonitor::stop() {
  running_ = false;
  if (worker_.joinable()) worker_.join();
}

void ResourceMonitor::loop() {
  while (running_) {
    SystemSnapshot snapshot;
    snapshot.memoryUsedPercent = readMemoryPercent();
    snapshot.cpuLoad = readLoad();
    snapshot.processRssBytes = readRssBytes();
    snapshot.uptimeSeconds = readUptime();
    state_.updateSystem(snapshot);
    for (int i = 0; i < 10 && running_; ++i) {
      std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
  }
}

}  // namespace pulsar::core
