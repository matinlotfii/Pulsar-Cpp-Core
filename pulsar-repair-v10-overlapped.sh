#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$ROOT/.repair-backups/v10-$STAMP"
PATCH_FILE="$(mktemp)"
cleanup() { rm -f "$PATCH_FILE"; }
trap cleanup EXIT

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

for required in \
  run.sh \
  camera/src/CameraDevice.cpp \
  camera/src/SbsRenderer.cpp \
  ui/frontend/src/app/camera-stream.tsx \
  core/scripts/start-session.sh \
  core/scripts/live-runtime-monitor.sh \
  core/scripts/summarize-live-log.py \
  core/config/pulsar.env; do
  [[ -f "$ROOT/$required" ]] || fail "داخل ریشه پروژه V9 نیستی؛ فایل پیدا نشد: $required"
done

command -v patch >/dev/null 2>&1 || fail "دستور patch نصب نیست."
command -v python3 >/dev/null 2>&1 || fail "python3 نصب نیست."
command -v git >/dev/null 2>&1 || fail "git نصب نیست."

mkdir -p "$BACKUP"
for file in \
  run.sh \
  camera/src/CameraDevice.cpp \
  camera/src/SbsRenderer.cpp \
  ui/frontend/src/app/camera-stream.tsx \
  core/scripts/start-session.sh \
  core/scripts/live-runtime-monitor.sh \
  core/scripts/summarize-live-log.py \
  core/config/pulsar.env; do
  mkdir -p "$BACKUP/$(dirname "$file")"
  cp -a "$ROOT/$file" "$BACKUP/$file"
done
printf 'BACKUP=%s\n' "$BACKUP"

cat >"$PATCH_FILE" <<'PATCH_V10'
--- a/camera/src/CameraDevice.cpp
+++ b/camera/src/CameraDevice.cpp
@@ -456,36 +456,276 @@
     return;
   }
 
