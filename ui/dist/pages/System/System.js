import React from "react";
function bytes(value) {
    if (value < 1024 * 1024)
        return `${Math.round(value / 1024)} KB`;
    return `${(value / 1024 / 1024).toFixed(1)} MB`;
}
function duration(total) { const days = Math.floor(total / 86400); const hours = Math.floor((total % 86400) / 3600); const mins = Math.floor((total % 3600) / 60); return `${days}d ${hours}h ${mins}m`; }
export function System({ state, error }) {
    const metrics = [{ label: "Memory used", value: `${state.system.memoryUsedPercent.toFixed(1)}%`, detail: "System MemAvailable" }, { label: "Core RSS", value: bytes(state.system.processRssBytes), detail: "Bounded latest-frame buffers" }, { label: "CPU load", value: state.system.cpuLoad.toFixed(2), detail: "Linux 1-minute load" }, { label: "Uptime", value: duration(state.system.uptimeSeconds), detail: "Host operating time" }];
    return React.createElement("div", { className: "system-page page-enter" },
        React.createElement("section", { className: "system-summary glass-panel" },
            React.createElement("div", { className: "system-logo" }, "P"),
            React.createElement("div", null,
                React.createElement("span", { className: "eyebrow" }, "PULSAR C++ CORE"),
                React.createElement("h2", null, "Runtime healthy"),
                React.createElement("p", null,
                    "Version ",
                    state.system.version,
                    " \u00B7 loopback API \u00B7 fixed camera queues \u00B7 native SBS renderer")),
            React.createElement("span", { className: `system-health ${error ? "has-error" : ""}` }, error || "ONLINE")),
        React.createElement("section", { className: "metrics-grid" }, metrics.map((metric) => React.createElement("article", { className: "metric-card glass-panel", key: metric.label },
            React.createElement("span", null, metric.label),
            React.createElement("strong", null, metric.value),
            React.createElement("small", null, metric.detail),
            React.createElement("i", { style: { width: metric.label === "Memory used" ? `${Math.min(state.system.memoryUsedPercent, 100)}%` : "55%" } })))),
        React.createElement("section", { className: "camera-system-grid" }, state.cameras.map((camera) => React.createElement("article", { className: "system-camera glass-panel", key: camera.index },
            React.createElement("div", null,
                React.createElement("span", { className: camera.online ? "online-dot" : "offline-dot" }),
                React.createElement("strong", null, camera.label)),
            React.createElement("dl", null,
                React.createElement("dt", null, "Status"),
                React.createElement("dd", null, camera.online ? "Streaming" : "Offline"),
                React.createElement("dt", null, "Model"),
                React.createElement("dd", null, camera.model || "Waiting for Galaxy SDK"),
                React.createElement("dt", null, "Serial"),
                React.createElement("dd", null, camera.serial || "—"),
                React.createElement("dt", null, "Resolution"),
                React.createElement("dd", null, camera.width ? `${camera.width} × ${camera.height}` : "—"),
                React.createElement("dt", null, "Frame rate"),
                React.createElement("dd", null,
                    camera.fps.toFixed(1),
                    " fps")),
            camera.error && React.createElement("p", null, camera.error)))));
}
