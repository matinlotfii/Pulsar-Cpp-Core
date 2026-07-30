cmake_minimum_required(VERSION 3.20)
project(PulsarCppCore VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

find_package(Threads REQUIRED)
find_package(JPEG REQUIRED)
find_library(SDL2_RUNTIME_LIBRARY NAMES SDL2-2.0 SDL2)
if(NOT SDL2_RUNTIME_LIBRARY AND EXISTS "/lib/x86_64-linux-gnu/libSDL2-2.0.so.0")
  set(SDL2_RUNTIME_LIBRARY "/lib/x86_64-linux-gnu/libSDL2-2.0.so.0")
endif()
if(NOT SDL2_RUNTIME_LIBRARY)
  message(FATAL_ERROR "SDL2 runtime library was not found. Install libsdl2-2.0-0.")
endif()

set(GALAXY_ROOT "${CMAKE_SOURCE_DIR}/camera/vendor/galaxy")
set(GALAXY_INCLUDE "${GALAXY_ROOT}/include")
set(GALAXY_LIBRARY "${GALAXY_ROOT}/lib/libgxiapi.so")
set(GALAXY_LOG_LIBRARY "${GALAXY_ROOT}/lib/liblog4cplus_gx.so")
foreach(required "${GALAXY_INCLUDE}/GxIAPI.h" "${GALAXY_INCLUDE}/DxImageProc.h" "${GALAXY_LIBRARY}" "${GALAXY_LOG_LIBRARY}")
  if(NOT EXISTS "${required}")
    message(FATAL_ERROR "Missing bundled Galaxy SDK file: ${required}")
  endif()
endforeach()

add_library(pulsar_core_state
  core/src/AppState.cpp
  core/src/Config.cpp
  core/src/ResourceMonitor.cpp)
target_include_directories(pulsar_core_state PUBLIC core/include)
target_link_libraries(pulsar_core_state PUBLIC Threads::Threads)

add_library(pulsar_camera
  camera/src/CameraDevice.cpp
  camera/src/CameraManager.cpp
  camera/src/JpegEncoder.cpp
  camera/src/Recorder.cpp
  camera/src/SbsRenderer.cpp)
target_include_directories(pulsar_camera PUBLIC camera/include)
target_include_directories(pulsar_camera SYSTEM PUBLIC "${GALAXY_INCLUDE}")
target_link_libraries(pulsar_camera PUBLIC pulsar_core_state JPEG::JPEG "${SDL2_RUNTIME_LIBRARY}" Threads::Threads
  "${GALAXY_LIBRARY}" "${GALAXY_LOG_LIBRARY}")
set_target_properties(pulsar_camera PROPERTIES BUILD_RPATH "${GALAXY_ROOT}/lib")

add_library(pulsar_ui_backend ui/backend/src/HttpServer.cpp)
target_include_directories(pulsar_ui_backend PUBLIC ui/backend/include)
target_link_libraries(pulsar_ui_backend PUBLIC pulsar_core_state pulsar_camera Threads::Threads)

add_executable(pulsar-core core/src/main.cpp)
target_link_libraries(pulsar-core PRIVATE pulsar_ui_backend pulsar_camera pulsar_core_state)
set_target_properties(pulsar-core PROPERTIES BUILD_RPATH "${GALAXY_ROOT}/lib")
target_link_options(pulsar-core PRIVATE "-Wl,--disable-new-dtags,-rpath,$ORIGIN/../../camera/vendor/galaxy/lib")

foreach(target pulsar_core_state pulsar_camera pulsar_ui_backend pulsar-core)
  target_compile_options(${target} PRIVATE -Wall -Wextra -Wpedantic -Wconversion -Wshadow)
endforeach()

target_compile_options(pulsar-core PRIVATE $<$<CONFIG:Release>:-O3;-DNDEBUG>)
install(TARGETS pulsar-core RUNTIME DESTINATION bin)