-  // Low-latency policy: dequeue every frame currently waiting in the SDK,
-  // keep only the newest successful frame, return all SDK buffers immediately,
-  // then process the private raw copy. This prevents a growing backlog.
-  constexpr uint32_t kAcquisitionBufferCount = 4;
-  std::array<PGX_FRAME_BUFFER, kAcquisitionBufferCount> readyBuffers{};
-  std::vector<uint8_t> rawCopy;
-  GX_FRAME_BUFFER copiedFrame{};
-
-  uint64_t processedFrames = 0;
-  uint64_t reportProcessedFrames = 0;
-  uint64_t reportAcquiredFrames = 0;
-  uint64_t reportDroppedStaleFrames = 0;
-
-  double dequeueMsSum = 0.0;
-  double rawCopyMsSum = 0.0;
-  double convertMsSum = 0.0;
-  double publishMsSum = 0.0;
-  double totalMsSum = 0.0;
-  double totalMsMax = 0.0;
-
-  uint64_t reportGpuFrames = 0;
-  double gpuH2dMsSum = 0.0;
-  double gpuDebayerMsSum = 0.0;
-  double gpuResizeMsSum = 0.0;
-  double gpuD2hMsSum = 0.0;
-  double gpuTotalMsSum = 0.0;
-  double gpuTotalMsMax = 0.0;
+  // V10 pipeline: acquisition and processing run independently. The capture
+  // thread copies the newest SDK buffer into a three-slot latest-only ring and
+  // requeues Galaxy buffers immediately. A second thread performs CUDA/NPP and
+  // publish work, so USB acquisition can overlap processing instead of adding
+  // both costs serially to every frame period.
+  enum class SlotState { Free, Writing, Ready, Processing };
+  struct RawSlot {
+    std::vector<uint8_t> bytes;
+    GX_FRAME_BUFFER frame{};
+    FrameTiming timing{};
+    SlotState state = SlotState::Free;
+    uint64_t sequence = 0;
+    double dequeueMs = 0.0;
+    double rawCopyMs = 0.0;
+  };
+
+  constexpr uint32_t kSdkReadyCapacity = 4;
+  constexpr size_t kPipelineSlotCount = 3;
+  std::array<PGX_FRAME_BUFFER, kSdkReadyCapacity> readyBuffers{};
+  std::array<RawSlot, kPipelineSlotCount> slots{};
+  std::mutex pipelineMutex;
+  std::condition_variable pipelineCv;
+  std::atomic<uint64_t> sdkAcquiredFrames{0};
+  std::atomic<uint64_t> sdkStaleDropped{0};
+  std::atomic<uint64_t> queueDropped{0};
+  uint64_t captureSequence = 0;
+
+  const auto durationMs = [](auto duration) {
+    return std::chrono::duration<double, std::milli>(duration).count();
+  };
+
+  std::thread processor([&] {
+    pthread_setname_np(pthread_self(), slot_ == 0 ? "pulsar-gpu-l" : "pulsar-gpu-r");
+    bestEffortRealtime(-4, 15);
+
+    uint64_t processedFrames = 0;
+    uint64_t reportProcessedFrames = 0;
+    uint64_t reportGpuFrames = 0;
+    double dequeueMsSum = 0.0;
+    double rawCopyMsSum = 0.0;
+    double queueWaitMsSum = 0.0;
+    double stageMsSum = 0.0;
+    double processMsSum = 0.0;
+    double publishMsSum = 0.0;
+    double totalMsSum = 0.0;
+    double totalMsMax = 0.0;
+    double gpuH2dMsSum = 0.0;
+    double gpuDebayerMsSum = 0.0;
+    double gpuResizeMsSum = 0.0;
+    double gpuD2hMsSum = 0.0;
+    double gpuTotalMsSum = 0.0;
+    double gpuTotalMsMax = 0.0;
+    auto fpsStart = std::chrono::steady_clock::now();
+    auto reportStart = fpsStart;
+
+    while (true) {
+      size_t selected = slots.size();
+      {
+        std::unique_lock<std::mutex> lock(pipelineMutex);
+        pipelineCv.wait(lock, [&] {
+          if (!running_) return true;
+          for (const auto& slot : slots) {
+            if (slot.state == SlotState::Ready) return true;
+          }
+          return false;
+        });
+
+        uint64_t newestSequence = 0;
+        for (size_t index = 0; index < slots.size(); ++index) {
+          if (slots[index].state == SlotState::Ready &&
+              (selected == slots.size() || slots[index].sequence > newestSequence)) {
+            selected = index;
+            newestSequence = slots[index].sequence;
+          }
+        }
+
+        if (selected == slots.size()) {
+          if (!running_) break;
+          continue;
+        }
+
+        // Drop queued frames older than the newest one. This ring never builds
+        // latency: it trades an obsolete frame for the freshest available one.
+        for (size_t index = 0; index < slots.size(); ++index) {
+          if (index != selected && slots[index].state == SlotState::Ready) {
+            slots[index].state = SlotState::Free;
+            queueDropped.fetch_add(1, std::memory_order_relaxed);
+          }
+        }
+        slots[selected].state = SlotState::Processing;
+      }
 
-  auto fpsStart = std::chrono::steady_clock::now();
-  auto reportStart = fpsStart;
+      RawSlot& job = slots[selected];
+      const auto processingStart = std::chrono::steady_clock::now();
+      const double queueWaitMs = job.timing.hostRawCopyDoneNs == 0
+          ? 0.0
+          : static_cast<double>(steadyNs(processingStart) -
+                                job.timing.hostRawCopyDoneNs) / 1'000'000.0;
+
+      bool published = false;
+      bool gpuFrame = false;
+      GpuBayerTimings gpuTimings{};
+      auto stageEnd = processingStart;
+      auto convertEnd = processingStart;
+      auto publishEnd = processingStart;
+
+      const bool canUseGpu = gpuRequested_ && !gpuDisabledAfterFailure_ &&
+                             gpuPipeline_ != nullptr &&
+                             bayer8(job.frame.nPixelFormat);
+      if (canUseGpu) {
+        std::string gpuError;
+        const bool staged = gpuPipeline_->stageInput(
+            job.bytes.data(), job.bytes.size(), gpuError);
+        stageEnd = std::chrono::steady_clock::now();
+
+        BayerPattern pattern = BayerPattern::Rggb;
+        const uint32_t sourceWidth = static_cast<uint32_t>(job.frame.nWidth);
+        const uint32_t sourceHeight = static_cast<uint32_t>(job.frame.nHeight);
+        const auto [outputWidth, outputHeight] =
+            fitOutputSize(sourceWidth, sourceHeight, maxWidth_, maxHeight_);
+        const uint8_t* gpuOutput = nullptr;
+        std::size_t gpuOutputBytes = 0;
+
+        if (staged &&
+            gpuPatternFor(job.frame.nPixelFormat, colorFilter_, pattern) &&
+            gpuPipeline_->processStaged(
+                sourceWidth, sourceHeight, pattern,
+                outputWidth, outputHeight,
+                gpuOutput, gpuOutputBytes,
+                gpuTimings, gpuError)) {
+          convertEnd = std::chrono::steady_clock::now();
+          job.timing.hostDebayerDoneNs = steadyNs(convertEnd);
+          publish(outputWidth, outputHeight, gpuOutput, gpuOutputBytes,
+                  true, job.timing);
+          publishEnd = std::chrono::steady_clock::now();
+          published = true;
+          gpuFrame = true;
+        } else {
+          gpuDisabledAfterFailure_ = true;
+          std::cerr << label_
+                    << ": GPU pipeline disabled; CPU fallback active: "
+                    << (gpuError.empty() ? "unsupported Bayer pattern" : gpuError)
+                    << '\n';
+        }
+      }
+
+      if (!published) {
+        job.frame.pImgBuf = job.bytes.data();
+        const bool converted = convert(&job.frame, rgb_);
+        convertEnd = std::chrono::steady_clock::now();
+        stageEnd = processingStart;
+        if (converted) {
+          job.timing.hostDebayerDoneNs = steadyNs(convertEnd);
+          publish(static_cast<uint32_t>(job.frame.nWidth),
+                  static_cast<uint32_t>(job.frame.nHeight),
+                  rgb_, true, job.timing);
+          publishEnd = std::chrono::steady_clock::now();
+          published = true;
+        }
+      }
+
+      if (published) {
+        ++processedFrames;
+        ++reportProcessedFrames;
+        if (gpuFrame) {
+          ++reportGpuFrames;
+          gpuH2dMsSum += gpuTimings.hostToDeviceMs;
+          gpuDebayerMsSum += gpuTimings.debayerMs;
+          gpuResizeMsSum += gpuTimings.resizeMs;
+          gpuD2hMsSum += gpuTimings.deviceToHostMs;
+          gpuTotalMsSum += gpuTimings.totalMs;
+          gpuTotalMsMax = std::max(gpuTotalMsMax, gpuTimings.totalMs);
+        }
+
+        const double stageMs = durationMs(stageEnd - processingStart);
+        const double processMs = durationMs(convertEnd - stageEnd);
+        const double publishMs = durationMs(publishEnd - convertEnd);
+        const double totalMs = job.timing.hostDequeueNs == 0
+            ? durationMs(publishEnd - processingStart)
+            : static_cast<double>(steadyNs(publishEnd) -
+                                  job.timing.hostDequeueNs) / 1'000'000.0;
+        dequeueMsSum += job.dequeueMs;
+        rawCopyMsSum += job.rawCopyMs;
+        queueWaitMsSum += queueWaitMs;
+        stageMsSum += stageMs;
+        processMsSum += processMs;
+        publishMsSum += publishMs;
+        totalMsSum += totalMs;
+        totalMsMax = std::max(totalMsMax, totalMs);
+      }
+
+      {
+        std::lock_guard<std::mutex> lock(pipelineMutex);
+        job.state = SlotState::Free;
+      }
+      pipelineCv.notify_one();
+
+      const auto now = std::chrono::steady_clock::now();
+      const std::chrono::duration<double> fpsElapsed = now - fpsStart;
+      if (fpsElapsed.count() >= 1.0) {
+        std::lock_guard<std::mutex> lock(mutex_);
+        status_.fps = static_cast<double>(processedFrames) / fpsElapsed.count();
+        processedFrames = 0;
+        fpsStart = now;
+      }
+
+      const std::chrono::duration<double> reportElapsed = now - reportStart;
+      if (reportElapsed.count() >= 2.0) {
+        const uint64_t acquired =
+            sdkAcquiredFrames.exchange(0, std::memory_order_relaxed);
+        const uint64_t sdkDropped =
+            sdkStaleDropped.exchange(0, std::memory_order_relaxed);
+        const uint64_t pipelineDropped =
+            queueDropped.exchange(0, std::memory_order_relaxed);
+        const double divisor =
+            static_cast<double>(std::max<uint64_t>(1, reportProcessedFrames));
+
+        std::cerr << label_ << ": latency-stats"
+                  << " pipeline="
+                  << (reportGpuFrames == reportProcessedFrames && reportGpuFrames > 0
+                          ? "gpu-overlapped"
+                          : (reportGpuFrames > 0 ? "mixed-overlapped" : "cpu-overlapped"))
+                  << " output-fps="
+                  << (static_cast<double>(reportProcessedFrames) /
+                      reportElapsed.count())
+                  << " acquired-fps="
+                  << (static_cast<double>(acquired) / reportElapsed.count())
+                  << " stale-dropped=" << (sdkDropped + pipelineDropped)
+                  << " sdk-stale-dropped=" << sdkDropped
+                  << " queue-dropped=" << pipelineDropped
+                  << " dequeue-wait-ms=" << (dequeueMsSum / divisor)
+                  << " raw-copy-ms=" << (rawCopyMsSum / divisor)
+                  << " queue-wait-ms=" << (queueWaitMsSum / divisor)
+                  << " stage-ms=" << (stageMsSum / divisor)
+                  << " process-ms=" << (processMsSum / divisor)
+                  << " publish-ms=" << (publishMsSum / divisor)
+                  << " host-pipeline-ms=" << (totalMsSum / divisor)
+                  << " host-pipeline-max-ms=" << totalMsMax;
+
+        if (reportGpuFrames > 0) {
+          const double gpuDivisor = static_cast<double>(reportGpuFrames);
+          std::cerr << " gpu-h2d-ms=" << (gpuH2dMsSum / gpuDivisor)
+                    << " gpu-debayer-ms=" << (gpuDebayerMsSum / gpuDivisor)
+                    << " gpu-resize-ms=" << (gpuResizeMsSum / gpuDivisor)
+                    << " gpu-d2h-ms=" << (gpuD2hMsSum / gpuDivisor)
+                    << " gpu-total-ms=" << (gpuTotalMsSum / gpuDivisor)
+                    << " gpu-total-max-ms=" << gpuTotalMsMax;
+        }
+        std::cerr << '\n';
+
+        reportProcessedFrames = 0;
+        reportGpuFrames = 0;
+        dequeueMsSum = 0.0;
+        rawCopyMsSum = 0.0;
+        queueWaitMsSum = 0.0;
+        stageMsSum = 0.0;
+        processMsSum = 0.0;
+        publishMsSum = 0.0;
+        totalMsSum = 0.0;
+        totalMsMax = 0.0;
+        gpuH2dMsSum = 0.0;
+        gpuDebayerMsSum = 0.0;
+        gpuResizeMsSum = 0.0;
+        gpuD2hMsSum = 0.0;
+        gpuTotalMsSum = 0.0;
+        gpuTotalMsMax = 0.0;
+        reportStart = now;
+      }
+    }
+  });
 
   while (running_) {
     if (device_ == nullptr && !connect()) {
@@ -499,10 +739,9 @@
     readyBuffers.fill(nullptr);
     uint32_t readyCount = 0;
     const auto dequeueStart = std::chrono::steady_clock::now();
-    const GX_STATUS dequeueStatus =
-        GXDQAllBufs(device_, readyBuffers.data(),
-                    static_cast<uint32_t>(readyBuffers.size()),
-                    &readyCount, 1000);
+    const GX_STATUS dequeueStatus = GXDQAllBufs(
+        device_, readyBuffers.data(),
+        static_cast<uint32_t>(readyBuffers.size()), &readyCount, 1000);
     const auto dequeueEnd = std::chrono::steady_clock::now();
 
     if (dequeueStatus != GX_STATUS_SUCCESS || readyCount == 0) {
@@ -514,11 +753,14 @@
       continue;
     }
 
-    reportAcquiredFrames += readyCount;
+    sdkAcquiredFrames.fetch_add(readyCount, std::memory_order_relaxed);
+    if (readyCount > 1) {
+      sdkStaleDropped.fetch_add(readyCount - 1u, std::memory_order_relaxed);
+    }
 
     PGX_FRAME_BUFFER newest = nullptr;
-    for (uint32_t i = readyCount; i > 0; --i) {
-      PGX_FRAME_BUFFER candidate = readyBuffers[i - 1];
+    for (uint32_t index = readyCount; index > 0; --index) {
+      PGX_FRAME_BUFFER candidate = readyBuffers[index - 1u];
       if (candidate != nullptr &&
           candidate->nStatus == GX_FRAME_STATUS_SUCCESS &&
           candidate->pImgBuf != nullptr && candidate->nImgSize > 0) {
@@ -527,210 +769,76 @@
       }
     }
 
-    const uint64_t staleNow = readyCount > 1 ? readyCount - 1u : 0u;
-    reportDroppedStaleFrames += staleNow;
-
-    bool havePrivateFrame = false;
-    bool gpuInputStaged = false;
-    std::string gpuStageError;
-    const auto copyStart = std::chrono::steady_clock::now();
+    size_t selected = slots.size();
     if (newest != nullptr) {
-      copiedFrame = *newest;
-
-      const bool canStageGpu =
-          gpuRequested_ && !gpuDisabledAfterFailure_ &&
-          gpuPipeline_ != nullptr && bayer8(newest->nPixelFormat);
-
-      if (canStageGpu && gpuPipeline_->stageInput(
-                             static_cast<const uint8_t*>(newest->pImgBuf),
-                             static_cast<std::size_t>(newest->nImgSize),
-                             gpuStageError)) {
-        copiedFrame.pImgBuf = nullptr;
-        gpuInputStaged = true;
-        havePrivateFrame = true;
-      } else {
-        if (canStageGpu) {
-          gpuDisabledAfterFailure_ = true;
-          std::cerr << label_
-                    << ": GPU pinned-input staging failed; CPU fallback active: "
-                    << gpuStageError << '\n';
+      std::lock_guard<std::mutex> lock(pipelineMutex);
+      for (size_t index = 0; index < slots.size(); ++index) {
+        if (slots[index].state == SlotState::Free) {
+          selected = index;
+          break;
         }
-
-        rawCopy.resize(static_cast<size_t>(newest->nImgSize));
-        std::memcpy(rawCopy.data(), newest->pImgBuf, rawCopy.size());
-        copiedFrame.pImgBuf = rawCopy.data();
-        havePrivateFrame = true;
+      }
+      if (selected == slots.size()) {
+        uint64_t oldestSequence = UINT64_MAX;
+        for (size_t index = 0; index < slots.size(); ++index) {
+          if (slots[index].state == SlotState::Ready &&
+              slots[index].sequence < oldestSequence) {
+            selected = index;
+            oldestSequence = slots[index].sequence;
+          }
+        }
+        if (selected != slots.size()) {
+          queueDropped.fetch_add(1, std::memory_order_relaxed);
+        }
+      }
+      if (selected != slots.size()) {
+        slots[selected].state = SlotState::Writing;
       }
     }
+
+    const auto copyStart = std::chrono::steady_clock::now();
+    if (newest != nullptr && selected != slots.size()) {
+      RawSlot& slot = slots[selected];
+      slot.bytes.resize(static_cast<size_t>(newest->nImgSize));
+      std::memcpy(slot.bytes.data(), newest->pImgBuf, slot.bytes.size());
+      slot.frame = *newest;
+      slot.frame.pImgBuf = slot.bytes.data();
+      slot.timing = {};
+      slot.timing.cameraFrameId = newest->nFrameID;
+      slot.timing.cameraTimestamp = newest->nTimestamp;
+      slot.timing.hostDequeueNs = steadyNs(dequeueEnd);
+    } else if (newest != nullptr) {
+      queueDropped.fetch_add(1, std::memory_order_relaxed);
+    }
     const auto copyEnd = std::chrono::steady_clock::now();
 
-    // Return all Galaxy SDK buffers before CPU debayer/resize starts so the
-    // camera can continue acquiring into its fixed buffer pool.
     if (GXQAllBufs(device_) != GX_STATUS_SUCCESS) {
+      if (selected != slots.size()) {
+        std::lock_guard<std::mutex> lock(pipelineMutex);
+        slots[selected].state = SlotState::Free;
+      }
       fail("camera buffer requeue failed; reconnecting");
       close();
       std::this_thread::sleep_for(std::chrono::milliseconds(250));
       continue;
     }
 
-    bool published = false;
-    GpuBayerTimings gpuTimings{};
-    auto convertEnd = copyEnd;
-    auto publishEnd = copyEnd;
-    if (havePrivateFrame) {
-      FrameTiming timing{};
-      timing.cameraFrameId = copiedFrame.nFrameID;
-      timing.cameraTimestamp = copiedFrame.nTimestamp;
-      timing.hostDequeueNs = steadyNs(dequeueEnd);
-      timing.hostRawCopyDoneNs = steadyNs(copyEnd);
-
-      if (gpuRequested_ && !gpuDisabledAfterFailure_ && gpuPipeline_ != nullptr &&
-          bayer8(copiedFrame.nPixelFormat)) {
-        BayerPattern pattern = BayerPattern::Rggb;
-        const uint32_t sourceWidth = static_cast<uint32_t>(copiedFrame.nWidth);
-        const uint32_t sourceHeight = static_cast<uint32_t>(copiedFrame.nHeight);
-        const auto [outputWidth, outputHeight] =
-            fitOutputSize(sourceWidth, sourceHeight, maxWidth_, maxHeight_);
-        std::string gpuError;
-        const uint8_t* gpuOutput = nullptr;
-        std::size_t gpuOutputBytes = 0;
-
-        if (gpuInputStaged &&
-            gpuPatternFor(copiedFrame.nPixelFormat, colorFilter_, pattern) &&
-            gpuPipeline_->processStaged(
-                sourceWidth,
-                sourceHeight,
-                pattern,
-                outputWidth,
-                outputHeight,
-                gpuOutput,
-                gpuOutputBytes,
-                gpuTimings,
-                gpuError)) {
-          convertEnd = std::chrono::steady_clock::now();
-          timing.hostDebayerDoneNs = steadyNs(convertEnd);
-          publish(
-              outputWidth,
-              outputHeight,
-              gpuOutput,
-              gpuOutputBytes,
-              true,
-              timing);
-          publishEnd = std::chrono::steady_clock::now();
-          published = true;
-          ++reportGpuFrames;
-          gpuH2dMsSum += gpuTimings.hostToDeviceMs;
-          gpuDebayerMsSum += gpuTimings.debayerMs;
-          gpuResizeMsSum += gpuTimings.resizeMs;
-          gpuD2hMsSum += gpuTimings.deviceToHostMs;
-          gpuTotalMsSum += gpuTimings.totalMs;
-          gpuTotalMsMax = std::max(gpuTotalMsMax, gpuTimings.totalMs);
-        } else {
-          gpuDisabledAfterFailure_ = true;
-          std::cerr << label_ << ": GPU pipeline disabled; CPU fallback active: "
-                    << (gpuError.empty() ? "unsupported Bayer pattern" : gpuError)
-                    << '\n';
-        }
-      }
-
-      // A staged GPU frame no longer owns a CPU raw copy. If GPU processing
-      // fails, drop this one frame; the next iteration uses CPU fallback after
-      // gpuDisabledAfterFailure_ has been set.
-      if (!published && !gpuInputStaged) {
-        const bool converted = convert(&copiedFrame, rgb_);
-        convertEnd = std::chrono::steady_clock::now();
-        if (converted) {
-          timing.hostDebayerDoneNs = steadyNs(convertEnd);
-          publish(static_cast<uint32_t>(copiedFrame.nWidth),
-                  static_cast<uint32_t>(copiedFrame.nHeight), rgb_, true, timing);
-          publishEnd = std::chrono::steady_clock::now();
-          published = true;
-        }
-      }
-
-      if (published) {
-        ++processedFrames;
-        ++reportProcessedFrames;
+    if (selected != slots.size()) {
+      RawSlot& slot = slots[selected];
+      slot.timing.hostRawCopyDoneNs = steadyNs(copyEnd);
+      slot.dequeueMs = durationMs(dequeueEnd - dequeueStart);
+      slot.rawCopyMs = durationMs(copyEnd - copyStart);
+      {
+        std::lock_guard<std::mutex> lock(pipelineMutex);
+        slot.sequence = ++captureSequence;
+        slot.state = SlotState::Ready;
       }
-    }
-
-    const auto now = std::chrono::steady_clock::now();
-    const auto ms = [](auto duration) {
-      return std::chrono::duration<double, std::milli>(duration).count();
-    };
-
-    if (published) {
-      const double dequeueMs = ms(dequeueEnd - dequeueStart);
-      const double copyMs = ms(copyEnd - copyStart);
-      const double convertMs = ms(convertEnd - copyEnd);
-      const double publishMs = ms(publishEnd - convertEnd);
-      const double totalMs = ms(publishEnd - dequeueEnd);
-      dequeueMsSum += dequeueMs;
-      rawCopyMsSum += copyMs;
-      convertMsSum += convertMs;
-      publishMsSum += publishMs;
-      totalMsSum += totalMs;
-      totalMsMax = std::max(totalMsMax, totalMs);
-    }
-
-    const std::chrono::duration<double> fpsElapsed = now - fpsStart;
-    if (fpsElapsed.count() >= 1.0) {
-      std::lock_guard<std::mutex> lock(mutex_);
-      status_.fps = static_cast<double>(processedFrames) / fpsElapsed.count();
-      processedFrames = 0;
-      fpsStart = now;
-    }
-
-    const std::chrono::duration<double> reportElapsed = now - reportStart;
-    if (reportElapsed.count() >= 2.0) {
-      const double divisor = static_cast<double>(std::max<uint64_t>(1, reportProcessedFrames));
-      std::cerr << label_ << ": latency-stats"
-                << " pipeline="
-                << (reportGpuFrames == reportProcessedFrames && reportGpuFrames > 0
-                        ? "gpu"
-                        : (reportGpuFrames > 0 ? "mixed" : "cpu"))
-                << " output-fps="
-                << (static_cast<double>(reportProcessedFrames) / reportElapsed.count())
-                << " acquired-fps="
-                << (static_cast<double>(reportAcquiredFrames) / reportElapsed.count())
-                << " stale-dropped=" << reportDroppedStaleFrames
-                << " dequeue-wait-ms=" << (dequeueMsSum / divisor)
-                << " raw-copy-ms=" << (rawCopyMsSum / divisor)
-                << " process-ms=" << (convertMsSum / divisor)
-                << " publish-ms=" << (publishMsSum / divisor)
-                << " host-pipeline-ms=" << (totalMsSum / divisor)
-                << " host-pipeline-max-ms=" << totalMsMax;
-
-      if (reportGpuFrames > 0) {
-        const double gpuDivisor = static_cast<double>(reportGpuFrames);
-        std::cerr << " gpu-h2d-ms=" << (gpuH2dMsSum / gpuDivisor)
-                  << " gpu-debayer-ms=" << (gpuDebayerMsSum / gpuDivisor)
-                  << " gpu-resize-ms=" << (gpuResizeMsSum / gpuDivisor)
-                  << " gpu-d2h-ms=" << (gpuD2hMsSum / gpuDivisor)
-                  << " gpu-total-ms=" << (gpuTotalMsSum / gpuDivisor)
-                  << " gpu-total-max-ms=" << gpuTotalMsMax;
-      }
-      std::cerr << '\n';
-
-      reportProcessedFrames = 0;
-      reportAcquiredFrames = 0;
-      reportDroppedStaleFrames = 0;
-      dequeueMsSum = 0.0;
-      rawCopyMsSum = 0.0;
-      convertMsSum = 0.0;
-      publishMsSum = 0.0;
-      totalMsSum = 0.0;
-      totalMsMax = 0.0;
-      reportGpuFrames = 0;
-      gpuH2dMsSum = 0.0;
-      gpuDebayerMsSum = 0.0;
-      gpuResizeMsSum = 0.0;
-      gpuD2hMsSum = 0.0;
-      gpuTotalMsSum = 0.0;
-      gpuTotalMsMax = 0.0;
-      reportStart = now;
+      pipelineCv.notify_one();
     }
   }
+
+  pipelineCv.notify_all();
+  if (processor.joinable()) processor.join();
 }
 
 void CameraDevice::mockLoop() {
--- a/camera/src/SbsRenderer.cpp
+++ b/camera/src/SbsRenderer.cpp
@@ -653,10 +653,15 @@
   elevateRendererPriority();
   const bool pboRequested = envEnabled("PULSAR_GL_PBO_UPLOAD");
   const StereoPairingMode pairingMode = stereoPairingModeFromEnvironment();
-  std::cerr << "SBS Renderer: multi-output-latest-only=1 vsync=" << (envEnabled("PULSAR_SBS_PRESENT_VSYNC", false) ? "on" : "off") << '\n';
+  std::cerr << "SBS Renderer: multi-output-latest-only=1 nvidia-offload="
+            << (envEnabled("PULSAR_CORE_NVIDIA_OFFLOAD", false) ? "on" : "off")
+            << " vsync=" << (envEnabled("PULSAR_SBS_PRESENT_VSYNC", false) ? "on" : "off") << '\n';
   std::cerr << "SBS Renderer: stereo-pairing-mode="
             << stereoPairingModeName(pairingMode) << '\n';
-  SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, "1");
+  const std::string scaleQuality = envString("PULSAR_RENDER_SCALE_QUALITY", "1");
+  SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, scaleQuality.c_str());
+  SDL_SetHint("SDL_RENDER_BATCHING", "1");
+  SDL_SetHint("SDL_VIDEO_X11_NET_WM_BYPASS_COMPOSITOR", "1");
   if (pboRequested) SDL_SetHint(SDL_HINT_RENDER_DRIVER, "opengl");
   if (SDL_InitSubSystem(SDL_INIT_VIDEO) != 0) {
     std::cerr << "SDL video init failed: " << SDL_GetError() << '\n';
--- a/ui/frontend/src/app/camera-stream.tsx
+++ b/ui/frontend/src/app/camera-stream.tsx
@@ -98,7 +98,7 @@
     let controller: AbortController | null = null;
     let context: CanvasRenderingContext2D | null = null;
     let pendingBitmap: PendingBitmap | null = null;
-    let drawRequest = 0;
+    let drawScheduled = false;
     let localDropped = 0;
     let status: CameraStreamStatus = "connecting";
     let frameVisible = false;
@@ -117,7 +117,7 @@
     };
 
     const drawLatest = () => {
-      drawRequest = 0;
+      drawScheduled = false;
       const frame = pendingBitmap;
       pendingBitmap = null;
       if (!frame || stopped) {
@@ -166,8 +166,9 @@
       });
       localDropped = 0;
 
-      if (pendingBitmap && drawRequest === 0) {
-        drawRequest = window.requestAnimationFrame(drawLatest);
+      if (pendingBitmap && !drawScheduled) {
+        drawScheduled = true;
+        queueMicrotask(drawLatest);
       }
     };
 
@@ -185,7 +186,10 @@
         localDropped += 1;
       }
       pendingBitmap = event.data;
-      if (drawRequest === 0) drawRequest = window.requestAnimationFrame(drawLatest);
+      if (!drawScheduled) {
+        drawScheduled = true;
+        queueMicrotask(drawLatest);
+      }
     };
 
     worker.onerror = () => updateStatus("offline");
@@ -235,7 +239,6 @@
       stopped = true;
       controller?.abort();
       worker.terminate();
-      if (drawRequest !== 0) window.cancelAnimationFrame(drawRequest);
       pendingBitmap?.bitmap.close();
     };
   }, [cameraIndex]);
