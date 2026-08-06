cmake_minimum_required(VERSION 3.20)

# The development laptop can build the CPU fallback without CUDA, while the
# Pulsar target automatically enables CUDA when the versioned toolkit exists.
if(NOT DEFINED CMAKE_CUDA_COMPILER AND EXISTS "/usr/local/cuda-13.2/bin/nvcc")
  set(CMAKE_CUDA_COMPILER "/usr/local/cuda-13.2/bin/nvcc" CACHE FILEPATH "CUDA compiler" FORCE)
endif()

project(PulsarCppCore VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# RTX 3080 uses NVIDIA compute capability 8.6.
# This must be set before CMake performs its CUDA compiler test.
if(NOT DEFINED CMAKE_CUDA_ARCHITECTURES)
  set(CMAKE_CUDA_ARCHITECTURES 86 CACHE STRING "CUDA architectures")
endif()

include(CheckLanguage)
check_language(CUDA)
set(PULSAR_CUDA_AVAILABLE OFF)
if(CMAKE_CUDA_COMPILER)
  enable_language(CUDA)
  set(CMAKE_CUDA_STANDARD 17)
  set(CMAKE_CUDA_STANDARD_REQUIRED ON)
  find_package(CUDAToolkit 13.2 QUIET)
  if(CUDAToolkit_FOUND)
    set(PULSAR_CUDA_AVAILABLE ON)
  endif()
endif()
set(PULSAR_CUDA_AVAILABLE "${PULSAR_CUDA_AVAILABLE}" CACHE BOOL
  "Whether the CUDA/NPP camera pipeline is enabled" FORCE)

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

set(PULSAR_CAMERA_SOURCES
  camera/src/CameraDevice.cpp
  camera/src/CameraManager.cpp
  camera/src/JpegEncoder.cpp
  camera/src/Recorder.cpp
  camera/src/SbsRenderer.cpp)

if(PULSAR_CUDA_AVAILABLE)
  list(APPEND PULSAR_CAMERA_SOURCES camera/src/GpuBayerPipeline.cu)
else()
  list(APPEND PULSAR_CAMERA_SOURCES camera/src/GpuBayerPipelineStub.cpp)
endif()

add_library(pulsar_camera ${PULSAR_CAMERA_SOURCES})
target_include_directories(pulsar_camera PUBLIC camera/include)
target_include_directories(pulsar_camera SYSTEM PUBLIC "${GALAXY_INCLUDE}")
target_link_libraries(pulsar_camera PUBLIC pulsar_core_state JPEG::JPEG "${SDL2_RUNTIME_LIBRARY}" Threads::Threads
  "${GALAXY_LIBRARY}" "${GALAXY_LOG_LIBRARY}")
set_target_properties(pulsar_camera PROPERTIES BUILD_RPATH "${GALAXY_ROOT}/lib")

if(PULSAR_CUDA_AVAILABLE)
  find_library(PULSAR_NPPC_LIBRARY
    NAMES nppc
    HINTS "${CUDAToolkit_LIBRARY_DIR}" "${CUDAToolkit_ROOT}/targets/x86_64-linux/lib"
    REQUIRED)
  find_library(PULSAR_NPPICC_LIBRARY
    NAMES nppicc
    HINTS "${CUDAToolkit_LIBRARY_DIR}" "${CUDAToolkit_ROOT}/targets/x86_64-linux/lib"
    REQUIRED)
  find_library(PULSAR_NPPIG_LIBRARY
    NAMES nppig
    HINTS "${CUDAToolkit_LIBRARY_DIR}" "${CUDAToolkit_ROOT}/targets/x86_64-linux/lib"
    REQUIRED)

  target_compile_definitions(pulsar_camera PUBLIC PULSAR_HAS_CUDA=1)
  target_link_libraries(pulsar_camera PUBLIC
    CUDA::cudart
    "${PULSAR_NPPC_LIBRARY}"
    "${PULSAR_NPPICC_LIBRARY}"
    "${PULSAR_NPPIG_LIBRARY}")
  set_target_properties(pulsar_camera PROPERTIES
    CUDA_ARCHITECTURES 86
    CUDA_SEPARABLE_COMPILATION OFF
    BUILD_RPATH "${GALAXY_ROOT}/lib;${CUDAToolkit_LIBRARY_DIR}")
  message(STATUS "Pulsar CUDA/NPP pipeline: enabled (${CMAKE_CUDA_COMPILER})")
else()
  target_compile_definitions(pulsar_camera PUBLIC PULSAR_HAS_CUDA=0)
  message(STATUS "Pulsar CUDA/NPP pipeline: disabled; CPU fallback build")
endif()

add_library(pulsar_ui_backend ui/backend/src/HttpServer.cpp)
target_include_directories(pulsar_ui_backend PUBLIC ui/backend/include)
target_link_libraries(pulsar_ui_backend PUBLIC pulsar_core_state pulsar_camera Threads::Threads)

add_executable(pulsar-core core/src/main.cpp)
target_link_libraries(pulsar-core PRIVATE pulsar_ui_backend pulsar_camera pulsar_core_state)
# Keep the bundled Galaxy SDK discoverable both in the build tree and when the
# executable is launched from core/build. Using CMake's RPATH properties avoids
# the previous literal "$$ORIGIN" entry produced by target_link_options.
set_target_properties(pulsar-core PROPERTIES
  BUILD_RPATH "$ORIGIN/../../camera/vendor/galaxy/lib"
  INSTALL_RPATH "$ORIGIN/../../camera/vendor/galaxy/lib")
target_link_options(pulsar-core PRIVATE "LINKER:--disable-new-dtags")
if(PULSAR_CUDA_AVAILABLE)
  set_property(TARGET pulsar-core APPEND PROPERTY BUILD_RPATH "${CUDAToolkit_LIBRARY_DIR}")
  set_property(TARGET pulsar-core APPEND PROPERTY INSTALL_RPATH "${CUDAToolkit_LIBRARY_DIR}")
endif()

foreach(target pulsar_core_state pulsar_camera pulsar_ui_backend pulsar-core)
  target_compile_options(${target} PRIVATE
    $<$<COMPILE_LANGUAGE:CXX>:-Wall;-Wextra;-Wpedantic;-Wconversion;-Wshadow>)
endforeach()

target_compile_options(pulsar-core PRIVATE $<$<AND:$<CONFIG:Release>,$<COMPILE_LANGUAGE:CXX>>:-O3;-DNDEBUG>)
install(TARGETS pulsar-core RUNTIME DESTINATION bin)
