import React from "react";
import { useEffect, useRef, useState } from "react";
import { api } from "../api/client.js";
import type { CameraState, RecordingState } from "../types.js";
import { CameraPreview } from "./CameraPreview.js";
import { Segmented, StepControl, ToggleRow } from "./ControlRow.js";
import { Icon } from "./Icon.js";
export function CameraControlPage({ camera, recording, refresh }: {
    camera: CameraState;
    recording: RecordingState;
    refresh: () => Promise<void>;
}) {
    const index = camera.index as 0 | 1;
    const [draft, setDraft] = useState(camera.controls);
    const first = useRef(true);
    useEffect(() => setDraft(camera.controls), [camera.controls, camera.index]);
    useEffect(() => {
        if (first.current) {
            first.current = false;
            return;
        }
        const timer = window.setTimeout(() => {
            void api.camera(index, draft).then(() => refresh()).catch(() => undefined);
        }, 120);
        return () => window.clearTimeout(timer);
    }, [draft, index, refresh]);
    const patch = <K extends keyof typeof draft>(key: K, value: (typeof draft)[K]) => setDraft((current) => ({ ...current, [key]: value }));
    const recordingAction = async () => {
        if (recording.active)
            await api.stopRecording();
        else
            await api.startRecording();
        await refresh();
    };
    return (<div className="camera-page-grid page-enter">
      <section className="camera-stage glass-panel">
        <CameraPreview index={index} online={camera.online} label={camera.label}/>
        <div className="camera-meta"><span>{camera.width || "—"} × {camera.height || "—"}</span><span>{camera.fps.toFixed(1)} fps</span><span>{camera.model || "Daheng Galaxy"}</span></div>
        <div className="camera-actions">
          <button onClick={() => void api.snapshot()}><Icon name="camera"/><span>Snapshot</span></button>
          <button className={recording.active ? "is-danger" : ""} onClick={() => void recordingAction()}><Icon name="record"/><span>{recording.active ? "Stop" : "Record"}</span></button>
          <button className={draft.frozen ? "is-active" : ""} onClick={() => patch("frozen", !draft.frozen)}><span className="snowflake">✦</span><span>Freeze</span></button>
          <button onClick={() => patch("rotation", (draft.rotation + 90) % 360)}><span className="rotate-symbol">↻</span><span>Rotate</span></button>
        </div>
      </section>

      <aside className="camera-controls glass-panel">
        <div className="panel-heading"><div><span>OPTICAL CONTROL</span><h2>{camera.label}</h2></div><span className={`connection-pill ${camera.online ? "is-online" : ""}`}>{camera.online ? "Connected" : "Offline"}</span></div>
        <StepControl label="Digital Zoom" value={draft.zoom} suffix="×" min={1} max={8} step={0.1} onChange={(value) => patch("zoom", value)}/>
        <StepControl label="Motor Focus" value={draft.focus} min={-100} max={100} step={1} onChange={(value) => patch("focus", value)}/>
        <StepControl label="Brightness" value={draft.brightness} min={0} max={100} step={1} onChange={(value) => patch("brightness", value)}/>
        <ToggleRow label="Automatic exposure" detail="Galaxy camera controls exposure and gain" value={draft.autoExposure} onChange={(value) => patch("autoExposure", value)}/>
        {!draft.autoExposure && <>
          <StepControl label="Exposure" value={Math.round(draft.exposureUs)} suffix=" μs" min={40} max={50000} step={100} onChange={(value) => patch("exposureUs", value)}/>
          <StepControl label="Gain" value={draft.gainDb} suffix=" dB" min={0} max={24} step={0.5} onChange={(value) => patch("gainDb", value)}/>
        </>}
        <div className="control-group"><label>White Balance</label><Segmented value={draft.whiteBalance} options={["Auto", "Warm", "Cool", "Manual"] as const} onChange={(value) => patch("whiteBalance", value)}/></div>
        <div className="control-group"><label>Image Enhance</label><Segmented value={draft.enhance} options={["Low", "Medium", "High"] as const} onChange={(value) => patch("enhance", value)}/></div>
      </aside>
    </div>);
}