--- a/core/scripts/start-session.sh
+++ b/core/scripts/start-session.sh
@@ -336,17 +336,27 @@
 )
 
 if [[ "${PULSAR_CORE_NVIDIA_OFFLOAD:-0}" == "1" ]]; then
-  core_command=(
-    env
-    __NV_PRIME_RENDER_OFFLOAD=1
-    __NV_PRIME_RENDER_OFFLOAD_PROVIDER="${PULSAR_CORE_NVIDIA_PROVIDER:-NVIDIA-G0}"
-    __GLX_VENDOR_LIBRARY_NAME=nvidia
-    "${core_command[@]}"
-  )
-
-  printf '%s\n'     "Pulsar core NVIDIA PRIME offload enabled: ${PULSAR_CORE_NVIDIA_PROVIDER:-NVIDIA-G0}"     >>"$PULSAR_LOG_FILE"
+  requested_provider="${PULSAR_CORE_NVIDIA_PROVIDER:-NVIDIA-G0}"
+  detected_provider="$(xrandr --listproviders 2>/dev/null | sed -n 's/.*name:\(.*NVIDIA[^ ]*\).*/\1/p' | head -n1 || true)"
+  selected_provider="$requested_provider"
+  if ! xrandr --listproviders 2>/dev/null | grep -Fq "name:${selected_provider}"; then
+    selected_provider="$detected_provider"
+  fi
+  if [[ -n "$selected_provider" ]]; then
+    core_command=(
+      env
+      __NV_PRIME_RENDER_OFFLOAD=1
+      __NV_PRIME_RENDER_OFFLOAD_PROVIDER="$selected_provider"
+      __GLX_VENDOR_LIBRARY_NAME=nvidia
+      __GL_SYNC_TO_VBLANK=0
+      __GL_MaxFramesAllowed=1
+      "${core_command[@]}"
+    )
+    printf '%s\n' "Pulsar core NVIDIA PRIME offload enabled: $selected_provider" >>"$PULSAR_LOG_FILE"
+  else
+    printf '%s\n' "Pulsar core NVIDIA PRIME offload requested but no NVIDIA provider was found; using default GL provider." >>"$PULSAR_LOG_FILE"
+  fi
 fi
