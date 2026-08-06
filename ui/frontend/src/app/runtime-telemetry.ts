type PreviewAccumulator = {
  samples: number;
  requestMs: number;
  sourceAgeMs: number;
  decodeMs: number;
  drawMs: number;
  bytes: number;
  dropped: number;
};

type RuntimeAccumulator = {
  stateApiSamples: number;
  stateApiMs: number;
  rafFrames: number;
  rafMisses: number;
  rafGapMaxMs: number;
  longTasks: number;
  longTaskMs: number;
  preview: [PreviewAccumulator, PreviewAccumulator];
};

const makePreview = (): PreviewAccumulator => ({
  samples: 0,
  requestMs: 0,
  sourceAgeMs: 0,
  decodeMs: 0,
  drawMs: 0,
  bytes: 0,
  dropped: 0
});

let accumulator: RuntimeAccumulator = {
  stateApiSamples: 0,
  stateApiMs: 0,
  rafFrames: 0,
  rafMisses: 0,
  rafGapMaxMs: 0,
  longTasks: 0,
  longTaskMs: 0,
  preview: [makePreview(), makePreview()]
};

let started = false;
let flushTimer = 0;
let rafHandle = 0;
let lastRaf = 0;
let windowStartedAt = performance.now();

function average(total: number, count: number) {
  return count > 0 ? total / count : 0;
}

function resetAccumulator() {
  accumulator = {
    stateApiSamples: 0,
    stateApiMs: 0,
    rafFrames: 0,
    rafMisses: 0,
    rafGapMaxMs: 0,
    longTasks: 0,
    longTaskMs: 0,
    preview: [makePreview(), makePreview()]
  };
  windowStartedAt = performance.now();
}

function flushRuntimeTelemetry() {
  const elapsedMs = Math.max(1, performance.now() - windowStartedAt);
  const left = accumulator.preview[0];
  const right = accumulator.preview[1];
  const payload = {
    windowMs: elapsedMs,
    rafFps: accumulator.rafFrames * 1000 / elapsedMs,
    rafMisses: accumulator.rafMisses,
    rafGapMaxMs: accumulator.rafGapMaxMs,
    longTasks: accumulator.longTasks,
    longTaskMs: accumulator.longTaskMs,
    stateApiMs: average(accumulator.stateApiMs, accumulator.stateApiSamples),
    stateApiSamples: accumulator.stateApiSamples,
    leftSamples: left.samples,
    leftRequestMs: average(left.requestMs, left.samples),
    leftSourceAgeMs: average(left.sourceAgeMs, left.samples),
    leftDecodeMs: average(left.decodeMs, left.samples),
    leftDrawMs: average(left.drawMs, left.samples),
    leftBytes: average(left.bytes, left.samples),
    leftDropped: left.dropped,
    rightSamples: right.samples,
    rightRequestMs: average(right.requestMs, right.samples),
    rightSourceAgeMs: average(right.sourceAgeMs, right.samples),
    rightDecodeMs: average(right.decodeMs, right.samples),
    rightDrawMs: average(right.drawMs, right.samples),
    rightBytes: average(right.bytes, right.samples),
    rightDropped: right.dropped
  };

  resetAccumulator();
  void fetch("/api/telemetry/ui", {
    method: "POST",
    cache: "no-store",
    keepalive: true,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload)
  }).catch(() => undefined);
}

function animationFrame(now: number) {
  if (lastRaf > 0) {
    const gap = now - lastRaf;
    accumulator.rafGapMaxMs = Math.max(accumulator.rafGapMaxMs, gap);
    if (gap > 24) accumulator.rafMisses += 1;
  }
  lastRaf = now;
  accumulator.rafFrames += 1;
  rafHandle = window.requestAnimationFrame(animationFrame);
}

export function startRuntimeTelemetry() {
  if (started || typeof window === "undefined") return;
  started = true;
  windowStartedAt = performance.now();
  rafHandle = window.requestAnimationFrame(animationFrame);
  flushTimer = window.setInterval(flushRuntimeTelemetry, 5000);

  if ("PerformanceObserver" in window) {
    try {
      const observer = new PerformanceObserver((entries) => {
        for (const entry of entries.getEntries()) {
          accumulator.longTasks += 1;
          accumulator.longTaskMs += entry.duration;
        }
      });
      observer.observe({ entryTypes: ["longtask"] });
    } catch {
      // Long-task observation is optional on older Chromium builds.
    }
  }

  window.addEventListener("pagehide", flushRuntimeTelemetry, { passive: true });
}

export function recordStateApiLatency(milliseconds: number) {
  if (!Number.isFinite(milliseconds) || milliseconds < 0) return;
  accumulator.stateApiSamples += 1;
  accumulator.stateApiMs += milliseconds;
}

export function recordPreviewTelemetry(
  cameraIndex: 0 | 1,
  values: {
    requestMs?: number;
    sourceAgeMs?: number;
    decodeMs?: number;
    drawMs?: number;
    bytes?: number;
    dropped?: number;
  }
) {
  const target = accumulator.preview[cameraIndex];
  target.samples += 1;
  target.requestMs += Math.max(0, values.requestMs ?? 0);
  target.sourceAgeMs += Math.max(0, values.sourceAgeMs ?? 0);
  target.decodeMs += Math.max(0, values.decodeMs ?? 0);
  target.drawMs += Math.max(0, values.drawMs ?? 0);
  target.bytes += Math.max(0, values.bytes ?? 0);
  target.dropped += Math.max(0, values.dropped ?? 0);
}

export function stopRuntimeTelemetryForTests() {
  if (!started) return;
  window.clearInterval(flushTimer);
  window.cancelAnimationFrame(rafHandle);
  started = false;
}
