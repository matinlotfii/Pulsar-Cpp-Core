import React from "react";
import type { PulsarState } from "../../types.js";
function bytes(value: number) { if (value < 1024 * 1024)
    return `${Math.round(value / 1024)} KB`; return `${(value / 1024 / 1024).toFixed(1)} MB`; }
function duration(total: number) { const days = Math.floor(total / 86400); const hours = Math.floor((total % 86400) / 3600); const mins = Math.floor((total % 3600) / 60); return `${days}d ${hours}h ${mins}m`; }
export function System({ state, error }: {
    state: PulsarState;
    error: string;
}) {
    const metrics = [{ label: "Memory used", value: `${state.system.memoryUsedPercent.toFixed(1)}%`, detail: "System MemAvailable" }, { label: "Core RSS", value: bytes(state.system.processRssBytes), detail: "Bounded latest-frame buffers" }, { label: "CPU load", value: state.system.cpuLoad.toFixed(2), detail: "Linux 1-minute load" }, { label: "Uptime", value: duration(state.system.uptimeSeconds), detail: "Host operating time" }];
    return <div className="system-page page-enter"><section className="system-summary glass-panel"><div className="system-logo">P</div><div><span className="eyebrow">PULSAR C++ CORE</span><h2>Runtime healthy</h2><p>Version {state.system.version} · loopback API · fixed camera queues · native SBS renderer</p></div><span className={`system-health ${error ? "has-error" : ""}`}>{error || "ONLINE"}</span></section><section className="metrics-grid">{metrics.map((metric) => <article className="metric-card glass-panel" key={metric.label}><span>{metric.label}</span><strong>{metric.value}</strong><small>{metric.detail}</small><i style={{ width: metric.label === "Memory used" ? `${Math.min(state.system.memoryUsedPercent, 100)}%` : "55%" }}/></article>)}</section><section className="camera-system-grid">{state.cameras.map((camera) => <article className="system-camera glass-panel" key={camera.index}><div><span className={camera.online ? "online-dot" : "offline-dot"}/><strong>{camera.label}</strong></div><dl><dt>Status</dt><dd>{camera.online ? "Streaming" : "Offline"}</dd><dt>Model</dt><dd>{camera.model || "Waiting for Galaxy SDK"}</dd><dt>Serial</dt><dd>{camera.serial || "—"}</dd><dt>Resolution</dt><dd>{camera.width ? `${camera.width} × ${camera.height}` : "—"}</dd><dt>Frame rate</dt><dd>{camera.fps.toFixed(1)} fps</dd></dl>{camera.error && <p>{camera.error}</p>}</article>)}</section></div>;
}
