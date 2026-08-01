import { Move3D, RefreshCcw, ScanLine, SlidersHorizontal, WandSparkles } from "lucide-react";
import { useEffect, useRef, useState, type CSSProperties, type ReactNode } from "react";
import { Button as AriaButton } from "react-aria-components";
import { MedicalView, requestStereoAutoAlign, stereoAutoAlignTriggerParam } from "../camera-stream";
import { lightTapFeedback } from "../feedback";
import type { StereoAutoAlignState, StereoCalibrationStatus, StereoMode, StereoSettingsPanel } from "../model";

function clamp(value: number, min: number, max: number) {
  return Math.min(max, Math.max(min, value));
}

function estimateCheckerboardConfidence(source: HTMLCanvasElement) {
  const width = 144;
  const height = 96;
  const sampleCanvas = document.createElement("canvas");
  sampleCanvas.width = width;
  sampleCanvas.height = height;
  const context = sampleCanvas.getContext("2d", { willReadFrequently: true });
  if (!context) return 0;

  context.drawImage(source, 0, 0, width, height);
  const image = context.getImageData(0, 0, width, height);
  let contrastScore = 0;
  let contrastSamples = 0;
  for (let y = 0; y < height - 1; y += 4) {
    for (let x = 0; x < width - 1; x += 4) {
      const offset = (y * width + x) * 4;
      const rightOffset = (y * width + x + 1) * 4;
      const bottomOffset = ((y + 1) * width + x) * 4;
      const luminance = image.data[offset] * 0.2126 + image.data[offset + 1] * 0.7152 + image.data[offset + 2] * 0.0722;
      const luminanceRight = image.data[rightOffset] * 0.2126 + image.data[rightOffset + 1] * 0.7152 + image.data[rightOffset + 2] * 0.0722;
      const luminanceBottom = image.data[bottomOffset] * 0.2126 + image.data[bottomOffset + 1] * 0.7152 + image.data[bottomOffset + 2] * 0.0722;
      contrastScore += Math.abs(luminance - luminanceRight) + Math.abs(luminance - luminanceBottom);
      contrastSamples += 2;
    }
  }

  return clamp(Math.round(contrastScore / Math.max(1, contrastSamples) * 1.6), 0, 100);
}

function detectStereoCheckerboard() {
  const frames = Array.from(document.querySelectorAll<HTMLImageElement>(".stereo-screen .stereo-views .camera-live-image.is-visible"));
  if (frames.length < 2) return { detected: false, score: 0 };

  const canvases = frames.slice(0, 2).map((frame) => {
    const canvas = document.createElement("canvas");
    const width = Math.max(24, frame.naturalWidth || frame.clientWidth || 320);
    const height = Math.max(24, frame.naturalHeight || frame.clientHeight || 180);
    canvas.width = width;
    canvas.height = height;
    const context = canvas.getContext("2d");
    context?.drawImage(frame, 0, 0, width, height);
    return canvas;
  });

  const scores = canvases.map((frame) => estimateCheckerboardConfidence(frame));
  const score = Math.round((scores[0] + scores[1]) / 2);
  return { detected: scores.every((frameScore) => frameScore >= 68), score };
}

function formatRelativeCalibrationTime(timestamp: number | null, now: number) {
  if (!timestamp) return "Never";
  const elapsedSeconds = Math.max(0, Math.floor((now - timestamp) / 1000));
  if (elapsedSeconds < 60) return "Just now";
  const elapsedMinutes = Math.floor(elapsedSeconds / 60);
  if (elapsedMinutes < 60) return `${elapsedMinutes} min ago`;
  const elapsedHours = Math.floor(elapsedMinutes / 60);
  if (elapsedHours < 24) return `${elapsedHours} hr ago`;
  const elapsedDays = Math.floor(elapsedHours / 24);
  return `${elapsedDays} day${elapsedDays === 1 ? "" : "s"} ago`;
}

