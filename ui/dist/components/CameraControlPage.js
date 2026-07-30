import React from "react";
import { useEffect, useRef, useState } from "react";
import { api } from "../api/client.js";
import { CameraPreview } from "./CameraPreview.js";
import { Segmented, StepControl, ToggleRow } from "./ControlRow.js";
import { Icon } from "./Icon.js";
export function CameraControlPage({ camera, recording, refresh }) {
    const index = camera.index;
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
    const patch = (key, value) => setDraft((current) => ({ ...current, [key]: value }));
    const recordingAction = async () => {
        if (recording.active)
            await api.stopRecording();
        else
            await api.startRecording();
        await refresh();
    };
    return (React.createElement("div", { className: "camera-page-grid page-enter" },
        React.createElement("section", { className: "camera-stage glass-panel" },
            React.createElement(CameraPreview, { index: index, online: camera.online, label: camera.label }),
            React.createElement("div", { className: "camera-meta" },
                React.createElement("span", null,
                    camera.width || "—",
                    " \u00D7 ",
                    camera.height || "—"),
                React.createElement("span", null,
                    camera.fps.toFixed(1),
                    " fps"),
                React.createElement("span", null, camera.model || "Daheng Galaxy")),
            React.createElement("div", { className: "camera-actions" },
                React.createElement("button", { onClick: () => void api.snapshot() },
                    React.createElement(Icon, { name: "camera" }),
                    React.createElement("span", null, "Snapshot")),
                React.createElement("button", { className: recording.active ? "is-danger" : "", onClick: () => void recordingAction() },
                    React.createElement(Icon, { name: "record" }),
                    React.createElement("span", null, recording.active ? "Stop" : "Record")),
                React.createElement("button", { className: draft.frozen ? "is-active" : "", onClick: () => patch("frozen", !draft.frozen) },
                    React.createElement("span", { className: "snowflake" }, "\u2726"),
                    React.createElement("span", null, "Freeze")),
                React.createElement("button", { onClick: () => patch("rotation", (draft.rotation + 90) % 360) },
                    React.createElement("span", { className: "rotate-symbol" }, "\u21BB"),
                    React.createElement("span", null, "Rotate")))),
        React.createElement("aside", { className: "camera-controls glass-panel" },
            React.createElement("div", { className: "panel-heading" },
                React.createElement("div", null,
                    React.createElement("span", null, "OPTICAL CONTROL"),
                    React.createElement("h2", null, camera.label)),
                React.createElement("span", { className: `connection-pill ${camera.online ? "is-online" : ""}` }, camera.online ? "Connected" : "Offline")),
            React.createElement(StepControl, { label: "Digital Zoom", value: draft.zoom, suffix: "\u00D7", min: 1, max: 8, step: 0.1, onChange: (value) => patch("zoom", value) }),
            React.createElement(StepControl, { label: "Motor Focus", value: draft.focus, min: -100, max: 100, step: 1, onChange: (value) => patch("focus", value) }),
            React.createElement(StepControl, { label: "Brightness", value: draft.brightness, min: 0, max: 100, step: 1, onChange: (value) => patch("brightness", value) }),
            React.createElement(ToggleRow, { label: "Automatic exposure", detail: "Galaxy camera controls exposure and gain", value: draft.autoExposure, onChange: (value) => patch("autoExposure", value) }),
            !draft.autoExposure && React.createElement(React.Fragment, null,
                React.createElement(StepControl, { label: "Exposure", value: Math.round(draft.exposureUs), suffix: " \u03BCs", min: 40, max: 50000, step: 100, onChange: (value) => patch("exposureUs", value) }),
                React.createElement(StepControl, { label: "Gain", value: draft.gainDb, suffix: " dB", min: 0, max: 24, step: 0.5, onChange: (value) => patch("gainDb", value) })),
            React.createElement("div", { className: "control-group" },
                React.createElement("label", null, "White Balance"),
                React.createElement(Segmented, { value: draft.whiteBalance, options: ["Auto", "Warm", "Cool", "Manual"], onChange: (value) => patch("whiteBalance", value) })),
            React.createElement("div", { className: "control-group" },
                React.createElement("label", null, "Image Enhance"),
                React.createElement(Segmented, { value: draft.enhance, options: ["Low", "Medium", "High"], onChange: (value) => patch("enhance", value) })))));
}
