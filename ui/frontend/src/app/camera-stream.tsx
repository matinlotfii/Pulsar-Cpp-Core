import { useEffect, useRef, useState, type CSSProperties } from "react";
import type { StereoAutoAlignState, StereoAutoAlignTrigger, StereoMode } from "./model";

export const defaultStereoAutoAlign: StereoAutoAlignState = {
  enabled: false,
  active: false,
  trigger: "Hold Button",
  xOffset: 0,
  yOffset: 0,
  xRatio: 0,
  yRatio: 0,
  quality: 0,
  samples: 0,
  status: "Idle",
  message: "Hold Align to match both views."
};

function cameraAlignStyle(cameraIndex: 0 | 1, alignOffset?: StereoAutoAlignState) {
  const enabled = Boolean(alignOffset?.enabled && alignOffset.samples > 0);
  if (!enabled || !alignOffset) return undefined;

  const direction = cameraIndex === 0 ? -0.5 : 0.5;
  const translateX = alignOffset.xRatio * direction * 100;
  const translateY = alignOffset.yRatio * direction * 100;
  const overscan = Math.min(1.08, 1 + Math.max(Math.abs(translateX), Math.abs(translateY)) / 700);

  return {
    "--camera-align-x": `${translateX}%`,
    "--camera-align-y": `${translateY}%`,
    "--camera-align-scale": overscan.toFixed(4)
  } as CSSProperties;
}

function cameraServiceBaseUrl() {
  const configured = import.meta.env.VITE_PULSAR_CAMERA_BASE_URL;
  if (typeof configured === "string" && configured.length > 0) {
    return configured.replace(/\/$/, "");
  }
  if (typeof window !== "undefined" && window.location.origin) {
    return window.location.origin;
  }
  return "http://127.0.0.1:4173";
}

function cameraLatestFrameUrl(cameraIndex: 0 | 1, previousFrameId: number) {
  return `${cameraServiceBaseUrl()}/camera/${cameraIndex}/frame.jpg?after=${previousFrameId}&t=${performance.now().toFixed(0)}`;
}

export function stereoAutoAlignTriggerParam(trigger: StereoAutoAlignTrigger) {
  if (trigger === "Pedal") return "pedal";
  if (trigger === "Hardware Zoom") return "zoom";
  if (trigger === "Manual") return "manual";
  return "hold";
}

export async function requestStereoAutoAlign(query = "") {
  const response = await fetch(`${cameraServiceBaseUrl()}/api/stereo/auto-align${query}`, { cache: "no-store" });
  if (!response.ok) {
    throw new Error("Stereo auto alignment unavailable.");
  }
  return { ...defaultStereoAutoAlign, ...await response.json() } as StereoAutoAlignState;
}

type CameraStreamStatus = "connecting" | "live" | "offline";
type WorkerFrameMessage =
  | { type: "bitmap"; bitmap: ImageBitmap; sequence: number }
  | { type: "error" };

