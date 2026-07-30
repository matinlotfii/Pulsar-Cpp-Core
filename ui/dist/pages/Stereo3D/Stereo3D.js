import React from "react";
import { api } from "../../api/client.js";
import { CameraPreview } from "../../components/CameraPreview.js";
import { StepControl, ToggleRow } from "../../components/ControlRow.js";
export function Stereo3D({ state, refresh }) {
    const update = async (patch) => { await api.display(patch); await refresh(); };
    const order = state.display.swapEyes ? [1, 0] : [0, 1];
    return React.createElement("div", { className: "stereo-page page-enter" },
        React.createElement("section", { className: "stereo-view glass-panel", style: { gap: state.display.gapPx } },
            order.map((index) => React.createElement(CameraPreview, { key: index, index: index, online: state.cameras[index].online, label: state.cameras[index].label })),
            React.createElement("div", { className: "stereo-center-line" })),
        React.createElement("aside", { className: "stereo-controls glass-panel" },
            React.createElement("span", { className: "eyebrow" }, "NATIVE MAIN OUTPUT"),
            React.createElement("h2", null, "Stereo SBS"),
            React.createElement("p", null, "The large monitor is rendered directly by SDL2 in C++. These controls update it immediately without passing full-resolution frames through the browser."),
            React.createElement(ToggleRow, { label: "Swap left and right eyes", value: state.display.swapEyes, onChange: (value) => void update({ swapEyes: value }) }),
            React.createElement(ToggleRow, { label: "Mirror left camera", value: state.display.mirrorLeft, onChange: (value) => void update({ mirrorLeft: value }) }),
            React.createElement(ToggleRow, { label: "Mirror right camera", value: state.display.mirrorRight, onChange: (value) => void update({ mirrorRight: value }) }),
            React.createElement(StepControl, { label: "Center gap", value: state.display.gapPx, suffix: " px", min: 0, max: 200, step: 2, onChange: (value) => void update({ gapPx: value }) }),
            React.createElement(StepControl, { label: "Display target", value: state.display.targetFps, suffix: " fps", min: 24, max: 120, step: 6, onChange: (value) => void update({ targetFps: value }) }),
            React.createElement("div", { className: "stereo-health" },
                React.createElement("span", { className: state.cameras[0].online ? "ok" : "" }, "L"),
                React.createElement("b", null,
                    state.cameras[0].fps.toFixed(1),
                    " fps"),
                React.createElement("span", { className: state.cameras[1].online ? "ok" : "" }, "R"),
                React.createElement("b", null,
                    state.cameras[1].fps.toFixed(1),
                    " fps"))));
}
