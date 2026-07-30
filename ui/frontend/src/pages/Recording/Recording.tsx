import React from "react";
import { useState } from "react";
import { api } from "../../api/client.js";
import { CameraPreview } from "../../components/CameraPreview.js";
import { Icon } from "../../components/Icon.js";
import type { PulsarState } from "../../types.js";
function formatTime(seconds: number) { const h = Math.floor(seconds / 3600); const m = Math.floor((seconds % 3600) / 60); const s = seconds % 60; return [h, m, s].map((v) => String(v).padStart(2, "0")).join(":"); }
export function Recording({ state, refresh }: {
    state: PulsarState;
    refresh: () => Promise<void>;
}) {
    const [message, setMessage] = useState("");
    const toggle = async () => { if (state.recording.active)
        await api.stopRecording();
    else
        await api.startRecording(); await refresh(); };
    const snapshot = async () => { const result = await api.snapshot(); setMessage(result.file ? `Saved: ${result.file}` : "Snapshot failed"); window.setTimeout(() => setMessage(""), 3500); };
    return <div className="recording-page page-enter">
    <section className="recording-preview glass-panel"><div className="recording-sbs"><CameraPreview index={0} online={state.cameras[0].online} label="Left"/><CameraPreview index={1} online={state.cameras[1].online} label="Right"/></div><div className="record-overlay"><span className={state.recording.active ? "record-pulse" : ""}/> <b>{state.recording.active ? "REC" : "READY"}</b><time>{formatTime(state.recording.elapsedSeconds)}</time></div></section>
    <aside className="recording-controls glass-panel"><span className="eyebrow">CAPTURE ENGINE</span><h2>Procedure recording</h2><div className="record-clock">{formatTime(state.recording.elapsedSeconds)}</div><button className={`record-main-button ${state.recording.active ? "is-recording" : ""}`} onClick={() => void toggle()}><Icon name="record"/><span>{state.recording.active ? "Stop Recording" : "Start Recording"}</span></button><button className="secondary-action" onClick={() => void snapshot()}><Icon name="camera"/><span>Save SBS Snapshot</span></button><div className="record-info"><span>Encoding</span><b>H.264 · 1280×360 · 30 fps</b><span>Latest file</span><b>{state.recording.lastFile || "No recording yet"}</b></div>{message && <div className="toast-message">{message}</div>}</aside>
  </div>;
}