export function StereoScreen({
  header,
  mode,
  depth,
  rotation,
  eyeSwap,
  autoAlign,
  setAutoAlign,
  onModeChange,
  onDepthChange,
  onRotationCycle,
  onEyeSwapToggle
}: {
  header: ReactNode;
  mode: StereoMode;
  depth: number;
  rotation: number;
  eyeSwap: boolean;
  autoAlign: StereoAutoAlignState;
  setAutoAlign: (state: StereoAutoAlignState) => void;
  onModeChange: (mode: StereoMode) => void;
  onDepthChange: (depth: number) => void;
  onRotationCycle: () => void;
  onEyeSwapToggle: () => void;
}) {
  const holdAlignPressedRef = useRef(false);
  const [activePanel, setActivePanel] = useState<StereoSettingsPanel>("mode");
  const [calibrationStatus, setCalibrationStatus] = useState<StereoCalibrationStatus>("idle");
  const [calibrationProgress, setCalibrationProgress] = useState(0);
  const [calibrationScore, setCalibrationScore] = useState<number | null>(null);
  const [lastCalibratedAt, setLastCalibratedAt] = useState<number | null>(null);
  const [relativeTimeNow, setRelativeTimeNow] = useState(() => Date.now());
  const [showCalibrationErrorNotice, setShowCalibrationErrorNotice] = useState(false);
  const detectedCheckerScoreRef = useRef(0);
  const stereoPanelTitle: Record<StereoSettingsPanel, string> = {
    mode: "3D Mode",
    calibration: "Calibration",
    "auto-calibration": "Auto Calibration",
    depth: "Depth"
  };
  const stereoModeOptions: Array<{ value: StereoMode; label: string }> = [
    { value: "SBS", label: "SBS" },
    { value: "Line Interleaved", label: "Line Interleaved" }
  ];
  const stereoPanelButtons = [
    { panel: "mode", icon: Move3D, label: "3D Mode" },
    { panel: "calibration", icon: ScanLine, label: "Calibration" },
    { panel: "auto-calibration", icon: WandSparkles, label: "Auto Calibration" },
    { panel: "depth", icon: SlidersHorizontal, label: "Depth" }
  ] as const;
  const visibleStereoMode: StereoMode = mode;
  const isCalibrationDetecting = calibrationStatus === "detecting";
  const isCalibrationRunning = calibrationStatus === "running";
  const showCalibrationScan = isCalibrationDetecting || isCalibrationRunning;
  const showCalibrationGuide = !showCalibrationScan;
  const calibrationGuideClassName = `stereo-calibration-guide ${showCalibrationErrorNotice ? "is-error" : ""}`;
  const lastCalibrationLabel = formatRelativeCalibrationTime(lastCalibratedAt, relativeTimeNow);
  const autoAlignQuality = Math.round(autoAlign.quality);
  const calibrationButtonLabel =
    isCalibrationDetecting ? "Looking for Board" :
    isCalibrationRunning ? "Calibrating" :
    calibrationStatus === "success" ? "Calibrate Again" : "Start Calibration";

  useEffect(() => {
    if (!isCalibrationDetecting) return undefined;
    const startedAt = window.performance.now();
    const timer = window.setInterval(() => {
      const result = detectStereoCheckerboard();
      if (result.detected) {
        detectedCheckerScoreRef.current = result.score;
        setCalibrationProgress(1);
        setCalibrationScore(null);
        setCalibrationStatus("running");
        window.clearInterval(timer);
        return;
      }
      if (window.performance.now() - startedAt > 7000) {
        detectedCheckerScoreRef.current = 0;
        setCalibrationProgress(0);
        setCalibrationScore(null);
        setCalibrationStatus("failed");
        setShowCalibrationErrorNotice(true);
        lightTapFeedback("error");
        window.clearInterval(timer);
      }
    }, 320);
    return () => window.clearInterval(timer);
  }, [isCalibrationDetecting]);

  useEffect(() => {
    if (!isCalibrationRunning) return undefined;
    const timer = window.setInterval(() => {
      setCalibrationProgress((current) => {
        const next = Math.min(current + 8, 100);
        if (next >= 100) {
          window.clearInterval(timer);
          const detectionScore = detectedCheckerScoreRef.current || 72;
          const score = clamp(Math.round(detectionScore * 0.72 + 26 - Math.abs(depth - 5) * 1.4 - (eyeSwap ? 0 : 4)), 62, 99);
          setCalibrationScore(score);
          if (score >= 86) {
            const now = Date.now();
            setLastCalibratedAt(now);
            setRelativeTimeNow(now);
            setCalibrationStatus("success");
            setShowCalibrationErrorNotice(false);
            lightTapFeedback("success");
          } else {
            setCalibrationStatus("failed");
            setShowCalibrationErrorNotice(true);
            lightTapFeedback("error");
          }
        }
        return next;
      });
    }, 90);
    return () => window.clearInterval(timer);
  }, [depth, eyeSwap, isCalibrationRunning]);

  useEffect(() => {
    if (!lastCalibratedAt) return undefined;
    const timer = window.setInterval(() => setRelativeTimeNow(Date.now()), 30_000);
    return () => window.clearInterval(timer);
  }, [lastCalibratedAt]);

  useEffect(() => {
    if (!showCalibrationErrorNotice) return undefined;
    const timer = window.setTimeout(() => setShowCalibrationErrorNotice(false), 3000);
    return () => window.clearTimeout(timer);
  }, [showCalibrationErrorNotice]);

  const updateAutoAlign = async (query: string) => {
    try {
      const state = await requestStereoAutoAlign(query);
      setAutoAlign(state);
      return state;
    } catch {
      return null;
    }
  };

  const handleHoldAlignChange = (pressed: boolean) => {
    if (holdAlignPressedRef.current === pressed) return;
    holdAlignPressedRef.current = pressed;
    if (pressed) {
      lightTapFeedback("tap");
    }
    void updateAutoAlign(`?action=hold&active=${pressed ? "1" : "0"}`);
  };

  return (
    <div className="hmi-screen stereo-screen">
      {header}
      <main className="stereo-layout">
        <div>
          <MedicalView split stereoMode={visibleStereoMode} alignOffset={autoAlign} showAutoAlignOverlay={activePanel === "auto-calibration"} />
          <div className="stereo-mode-row">
            {stereoPanelButtons.map(({ panel, icon: Icon, label }) => (
              <AriaButton key={panel} className={`camera-action stereo-mode-action ${activePanel === panel ? "is-active" : ""}`} aria-label={label} onPress={() => {
                lightTapFeedback("tap");
                setActivePanel(panel);
              }}>
                <Icon size={24} />
                <span>{label}</span>
              </AriaButton>
            ))}
          </div>
        </div>

        <aside className="quick-panel stereo-side">
          <div className="stereo-side-head"><span>{stereoPanelTitle[activePanel]}</span><small>Stereo Setup</small></div>

          {activePanel === "mode" ? (
            <div className="stereo-panel-stack">
              {stereoModeOptions.map((option) => (
                <AriaButton key={option.value} className={`stereo-choice ${mode === option.value ? "is-active" : ""}`} aria-label={option.label} onPress={() => onModeChange(option.value)}>
                  <span>{option.label}</span>
                  <small>{mode === option.value ? "Selected" : "Select"}</small>
                </AriaButton>
              ))}
            </div>
          ) : null}

          {activePanel === "calibration" ? (
            <div className="stereo-panel-stack">
              <AriaButton className={`stereo-action stereo-calibration-button ${isCalibrationDetecting || isCalibrationRunning ? "is-running" : ""}`} aria-label={calibrationButtonLabel} isDisabled={isCalibrationDetecting || isCalibrationRunning} onPress={() => {
                lightTapFeedback("tap");
                detectedCheckerScoreRef.current = 0;
                setShowCalibrationErrorNotice(false);
                setCalibrationScore(null);
                setCalibrationProgress(0);
                setCalibrationStatus("detecting");
              }}>
                {calibrationButtonLabel}
                <ScanLine size={18} />
              </AriaButton>

              {showCalibrationGuide ? (
                <>
                  <div className="stereo-last-calibration"><small>Last Calibrated</small><strong>{lastCalibrationLabel}</strong></div>
                  <div className={calibrationGuideClassName}>
                    <strong>{showCalibrationErrorNotice ? "Calibration failed" : "9x6 inner-corner checkerboard target"}</strong>
                    <span>{showCalibrationErrorNotice ? "Show the checkerboard and try again." : "Hold it steady in both camera views."}</span>
                  </div>
                </>
              ) : null}

              {showCalibrationScan ? (
                <div className={`stereo-calibration-card is-${calibrationStatus}`}>
                  <div className="stereo-checkerboard" aria-hidden="true">
                    <span className="stereo-checker-scan" style={{ "--scan-progress": `${calibrationProgress}%` } as CSSProperties} />
                  </div>
                  <div className="stereo-calibration-meta">
                    <small>Stereo Calibration</small>
                    <strong>{isCalibrationDetecting ? "Detecting board" : isCalibrationRunning ? `${calibrationProgress}%` : calibrationScore !== null ? `${calibrationScore}% matched` : "Checkerboard not detected"}</strong>
                    <span>{isCalibrationDetecting ? "Show the checkerboard" : isCalibrationRunning ? "Calibrating both cameras" : calibrationStatus === "success" ? "Calibration successful" : calibrationScore === null ? "Show the board to both cameras and try again" : "Not accurate enough. Try again"}</span>
                  </div>
                </div>
              ) : null}
            </div>
          ) : null}

          {activePanel === "auto-calibration" ? (
            <div className="stereo-panel-stack">
              <AriaButton className={`toggle-row stereo-auto-toggle ${autoAlign.enabled ? "" : "is-off"}`} aria-label="Auto Alignment" onPress={() => {
                lightTapFeedback("tap");
                void updateAutoAlign(`?action=enable&enabled=${autoAlign.enabled ? "0" : "1"}`);
              }}>
                <span>Auto Align</span>
                <span className="toggle-on" />
              </AriaButton>

              <div className="stereo-trigger-grid" aria-label="Auto alignment trigger">
                {(["Hold Button", "Pedal"] as const).map((trigger) => (
                  <AriaButton key={trigger} className={`stereo-trigger-chip ${autoAlign.trigger === trigger ? "is-active" : ""}`} aria-label={trigger} onPress={() => {
                    lightTapFeedback("tap");
                    void updateAutoAlign(`?action=trigger&trigger=${stereoAutoAlignTriggerParam(trigger)}`);
                  }}>
                    {trigger}
                  </AriaButton>
                ))}
              </div>

              <AriaButton
                className={`stereo-action stereo-hold-align ${autoAlign.active ? "is-active" : ""}`}
                aria-label="Hold to align"
                isDisabled={!autoAlign.enabled}
                onPressChange={handleHoldAlignChange}
              >
                Hold Align
                <WandSparkles size={18} />
              </AriaButton>

              <div className="stereo-align-metrics">
                <span><small>X</small><strong>{autoAlign.xOffset.toFixed(1)} px</strong></span>
                <span><small>Y</small><strong>{autoAlign.yOffset.toFixed(1)} px</strong></span>
                <span><small>Match</small><strong>{autoAlignQuality}%</strong></span>
              </div>

              <AriaButton className="stereo-action" aria-label="Reset auto alignment" onPress={() => {
                lightTapFeedback("tap");
                void updateAutoAlign("?action=reset");
              }}>
                Reset Offset
                <RefreshCcw size={18} />
              </AriaButton>
            </div>
          ) : null}

          {activePanel === "depth" ? (
            <div className="stereo-panel-stack">
              <div className="stereo-depth-value"><small>Depth</small><strong>{depth}</strong></div>
              <input type="range" min="1" max="10" value={depth} aria-label="Depth" onChange={(event) => onDepthChange(Number(event.currentTarget.value))} />
              <AriaButton className="stereo-action" aria-label="3D Rotation" onPress={onRotationCycle}>Rotation<small>{rotation} deg</small></AriaButton>
              <AriaButton className={`toggle-row stereo-eye-toggle ${eyeSwap ? "" : "is-off"}`} aria-label="Eye Swap" onPress={onEyeSwapToggle}><span>Eye Swap</span><span className="toggle-on" /></AriaButton>
            </div>
          ) : null}
        </aside>
      </main>
    </div>
  );
}
