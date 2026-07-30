#pragma once

#include "pulsar/core/AppState.hpp"

#include <atomic>
#include <thread>

namespace pulsar::core {

class ResourceMonitor {
 public:
  explicit ResourceMonitor(AppState& state);
  ~ResourceMonitor();
  void start();
  void stop();

 private:
  void loop();
  AppState& state_;
  std::atomic<bool> running_{false};
  std::thread worker_;
};

}  // namespace pulsar::core