function CameraLiveView({
  cameraIndex,
  label,
  alignOffset
}: {
  cameraIndex: 0 | 1;
  label: string;
  alignOffset?: StereoAutoAlignState;
}) {
  const [streamStatus, setStreamStatus] = useState<CameraStreamStatus>("connecting");
  const [hasLiveFrame, setHasLiveFrame] = useState(false);
  const canvasRef = useRef<HTMLCanvasElement | null>(null);
  const isCalibratedFeed = Boolean(alignOffset?.enabled && alignOffset.samples > 0);
  const alignStyle = cameraAlignStyle(cameraIndex, alignOffset);

  useEffect(() => {
    let stopped = false;
    let consecutiveFailures = 0;
    let previousFrameId = 0;
    let controller: AbortController | null = null;
    const worker = new Worker(new URL("./cameraFrameWorker.ts", import.meta.url), { type: "module" });

    worker.onmessage = (event: MessageEvent<WorkerFrameMessage>) => {
      if (stopped) return;
      if (event.data.type === "error") {
        setStreamStatus("offline");
        return;
      }
      const bitmap = event.data.bitmap;
      const canvas = canvasRef.current;
      const context = canvas?.getContext("2d", { alpha: false, desynchronized: true });
      if (canvas && context) {
        const targetWidth = Math.max(1, Math.round(canvas.clientWidth || bitmap.width));
        const targetHeight = Math.max(1, Math.round(canvas.clientHeight || bitmap.height));
        if (canvas.width !== targetWidth || canvas.height !== targetHeight) {
          canvas.width = targetWidth;
          canvas.height = targetHeight;
        }
        const scale = Math.max(targetWidth / bitmap.width, targetHeight / bitmap.height);
        const sourceWidth = targetWidth / scale;
        const sourceHeight = targetHeight / scale;
        const sourceX = (bitmap.width - sourceWidth) * 0.5;
        const sourceY = (bitmap.height - sourceHeight) * 0.5;
        context.drawImage(bitmap, sourceX, sourceY, sourceWidth, sourceHeight,
                          0, 0, targetWidth, targetHeight);
        setHasLiveFrame(true);
        setStreamStatus("live");
      }
      bitmap.close();
    };

    worker.onerror = () => {
      if (!stopped) setStreamStatus("offline");
    };

    const sleep = (milliseconds: number) =>
      new Promise<void>((resolve) => window.setTimeout(resolve, milliseconds));

    const receiveLatestFrames = async () => {
      while (!stopped) {
        controller = new AbortController();
        try {
          const response = await fetch(cameraLatestFrameUrl(cameraIndex, previousFrameId), {
            cache: "no-store",
            signal: controller.signal,
            headers: { Accept: "image/jpeg" }
          });
          if (!response.ok) throw new Error(`camera preview HTTP ${response.status}`);
          const frameId = Number(response.headers.get("X-Pulsar-Frame-Id") ?? "0");
          const buffer = await response.arrayBuffer();
          if (stopped) break;
          if (buffer.byteLength > 0 && frameId !== previousFrameId) {
            previousFrameId = frameId;
            worker.postMessage({ type: "frame", buffer }, [buffer]);
          }
          consecutiveFailures = 0;
        } catch (error) {
          if (stopped || (error instanceof DOMException && error.name === "AbortError")) break;
          consecutiveFailures += 1;
          setStreamStatus(consecutiveFailures >= 3 ? "offline" : "connecting");
          await sleep(Math.min(800, 120 * consecutiveFailures));
        }
      }
    };

    void receiveLatestFrames();
    return () => {
      stopped = true;
      controller?.abort();
      worker.terminate();
    };
  }, [cameraIndex]);

  return (
    <div className={`medical-texture is-live-stream camera-stream-${streamStatus} ${isCalibratedFeed ? "is-calibrated-feed" : ""}`}>
      <canvas
        ref={canvasRef}
        className="camera-live-image is-visible"
        aria-label={`${label} latest-only live camera preview`}
        style={alignStyle}
      />
      {streamStatus === "offline" || (!hasLiveFrame && streamStatus !== "live") ? (
        <div className="camera-disconnect-panel" role="status" aria-live="polite">
          <div className="camera-disconnect-copy">
            <strong>{streamStatus === "offline" ? `${label} disconnected` : `Connecting ${label.toLowerCase()}`}</strong>
            <span>{streamStatus === "offline" ? "No live image is available." : "Waiting for live image."}</span>
          </div>
        </div>
      ) : null}
      <span className="vessel v1" />
      <span className="vessel v2" />
      <span className="vessel v3" />
      <span className="vessel v4" />
      {streamStatus === "live" ? (
        <>
          <span className="view-label is-live">● LIVE</span>
          <span className="fullscreen-cue">⌖</span>
        </>
      ) : null}
    </div>
  );
}

export function MedicalView({
  split = false,
  cameraIndex = 0,
  stereoMode = "SBS",
  alignOffset,
  showAutoAlignOverlay = false
}: {
  split?: boolean;
  cameraIndex?: 0 | 1;
  stereoMode?: StereoMode;
  alignOffset?: StereoAutoAlignState;
  showAutoAlignOverlay?: boolean;
}) {
  const resolvedAlignOffset = alignOffset ?? defaultStereoAutoAlign;
  const tissue = <CameraLiveView cameraIndex={cameraIndex} label={cameraIndex === 0 ? "Left Camera" : "Right Camera"} alignOffset={resolvedAlignOffset} />;
  const isLineToLine = stereoMode === "Line Interleaved";
  const isAutoAlignOverlay = Boolean(showAutoAlignOverlay && resolvedAlignOffset.enabled);

  return split ? (
    <div className={`stereo-views ${isLineToLine ? "is-line-to-line" : ""} ${isAutoAlignOverlay ? "has-auto-align" : ""}`}>
      <CameraLiveView cameraIndex={0} label="Left Camera" alignOffset={resolvedAlignOffset} />
      <CameraLiveView cameraIndex={1} label="Right Camera" alignOffset={resolvedAlignOffset} />
    </div>
  ) : (
    tissue
  );
}