-
 nohup "${core_command[@]}" >>"$PULSAR_LOG_FILE" 2>&1 &
 core_pid=$!
 echo "$core_pid" >"$PULSAR_PID_FILE"
@@ -378,7 +388,11 @@
   --enable-features=UseOzonePlatform --ozone-platform=x11 --use-gl=angle --use-angle=gl
   --touch-events=enabled
 )
-[[ "${PULSAR_BROWSER_GPU:-1}" == "1" ]] && browser_flags+=(--enable-gpu-rasterization --enable-zero-copy)
+if [[ "${PULSAR_BROWSER_SOFTWARE_COMPOSITOR:-0}" == "1" ]]; then
+  browser_flags+=(--disable-gpu --disable-gpu-compositing)
+elif [[ "${PULSAR_BROWSER_GPU:-1}" == "1" ]]; then
+  browser_flags+=(--enable-gpu-rasterization --enable-zero-copy --enable-accelerated-2d-canvas --ignore-gpu-blocklist)
+fi
 [[ $EUID -eq 0 ]] && browser_flags+=(--no-sandbox)
 
 if [[ "${PULSAR_HIDE_CURSOR:-1}" == "1" ]] && [[ -x "$PULSAR_ROOT/core/scripts/hide-cursor.sh" ]]; then
