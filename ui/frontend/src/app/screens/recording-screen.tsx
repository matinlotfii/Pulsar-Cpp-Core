import { ChevronRight, HardDrive } from "lucide-react";
import type { ReactNode } from "react";
import { Button as AriaButton } from "react-aria-components";
import type { SaveTarget } from "../model";

function formatElapsed(totalSeconds: number) {
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = totalSeconds % 60;
  return [hours, minutes, seconds].map((part) => String(part).padStart(2, "0")).join(":");
}

export function RecordingScreen({
  header,
  recordingActive,
  elapsed,
  saveTarget,
  onToggleRecording,
  onSaveTargetCycle,
  onOpenRecordings
}: {
  header: ReactNode;
  recordingActive: boolean;
  elapsed: number;
  saveTarget: SaveTarget;
  onToggleRecording: () => void;
  onSaveTargetCycle: () => void;
  onOpenRecordings: () => void;
}) {
  return (
    <div className="hmi-screen recording-screen">
      {header}
      <main className="recording-layout">
        <section className={`record-status ${recordingActive ? "is-recording" : "is-idle"}`}>
          <span>{recordingActive ? "Recording ●" : "Ready"}</span>
          <div className="rec-ring">{formatElapsed(elapsed)}</div>
          <strong>4K | 30fps | 120 Mbps</strong>
          <AriaButton className={`stop-record ${recordingActive ? "" : "is-idle"}`} onPress={onToggleRecording}>
            {recordingActive ? "■ Stop Recording" : "● Start Recording"}
          </AriaButton>
        </section>
        <section className="record-info">
          <AriaButton className="quick-link" aria-label="Save To" onPress={onSaveTargetCycle}><span>Save To<small>{saveTarget}</small></span><ChevronRight size={22} /></AriaButton>
          <div><span>File Name</span><strong>Surgery_2026-07-20_1030</strong></div>
          <div><span>Remaining Time</span><strong>02:45:10</strong></div>
          <AriaButton className="recordings-button" onPress={onOpenRecordings}><HardDrive size={22} /> Recordings</AriaButton>
        </section>
      </main>
    </div>
  );
}
