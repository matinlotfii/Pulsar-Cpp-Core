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

function cameraServiceStreamUrl(cameraIndex: 0 | 1, retryToken: number) {
  return `${cameraServiceBaseUrl()}/camera/${cameraIndex}/stream?v=${retryToken}`;
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
  const [retryToken, setRetryToken] = useState(0);
  const reconnectTimerRef = useRef<number | null>(null);
  const offlineTimerRef = useRef<number | null>(null);
  const isCalibratedFeed = Boolean(alignOffset?.enabled && alignOffset.samples > 0);
  const alignStyle = cameraAlignStyle(cameraIndex, alignOffset);

  useEffect(() => {
    return () => {
      if (reconnectTimerRef.current !== null) {
        window.clearTimeout(reconnectTimerRef.current);
      }
      if (offlineTimerRef.current !== null) {
        window.clearTimeout(offlineTimerRef.current);
      }
    };
  }, []);

  const scheduleReconnect = () => {
    if (reconnectTimerRef.current !== null) {
      window.clearTimeout(reconnectTimerRef.current);
    }
    if (offlineTimerRef.current !== null) {
      window.clearTimeout(offlineTimerRef.current);
    }
    if (hasLiveFrame) {
      setStreamStatus("connecting");
      offlineTimerRef.current = window.setTimeout(() => {
        setStreamStatus("offline");
        offlineTimerRef.current = null;
      }, 1600);
    } else {
      setStreamStatus("offline");
    }
    reconnectTimerRef.current = window.setTimeout(() => {
      setStreamStatus("connecting");
      setRetryToken((current) => current + 1);
      reconnectTimerRef.current = null;
    }, 900);
  };

  return (
    <div className={`medical-texture is-live-stream camera-stream-${streamStatus} ${isCalibratedFeed ? "is-calibrated-feed" : ""}`}>
      <img
        key={`${cameraIndex}-${retryToken}`}
        className="camera-live-image is-visible"
        src={cameraServiceStreamUrl(cameraIndex, retryToken)}
        alt={`${label} live camera stream`}
        style={alignStyle}
        draggable={false}
        decoding="async"
        fetchPriority="high"
        onLoad={() => {
          if (offlineTimerRef.current !== null) {
            window.clearTimeout(offlineTimerRef.current);
            offlineTimerRef.current = null;
          }
          setHasLiveFrame(true);
          setStreamStatus("live");
        }}
        onError={scheduleReconnect}
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
