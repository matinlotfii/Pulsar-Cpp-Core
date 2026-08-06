#!/usr/bin/env python3
"""Summarize a bounded Pulsar live trace and identify likely bottlenecks."""
from __future__ import annotations

import re
import statistics
import sys
from collections import defaultdict
from pathlib import Path


VALUE = r"([-+]?[0-9]+(?:\.[0-9]+)?)"


def values(text: str, pattern: str) -> list[float]:
    return [float(item) for item in re.findall(pattern, text)]


def median(items: list[float]) -> float | None:
    return statistics.median(items) if items else None


def fmt(value: float | None, unit: str = "") -> str:
    return "n/a" if value is None else f"{value:.3f}{unit}"


def metric(text: str, prefix: str, name: str) -> list[float]:
    return values(text, rf"{re.escape(prefix)}[^\n]*?{re.escape(name)}={VALUE}")


def camera_metrics(text: str, label: str) -> dict[str, float | None]:
    prefix = f"{label} Camera: latency-stats"
    names = {
        "output_fps": "output-fps",
        "acquired_fps": "acquired-fps",
        "dequeue_ms": "dequeue-wait-ms",
        "raw_ms": "raw-copy-ms",
        "process_ms": "process-ms",
        "publish_ms": "publish-ms",
        "host_ms": "host-pipeline-ms",
        "h2d_ms": "gpu-h2d-ms",
        "debayer_ms": "gpu-debayer-ms",
        "resize_ms": "gpu-resize-ms",
        "d2h_ms": "gpu-d2h-ms",
        "gpu_ms": "gpu-total-ms",
    }
    return {key: median(metric(text, prefix, token)) for key, token in names.items()}