--- a/core/scripts/live-runtime-monitor.sh
+++ b/core/scripts/live-runtime-monitor.sh
@@ -31,7 +31,7 @@
   sed "s/^/[${prefix}] /" "$file"
 }
 
-printf '[TRACE] version=observable-realtime-v9 start=%s duration-sec=%s interval-sec=%s host=%s\n' \
+printf '[TRACE] version=overlapped-realtime-v10 start=%s duration-sec=%s interval-sec=%s host=%s\n' \
   "$(date --iso-8601=seconds)" "$DURATION" "$SAMPLE_INTERVAL" "$(hostname)"
 printf '[TRACE] service-active=%s service-enabled=%s\n' \
   "$(systemctl is-active "$SERVICE" 2>/dev/null || true)" \
@@ -50,6 +50,12 @@
   pstree -ap "$main_pid" 2>/dev/null | sed 's/^/[PROCESS] /' || true
 fi
 printf '[PROCESS_TREE_END]\n'
+printf '[GRAPHICS_BEGIN]\n'
+DISPLAY="${DISPLAY:-:0}" xrandr --listproviders 2>&1 | sed 's/^/[XRANDR_PROVIDER] /' || true
+if command -v glxinfo >/dev/null 2>&1; then
+  DISPLAY="${DISPLAY:-:0}" glxinfo -B 2>&1 | sed 's/^/[GLX] /' || true
+fi
+printf '[GRAPHICS_END]\n'
 
 printf '[DISPLAY_PROBE_BEGIN]\n'
 DISPLAY="${DISPLAY:-:0}" "$PULSAR_ROOT/core/scripts/verify-viewer-panels.py" 2>&1 | sed 's/^/[DISPLAY_PROBE] /' || true
