import React from "react";
export function CameraPreview({ index, online, label, compact = false }: {
    index: 0 | 1;
    online: boolean;
    label: string;
    compact?: boolean;
}) {
    return (<div className={`camera-preview ${compact ? "is-compact" : ""}`}>
      <img src={`/camera/${index}/stream.mjpg`} alt={`${label} live view`} draggable={false}/>
      <div className={`live-badge ${online ? "is-online" : ""}`}><span />{online ? "LIVE" : "WAITING"}</div>
      <div className="camera-caption">{label}</div>
    </div>);
}
