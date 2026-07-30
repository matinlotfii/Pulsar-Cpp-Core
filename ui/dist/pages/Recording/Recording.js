import React from "react";
import { useState } from "react";
import { api } from "../../api/client.js";
import { CameraPreview } from "../../components/CameraPreview.js";
import { Icon } from "../../components/Icon.js";
function formatTime(seconds) { const h = Math.floor(seconds / 3600); const m = Math.floor((seconds % 3600) / 60); const s = seconds % 60; return [h, m, s].map((v) => String(v).padStart(2, "0")).join(":"); }
export function Recording({ state, refresh }) {
    const [message, setMessage] = useState("");
    const toggle = async () => {
        if (state.recording.active)
            await api.stopRecording();
        else
            await api.startRecording();
        await refresh();
    };
    const snapshot = async () => { const result = await api.snapshot(); setMessage(result.file ? `Saved: ${result.file}` : "Snapshot failed"); window.setTimeout(() => setMessage(""), 3500); };
    return React.createElement("div", { className: "recording-page page-enter" },
        React.createElement("section", { className: "recording-preview glass-panel" },
            React.createElement("div", { className: "recording-sbs" },
                React.createElement(CameraPreview, { index: 0, online: state.cameras[0].online, label: "Left" }),
                React.createElement(CameraPreview, { index: 1, online: state.cameras[1].online, label: "Right" })),
            React.createElement("div", { className: "record-overlay" },
                React.createElement("span", { className: state.recording.active ? "record-pulse" : "" }),
                " ",
                React.createElement("b", null, state.recording.active ? "REC" : "READY"),
                React.createElement("time", null, formatTime(state.recording.elapsedSeconds)))),
        React.createElement("aside", { className: "recording-controls glass-panel" },
            React.createElement("span", { className: "eyebrow" }, "CAPTURE ENGINE"),
            React.createElement("h2", null, "Procedure recording"),
            React.createElement("div", { className: "record-clock" }, formatTime(state.recording.elapsedSeconds)),
            React.createElement("button", { className: `record-main-button ${state.recording.active ? "is-recording" : ""}`, onClick: () => void toggle() },
                React.createElement(Icon, { name: "record" }),
                React.createElement("span", null, state.recording.active ? "Stop Recording" : "Start Recording")),
            React.createElement("button", { className: "secondary-action", onClick: () => void snapshot() },
                React.createElement(Icon, { name: "camera" }),
                React.createElement("span", null, "Save SBS Snapshot")),
            React.createElement("div", { className: "record-info" },
                React.createElement("span", null, "Encoding"),
                React.createElement("b", null, "H.264 \u00B7 1280\u00D7360 \u00B7 30 fps"),
                React.createElement("span", null, "Latest file"),
                React.createElement("b", null, state.recording.lastFile || "No recording yet")),
            message && React.createElement("div", { className: "toast-message" }, message)));
}