@@ -88,8 +94,11 @@
   timestamp="$(date --iso-8601=seconds)"
   core_pid="$(pgrep -n -x pulsar-core 2>/dev/null || true)"
   core_stats="missing"
+  thread_stats="missing"
   if [[ "$core_pid" =~ ^[0-9]+$ ]]; then
     core_stats="$(ps -p "$core_pid" -o pid=,psr=,ni=,pri=,pcpu=,pmem=,nlwp=,stat=,etime= 2>/dev/null | xargs || true)"
+    thread_stats="$(ps -L -p "$core_pid" -o tid=,psr=,pcpu=,stat=,comm= --sort=-pcpu 2>/dev/null | head -n 10 | tr '
+' ';' | sed 's/[[:space:]]\+/ /g' || true)"
   fi
 
   xorg_cpu="$(pgrep -n -x Xorg 2>/dev/null | xargs -r ps -o pcpu= -p 2>/dev/null | xargs || true)"
@@ -112,8 +121,8 @@
   loadavg="$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || true)"
   memory="$(awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{if(t>0)printf "%.1f",100*(t-a)/t}' /proc/meminfo 2>/dev/null || true)"
 
-  printf '[SYSTEM] ts=%s core="%s" xorg-cpu=%s chrome-root-cpu=%s chrome-gpu-cpu=%s chrome-renderer-cpu=%s gpu="%s" api="%s" outputs="%s" load="%s" memory-used-pct=%s\n' \
-    "$timestamp" "$core_stats" "${xorg_cpu:-0}" "$chrome_root_cpu" "$chrome_gpu_cpu" \
+  printf '[SYSTEM] ts=%s core="%s" threads="%s" xorg-cpu=%s chrome-root-cpu=%s chrome-gpu-cpu=%s chrome-renderer-cpu=%s gpu="%s" api="%s" outputs="%s" load="%s" memory-used-pct=%s\n' \
+    "$timestamp" "$core_stats" "$thread_stats" "${xorg_cpu:-0}" "$chrome_root_cpu" "$chrome_gpu_cpu" \
     "$chrome_renderer_cpu" "$gpu" "$api" "$outputs" "$loadavg" "${memory:-0}"
   sleep "$SAMPLE_INTERVAL"
 done
--- a/core/scripts/summarize-live-log.py
+++ b/core/scripts/summarize-live-log.py
@@ -35,6 +35,8 @@
         "acquired_fps": "acquired-fps",
         "dequeue_ms": "dequeue-wait-ms",
         "raw_ms": "raw-copy-ms",
+        "queue_ms": "queue-wait-ms",
+        "stage_ms": "stage-ms",
         "process_ms": "process-ms",
         "publish_ms": "publish-ms",
         "host_ms": "host-pipeline-ms",
