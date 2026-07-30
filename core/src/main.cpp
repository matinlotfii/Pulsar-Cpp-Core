#include "pulsar/camera/CameraManager.hpp"
#include "pulsar/camera/Recorder.hpp"
#include "pulsar/camera/SbsRenderer.hpp"
#include "pulsar/core/AppState.hpp"
#include "pulsar/core/Config.hpp"
#include "pulsar/core/ResourceMonitor.hpp"
#include "pulsar/ui/HttpServer.hpp"

#include <atomic>
#include <csignal>
#include <filesystem>
#include <iostream>

namespace {
std::atomic<bool> gRunning{true};
void stopSignal(int) { gRunning = false; }
}

int main(int argc, char** argv) {
  std::signal(SIGINT, stopSignal);
  std::signal(SIGTERM, stopSignal);
  std::signal(SIGPIPE, SIG_IGN);

  const auto config = pulsar::core::loadConfig(argc, argv);
  std::filesystem::create_directories(config.dataRoot);

  pulsar::core::AppState state;
  pulsar::core::ResourceMonitor monitor(state);
  pulsar::camera::CameraManager cameras(state, config);
  pulsar::camera::Recorder recorder(cameras, state, config.dataRoot);
  pulsar::camera::SbsRenderer renderer(cameras, state, config);
  pulsar::ui::HttpServer server(state, cameras, recorder, config);

  monitor.start();
  cameras.start();
  renderer.start();

  std::cout << "Pulsar C++ Core started. Camera mode: " << config.cameraMode
            << ", UI root: " << config.uiRoot << '\n';
  const bool serverOk = server.run(gRunning);
  gRunning = false;

  recorder.stop();
  renderer.stop();
  cameras.stop();
  monitor.stop();
  return serverOk ? 0 : 1;
}
