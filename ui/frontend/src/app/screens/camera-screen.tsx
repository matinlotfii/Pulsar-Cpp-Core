import { Camera, Clapperboard, RefreshCcw, SlidersHorizontal, Sparkles, type LucideIcon } from "lucide-react";
import type { ReactNode } from "react";
import { Button as AriaButton } from "react-aria-components";
import { MedicalView } from "../camera-stream";
import type { CameraControlState, CameraCycleField, CameraField, StereoAutoAlignState } from "../model";

function CameraActions({
  camera,
  onAction
}: {
  camera: CameraControlState;
  onAction: (action: "snapshot" | "record" | "freeze" | "rotate" | "more") => void;
}) {
  const actions: Array<{
    icon: LucideIcon;
    label: string;
    action: "snapshot" | "record" | "freeze" | "rotate" | "more";
    active?: boolean;
  }> = [
    { icon: Camera, label: "Snapshot", action: "snapshot" },
    { icon: Clapperboard, label: camera.recording ? "Recording" : "Record", action: "record", active: camera.recording },
    { icon: Sparkles, label: camera.frozen ? "Frozen" : "Freeze", action: "freeze", active: camera.frozen },
    { icon: RefreshCcw, label: `${camera.rotation} deg`, action: "rotate" },
    { icon: SlidersHorizontal, label: "More", action: "more" }
  ];

  return (
    <div className="camera-actions">
      {actions.map(({ icon: Icon, label, action, active }) => (
        <AriaButton className={`camera-action ${active ? "is-active" : ""}`} key={action} aria-label={label} onPress={() => onAction(action)}>
          <Icon size={24} />
          <span>{label}</span>
        </AriaButton>
      ))}
    </div>
  );
}

function QuickControls({
  camera,
  onAdjust,
  onCycle
}: {
  camera: CameraControlState;
  onAdjust: (field: CameraField, delta: number) => void;
  onCycle: (field: CameraCycleField) => void;
}) {
  const rows: Array<{ label: string; value: string; field: CameraField; delta: number }> = [
    { label: "Optical Zoom", value: `${camera.zoom.toFixed(1)}x`, field: "zoom", delta: 0.1 },
    { label: "Focus", value: `${camera.focus > 0 ? "+" : ""}${camera.focus}`, field: "focus", delta: 1 },
    { label: "Brightness", value: String(camera.brightness), field: "brightness", delta: 5 }
  ];

  return (
    <aside className="quick-panel">
      {rows.map((row) => (
        <div className="control-row" key={row.field}>
          <span>{row.label}</span>
          <strong>{row.value}</strong>
          <div className="control-actions">
            <AriaButton aria-label={`${row.label} down`} onPress={() => onAdjust(row.field, -row.delta)}>-</AriaButton>
            <AriaButton aria-label={`${row.label} up`} onPress={() => onAdjust(row.field, row.delta)}>+</AriaButton>
          </div>
        </div>
      ))}
      <AriaButton className="quick-link" onPress={() => onCycle("whiteBalance")}><span>White Balance</span><strong>{camera.whiteBalance}</strong></AriaButton>
      <AriaButton className="quick-link" onPress={() => onCycle("enhance")}><span>Enhance</span><strong>{camera.enhance}</strong></AriaButton>
      <div className="control-status" role="status">{camera.status}</div>
    </aside>
  );
}

export function CameraScreen({
  header,
  cameraIndex,
  camera,
  autoAlign,
  onCameraAction,
  onCameraAdjust,
  onCameraCycle
}: {
  header: ReactNode;
  cameraIndex: 0 | 1;
  camera: CameraControlState;
  autoAlign: StereoAutoAlignState;
  onCameraAction: (cameraIndex: 0 | 1, action: "snapshot" | "record" | "freeze" | "rotate" | "more") => void;
  onCameraAdjust: (cameraIndex: 0 | 1, field: CameraField, delta: number) => void;
  onCameraCycle: (cameraIndex: 0 | 1, field: CameraCycleField) => void;
}) {
  return (
    <div className="hmi-screen camera-screen">
      {header}
      <main className="camera-layout">
        <div className="camera-main">
          <MedicalView cameraIndex={cameraIndex} alignOffset={autoAlign} />
          <CameraActions camera={camera} onAction={(action) => onCameraAction(cameraIndex, action)} />
        </div>
        <QuickControls camera={camera} onAdjust={(field, delta) => onCameraAdjust(cameraIndex, field, delta)} onCycle={(field) => onCameraCycle(cameraIndex, field)} />
      </main>
    </div>
  );
}