@@ -70,8 +72,9 @@
         "loop_fps": "loop-fps", "left_age_ms": "left-host-age-ms",
         "right_age_ms": "right-host-age-ms", "skew_ms": "stereo-host-skew-ms",
         "upload_ms": "texture-upload-ms", "prepare_ms": "prepare-ms",
-        "render_ms": "render-ms", "present_ms": "present-ms",
-        "loop_total_ms": "loop-total-ms", "panels": "panels",
+        "render_ms": "render-ms", "render_max_ms": "render-max-ms",
+        "present_ms": "present-ms", "loop_total_ms": "loop-total-ms",
+        "loop_max_ms": "loop-total-max-ms", "panels": "panels",
     }
     renderer = {
         key: median(metric(text, "SBS Renderer: latency-stats", token))
@@ -125,8 +128,12 @@
         bottlenecks.append(("CAMERA_ACQUISITION",
                             f"Camera output is {min(fps_values):.2f} FPS; frames are not arriving fast enough."))
     for side, item in (("left", left), ("right", right)):
-        if item["raw_ms"] is not None and item["raw_ms"] > 3.0:
-            bottlenecks.append(("RAW_COPY", f"{side} raw staging copy={item['raw_ms']:.2f} ms"))
+        if item["raw_ms"] is not None and item["raw_ms"] > 12.0:
+            warnings.append(("RAW_COPY", f"{side} SDK copy={item['raw_ms']:.2f} ms; overlapped acquisition can tolerate it while queue wait stays low."))
+        if item["queue_ms"] is not None and item["queue_ms"] > 8.0:
+            bottlenecks.append(("CAMERA_QUEUE", f"{side} processing queue wait={item['queue_ms']:.2f} ms"))
+        if item["stage_ms"] is not None and item["stage_ms"] > 4.0:
+            bottlenecks.append(("PINNED_STAGE", f"{side} pageable-to-pinned stage={item['stage_ms']:.2f} ms"))
         if item["h2d_ms"] is not None and item["h2d_ms"] > 3.0:
             bottlenecks.append(("CUDA_H2D", f"{side} host-to-device={item['h2d_ms']:.2f} ms"))
         if item["process_ms"] is not None and item["process_ms"] > 5.0:
@@ -143,6 +150,8 @@
         bottlenecks.append(("TEXTURE_UPLOAD", f"Texture upload={renderer['upload_ms']:.2f} ms"))
     if renderer["render_ms"] is not None and renderer["render_ms"] > 10.0:
         bottlenecks.append(("RENDER_COPY", f"Panel rendering={renderer['render_ms']:.2f} ms"))
+    if renderer["render_max_ms"] is not None and renderer["render_max_ms"] > 80.0:
+        bottlenecks.append(("RENDER_STALL", f"Renderer maximum stall={renderer['render_max_ms']:.2f} ms"))
     if renderer["present_ms"] is not None and renderer["present_ms"] > 4.0:
         bottlenecks.append(("DISPLAY_PRESENT", f"Present={renderer['present_ms']:.2f} ms"))
 
@@ -171,13 +180,14 @@
     for name, reason in warnings:
         unique_warnings.setdefault(name, reason)
 
-    print("PULSAR OBSERVABLE REALTIME V9 — AUTOMATIC SUMMARY")
+    print("PULSAR OVERLAPPED REALTIME V10 — AUTOMATIC SUMMARY")
     print("=================================================")
     print(f"SOURCE_LOG={path.resolve()}")
     print()
     for label, item in (("LEFT_CAMERA", left), ("RIGHT_CAMERA", right)):
         print(f"{label}: output={fmt(item['output_fps'],' fps')} acquired={fmt(item['acquired_fps'],' fps')} "
               f"dequeue={fmt(item['dequeue_ms'],' ms')} raw={fmt(item['raw_ms'],' ms')} "
+              f"queue={fmt(item['queue_ms'],' ms')} stage={fmt(item['stage_ms'],' ms')} "
               f"process={fmt(item['process_ms'],' ms')} publish={fmt(item['publish_ms'],' ms')} "
               f"H2D={fmt(item['h2d_ms'],' ms')} debayer={fmt(item['debayer_ms'],' ms')} "
               f"resize={fmt(item['resize_ms'],' ms')} D2H={fmt(item['d2h_ms'],' ms')}")
--- a/run.sh
+++ b/run.sh
@@ -50,7 +50,7 @@
 RUN_GIT_BACKUP_DIR="${RUN_GIT_BACKUP_DIR:-$HOME/Downloads/Pulsar-Git-Backups}"
 RUN_GIT_TAG_PREFIX="${RUN_GIT_TAG_PREFIX:-pulsar-run}"
 RUN_GIT_MAX_FILE_MB="${RUN_GIT_MAX_FILE_MB:-95}"
-RUN_GIT_COMMIT_MESSAGE="${RUN_GIT_COMMIT_MESSAGE:-Pulsar observable realtime UI motion and multi-output viewer V9}"
+RUN_GIT_COMMIT_MESSAGE="${RUN_GIT_COMMIT_MESSAGE:-Pulsar overlapped camera pipeline and isolated realtime display V10}"
 RUN_GIT_PROMPT="${RUN_GIT_PROMPT:-0}"
 RUN_REQUIRE_CUDA="${RUN_REQUIRE_CUDA:-1}"
 # Destructive clean-replace deployment: stop the old kiosk/UI, remove the old
@@ -496,15 +496,27 @@
     remote_preflight
     checkpoint_and_push
     purge_remote_previous_deployment
+    deploy_status=0
+    set +e
     deploy_remote
-    stream_remote_runtime
-    collect_remote_diagnostics
+    deploy_status=$?
+    set -e
+
+    # Always collect a bounded trace when the remote host is reachable. This
+    # preserves exact failure evidence instead of stopping before logs return.
+    stream_remote_runtime || true
+    collect_remote_diagnostics || true
     echo
     echo "========== LOCAL DIAGNOSTICS READY =========="
-    echo "Deploy log:  $RUN_LOCAL_DIR/deploy.log"
-    echo "Live log:    $RUN_LOCAL_DIR/runtime-live.log"
-    echo "Summary:     $RUN_LOCAL_DIR/SUMMARY.txt"
-    echo "Latest link: $RUN_LOCAL_LOG_ROOT/latest"
+    echo "Deploy status: $deploy_status"
+    echo "Deploy log:    $RUN_LOCAL_DIR/deploy.log"
+    echo "Live log:      $RUN_LOCAL_DIR/runtime-live.log"
+    echo "Summary:       $RUN_LOCAL_DIR/SUMMARY.txt"
+    echo "Latest link:   $RUN_LOCAL_LOG_ROOT/latest"
+    if ((deploy_status != 0)); then
+      echo "Deployment failed, but diagnostic collection was retained." >&2
+      exit "$deploy_status"
+    fi
     ;;
   setup-remote)
     setup_remote_sudo
