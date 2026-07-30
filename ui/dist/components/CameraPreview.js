import React from "react";
export function CameraPreview({ index, online, label, compact = false }) {
    return (React.createElement("div", { className: `camera-preview ${compact ? "is-compact" : ""}` },
        React.createElement("img", { src: `/camera/${index}/stream.mjpg`, alt: `${label} live view`, draggable: false }),
        React.createElement("div", { className: `live-badge ${online ? "is-online" : ""}` },
            React.createElement("span", null),
            online ? "LIVE" : "WAITING"),
        React.createElement("div", { className: "camera-caption" }, label)));
}