def preview_metrics(text: str, label: str) -> dict[str, float | None]:
    prefix = f"{label} Camera: preview-stats"
    names = {"fps": "fps", "resize_ms": "resize-ms", "jpeg_ms": "jpeg-ms",
             "total_ms": "total-ms", "source_age_ms": "source-age-ms"}
    return {key: median(metric(text, prefix, token)) for key, token in names.items()}


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: summarize-live-log.py RUNTIME_LOG", file=sys.stderr)
        return 2
    path = Path(sys.argv[1])
    text = path.read_text(encoding="utf-8", errors="replace")

    left = camera_metrics(text, "Left")
    right = camera_metrics(text, "Right")
    preview_left = preview_metrics(text, "Left")
    preview_right = preview_metrics(text, "Right")

    renderer_names = {
        "loop_fps": "loop-fps", "left_age_ms": "left-host-age-ms",
        "right_age_ms": "right-host-age-ms", "skew_ms": "stereo-host-skew-ms",
        "upload_ms": "texture-upload-ms", "prepare_ms": "prepare-ms",
        "render_ms": "render-ms", "present_ms": "present-ms",
        "loop_total_ms": "loop-total-ms", "panels": "panels",
    }
    renderer = {
        key: median(metric(text, "SBS Renderer: latency-stats", token))
        for key, token in renderer_names.items()
    }

    snapshot = {
        "request_ms": median(values(text, rf"UI Snapshot: latest-stats[^\n]*?request-ms={VALUE}")),
        "source_age_ms": median(values(text, rf"UI Snapshot: latest-stats[^\n]*?source-age-ms={VALUE}")),
    }
    ui_names = {
        "raf_fps": "raf-fps", "missed_frames": "raf-misses",
        "max_gap_ms": "raf-gap-max-ms", "long_task_ms": "long-task-ms",
        "state_api_ms": "state-api-ms",
    }
    ui = {
        key: median(metric(text, "UI Runtime: perf-stats", token))
        for key, token in ui_names.items()
    }
    for key, token in {
        "preview_request_ms": "request-ms",
        "preview_source_age_ms": "source-age-ms",
        "preview_decode_ms": "decode-ms",
        "preview_draw_ms": "draw-ms",
        "preview_drops": "dropped",
    }.items():
        combined = []
        for side in ("left", "right"):
            combined.extend(metric(text, "UI Runtime: perf-stats", f"{side}-{token}"))
        ui[key] = median(combined)

    gpu_util = median(values(text, rf'\[SYSTEM\][^\n]*?gpu="{VALUE},'))
    memory_used = median(values(text, rf"\[SYSTEM\][^\n]*?memory-used-pct={VALUE}"))
    core_cpu = median(values(text, rf'\[SYSTEM\][^\n]*?core="[^\"]*?\s{VALUE}\s+[0-9.]+\s+[0-9]+\s+[A-Za-z]'))
    # ps column position can vary; collect explicit Chrome metrics reliably.
    chrome_renderer_cpu = median(values(text, rf"chrome-renderer-cpu={VALUE}"))
    chrome_gpu_cpu = median(values(text, rf"chrome-gpu-cpu={VALUE}"))

    display_failures = sorted(set(re.findall(
        r"\[(?:DISPLAY_PROBE|DISPLAY_PROBE_FINAL)\] ((?:VIEWER_WINDOW|PANEL_[0-9]+|GLASSES_PANEL_STATUS)=FAIL[^\n]*)",
        text)))
    display_passes = sorted(set(re.findall(
        r"\[(?:DISPLAY_PROBE|DISPLAY_PROBE_FINAL)\] ((?:VIEWER_WINDOW|PANEL_[0-9]+|GLASSES_PANEL_STATUS)=PASS[^\n]*)",
        text)))

    bottlenecks: list[tuple[str, str]] = []
    warnings: list[tuple[str, str]] = []

    fps_values = [v for v in (left["output_fps"], right["output_fps"]) if v is not None]
    if fps_values and min(fps_values) < 30.0:
        bottlenecks.append(("CAMERA_ACQUISITION",
                            f"Camera output is {min(fps_values):.2f} FPS; frames are not arriving fast enough."))
    for side, item in (("left", left), ("right", right)):
        if item["raw_ms"] is not None and item["raw_ms"] > 3.0:
            bottlenecks.append(("RAW_COPY", f"{side} raw staging copy={item['raw_ms']:.2f} ms"))
        if item["h2d_ms"] is not None and item["h2d_ms"] > 3.0:
            bottlenecks.append(("CUDA_H2D", f"{side} host-to-device={item['h2d_ms']:.2f} ms"))
        if item["process_ms"] is not None and item["process_ms"] > 5.0:
            bottlenecks.append(("CAMERA_PROCESS", f"{side} processing={item['process_ms']:.2f} ms"))
        if item["publish_ms"] is not None and item["publish_ms"] > 5.0:
            bottlenecks.append(("PUBLISH_COPY", f"{side} publish={item['publish_ms']:.2f} ms"))

    ages = [v for v in (renderer["left_age_ms"], renderer["right_age_ms"]) if v is not None]
    if ages and max(ages) > 55.0:
        bottlenecks.append(("FRAME_AGE", f"Rendered frame age={max(ages):.2f} ms"))
    if renderer["skew_ms"] is not None and renderer["skew_ms"] > 12.0:
        warnings.append(("STEREO_SKEW", f"Left/right skew={renderer['skew_ms']:.2f} ms"))
    if renderer["upload_ms"] is not None and renderer["upload_ms"] > 8.0:
        bottlenecks.append(("TEXTURE_UPLOAD", f"Texture upload={renderer['upload_ms']:.2f} ms"))
    if renderer["render_ms"] is not None and renderer["render_ms"] > 10.0:
        bottlenecks.append(("RENDER_COPY", f"Panel rendering={renderer['render_ms']:.2f} ms"))
    if renderer["present_ms"] is not None and renderer["present_ms"] > 4.0:
        bottlenecks.append(("DISPLAY_PRESENT", f"Present={renderer['present_ms']:.2f} ms"))

    if ui["raf_fps"] is not None and ui["raf_fps"] < 45.0:
        bottlenecks.append(("UI_RAF", f"UI animation rate={ui['raf_fps']:.2f} FPS"))
    if ui["long_task_ms"] is not None and ui["long_task_ms"] > 25.0:
        bottlenecks.append(("UI_MAIN_THREAD", f"UI long tasks={ui['long_task_ms']:.2f} ms"))
    if ui["state_api_ms"] is not None and ui["state_api_ms"] > 80.0:
        bottlenecks.append(("UI_API", f"/api/state={ui['state_api_ms']:.2f} ms"))
    if ui["preview_request_ms"] is not None and ui["preview_request_ms"] > 250.0:
        bottlenecks.append(("UI_PREVIEW_NETWORK", f"Preview request={ui['preview_request_ms']:.2f} ms"))
    if ui["preview_source_age_ms"] is not None and ui["preview_source_age_ms"] > 200.0:
        bottlenecks.append(("UI_PREVIEW_AGE", f"UI preview source age={ui['preview_source_age_ms']:.2f} ms"))
    if ui["preview_decode_ms"] is not None and ui["preview_decode_ms"] > 15.0:
        bottlenecks.append(("UI_PREVIEW_DECODE", f"Worker decode={ui['preview_decode_ms']:.2f} ms"))
    if ui["preview_draw_ms"] is not None and ui["preview_draw_ms"] > 10.0:
        bottlenecks.append(("UI_PREVIEW_DRAW", f"Canvas draw={ui['preview_draw_ms']:.2f} ms"))
    if display_failures:
        bottlenecks.append(("GLASSES_OUTPUT", "; ".join(display_failures)))

    # Deduplicate while preserving the strongest first observation.
    unique: dict[str, str] = {}
    for name, reason in bottlenecks:
        unique.setdefault(name, reason)
    unique_warnings: dict[str, str] = {}
    for name, reason in warnings:
        unique_warnings.setdefault(name, reason)

    print("PULSAR OBSERVABLE REALTIME V9 — AUTOMATIC SUMMARY")
    print("=================================================")
    print(f"SOURCE_LOG={path.resolve()}")
    print()
    for label, item in (("LEFT_CAMERA", left), ("RIGHT_CAMERA", right)):
        print(f"{label}: output={fmt(item['output_fps'],' fps')} acquired={fmt(item['acquired_fps'],' fps')} "
              f"dequeue={fmt(item['dequeue_ms'],' ms')} raw={fmt(item['raw_ms'],' ms')} "
              f"process={fmt(item['process_ms'],' ms')} publish={fmt(item['publish_ms'],' ms')} "
              f"H2D={fmt(item['h2d_ms'],' ms')} debayer={fmt(item['debayer_ms'],' ms')} "
              f"resize={fmt(item['resize_ms'],' ms')} D2H={fmt(item['d2h_ms'],' ms')}")
    print(f"RENDERER: loop={fmt(renderer['loop_fps'],' fps')} age-left={fmt(renderer['left_age_ms'],' ms')} "
          f"age-right={fmt(renderer['right_age_ms'],' ms')} skew={fmt(renderer['skew_ms'],' ms')} "
          f"upload={fmt(renderer['upload_ms'],' ms')} prepare={fmt(renderer['prepare_ms'],' ms')} "
          f"render={fmt(renderer['render_ms'],' ms')} present={fmt(renderer['present_ms'],' ms')} "
          f"loop-total={fmt(renderer['loop_total_ms'],' ms')} panels={fmt(renderer['panels'])}")
    print(f"UI_PREVIEW_ENCODER: left-total={fmt(preview_left['total_ms'],' ms')} "
          f"right-total={fmt(preview_right['total_ms'],' ms')} "
          f"left-fps={fmt(preview_left['fps'])} right-fps={fmt(preview_right['fps'])}")
    print(f"UI_BROWSER: raf={fmt(ui['raf_fps'],' fps')} long-task={fmt(ui['long_task_ms'],' ms')} "
          f"state-api={fmt(ui['state_api_ms'],' ms')} request={fmt(ui['preview_request_ms'],' ms')} "
          f"source-age={fmt(ui['preview_source_age_ms'],' ms')} "
          f"decode={fmt(ui['preview_decode_ms'],' ms')} draw={fmt(ui['preview_draw_ms'],' ms')} "
          f"drops={fmt(ui['preview_drops'])}")
    print(f"SYSTEM: gpu-util={fmt(gpu_util,'%')} memory-used={fmt(memory_used,'%')} "
          f"chrome-renderer-cpu={fmt(chrome_renderer_cpu,'%')} chrome-gpu-cpu={fmt(chrome_gpu_cpu,'%')}")
    print()
    if display_passes:
        print("DISPLAY_CHECKS:")
        for line in display_passes:
            print(f"  - {line}")
    print()
    print("AUTOMATIC DIAGNOSIS")
    print("-------------------")
    if unique:
        for name, reason in unique.items():
            print(f"BOTTLENECK={name}: {reason}")
    else:
        print("BOTTLENECK=NONE_PROVEN: No measured stage crossed the configured thresholds.")
    for name, reason in unique_warnings.items():
        print(f"WARNING={name}: {reason}")

    if not any(left.values()) or not any(renderer.values()):
        print("WARNING=INSUFFICIENT_SAMPLES: Camera/renderer metrics were incomplete; run a longer live trace.")
    print()
    print("NOTE=This report uses medians from bounded low-rate telemetry; it does not write frames or run perf in the real-time path.")
    return 1 if unique else 0


if __name__ == "__main__":
    raise SystemExit(main())