PATCH_V10

if grep -q 'V10 pipeline: acquisition and processing run independently' \
    "$ROOT/camera/src/CameraDevice.cpp"; then
  echo 'CODE_PATCH=ALREADY_APPLIED'
else
  if ! patch --batch --forward -p1 -d "$ROOT" <"$PATCH_FILE"; then
    echo 'Patch failed; restoring source backup.' >&2
    cp -a "$BACKUP/." "$ROOT/"
    exit 1
  fi
  echo 'CODE_PATCH=PASS'
fi

python3 - "$ROOT/core/config/pulsar.env" <<'PY_CONFIG'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding='utf-8')

values = {
    'PULSAR_CAMERA_FPS': '32',
    'PULSAR_CAMERA_EXPOSURE_US': '30000',
    'PULSAR_CAMERA_HARDWARE_ROI': '0',
    'PULSAR_CAMERA_ROI_REQUIRED': '0',
    'PULSAR_CAMERA_LINK_THROUGHPUT_BPS': '400000000',
    'PULSAR_STREAM_TRANSFER_SIZE': '1048576',
    'PULSAR_STREAM_TRANSFER_URB': '32',
    'PULSAR_ACQUISITION_BUFFER_COUNT': '2',
    'PULSAR_GPU_PIPELINE': 'both',
    'PULSAR_GPU_DIRECT_SDK_H2D': '0',
    'PULSAR_GL_PBO_UPLOAD': '1',
    'PULSAR_SBS_PRESENT_VSYNC': '0',
    'PULSAR_STEREO_PAIRING_MODE': 'latest',
    'PULSAR_CORE_NVIDIA_OFFLOAD': '1',
    'PULSAR_CORE_NVIDIA_PROVIDER': 'NVIDIA-G0',
    'PULSAR_RENDER_SCALE_QUALITY': '1',
    'PULSAR_PREVIEW_FPS': '6',
    'PULSAR_PREVIEW_MAX_WIDTH': '384',
    'PULSAR_PREVIEW_MAX_HEIGHT': '216',
    'PULSAR_JPEG_QUALITY': '38',
    'PULSAR_BROWSER_GPU': '1',
    'PULSAR_BROWSER_SOFTWARE_COMPOSITOR': '0',
    'PULSAR_LIVE_TRACE_SECONDS': '90',
    'PULSAR_SYSTEM_TRACE_SECONDS': '30',
    'PULSAR_LIVE_SAMPLE_INTERVAL': '1',
}

lines = text.splitlines()
seen = set()
out = []
for line in lines:
    if '=' in line and not line.lstrip().startswith('#'):
        key = line.split('=', 1)[0]
        if key in values:
            if key not in seen:
                out.append(f'{key}={values[key]}')
                seen.add(key)
            continue
    out.append(line)

if out and out[-1].strip():
    out.append('')
out.append('# V10 overlapped camera pipeline, isolated NVIDIA viewer and bounded local telemetry')
for key, value in values.items():
    if key not in seen:
        out.append(f'{key}={value}')

path.write_text('\n'.join(out) + '\n', encoding='utf-8')
print('CONFIG_PATCH=PASS')
PY_CONFIG

chmod +x \
  "$ROOT/run.sh" \
  "$ROOT/core/scripts/start-session.sh" \
  "$ROOT/core/scripts/live-runtime-monitor.sh" \
  "$ROOT/core/scripts/summarize-live-log.py"

bash -n "$ROOT/run.sh"
bash -n "$ROOT/core/scripts/start-session.sh"
bash -n "$ROOT/core/scripts/live-runtime-monitor.sh"
python3 -m py_compile "$ROOT/core/scripts/summarize-live-log.py"

grep -q 'gpu-overlapped' "$ROOT/camera/src/CameraDevice.cpp" || fail 'Camera pipeline patch marker missing.'
grep -q 'queueMicrotask(drawLatest)' "$ROOT/ui/frontend/src/app/camera-stream.tsx" || fail 'UI immediate-draw patch marker missing.'
grep -q 'Pulsar core NVIDIA PRIME offload enabled' "$ROOT/core/scripts/start-session.sh" || fail 'NVIDIA offload patch marker missing.'
grep -q 'Deployment failed, but diagnostic collection was retained' "$ROOT/run.sh" || fail 'Run logging patch marker missing.'

echo
echo '========== V10 ACTIVE CONFIG =========='
grep -nE '^PULSAR_(CAMERA_FPS|CAMERA_EXPOSURE_US|CAMERA_HARDWARE_ROI|CAMERA_LINK_THROUGHPUT_BPS|STREAM_TRANSFER_SIZE|STREAM_TRANSFER_URB|ACQUISITION_BUFFER_COUNT|GPU_PIPELINE|GPU_DIRECT_SDK_H2D|GL_PBO_UPLOAD|SBS_PRESENT_VSYNC|STEREO_PAIRING_MODE|CORE_NVIDIA_OFFLOAD|CORE_NVIDIA_PROVIDER|PREVIEW_FPS|PREVIEW_MAX_WIDTH|PREVIEW_MAX_HEIGHT|JPEG_QUALITY|LIVE_TRACE_SECONDS)=' \
  "$ROOT/core/config/pulsar.env"

echo
echo '========== SOURCE VALIDATION =========='
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -C "$ROOT" diff --check || fail 'git diff --check failed.'
else
  if grep -RInE '^(<<<<<<<|=======|>>>>>>>)' \
      "$ROOT/camera/src/CameraDevice.cpp" \
      "$ROOT/camera/src/SbsRenderer.cpp" \
      "$ROOT/ui/frontend/src/app/camera-stream.tsx" \
      "$ROOT/core/scripts" "$ROOT/run.sh"; then
    fail 'Conflict markers found.'
  fi
fi
echo 'SOURCE_VALIDATION=PASS'

if [[ "${PULSAR_REPAIR_SKIP_RUN:-0}" == "1" ]]; then
  echo 'PATCH_ONLY=PASS'
  echo "BACKUP=$BACKUP"
  exit 0
fi

echo
echo '========== CLEAN REMOTE DEPLOY + 90 SECOND TRACE =========='
set +e
RUN_LIVE_TRACE_SECONDS=90 "$ROOT/run.sh"
STATUS=$?
set -e

echo
echo '========== LOCAL RESULT =========='
echo "RUN_STATUS=$STATUS"
echo "BACKUP=$BACKUP"
echo "LATEST_DIAGNOSTICS=$ROOT/diagnostics/live/latest"
if [[ -f "$ROOT/diagnostics/live/latest/SUMMARY.txt" ]]; then
  cat "$ROOT/diagnostics/live/latest/SUMMARY.txt"
else
  echo 'SUMMARY_NOT_CREATED=1'
fi

exit "$STATUS"
