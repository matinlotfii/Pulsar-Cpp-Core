import React from "react";
import { CameraPreview } from "../../components/CameraPreview.js";
import { Icon } from "../../components/Icon.js";
const tiles = [
    { id: "stereo-3d", icon: "stereo", title: "3D (SBS)", detail: "Main display", tone: "violet" },
    { id: "recording", icon: "record", title: "Recording", detail: "Video & snapshots", tone: "red" },
    { id: "robotic-arm", icon: "robot", title: "Robotic Arm", detail: "Six motor axes", tone: "cyan" },
    { id: "display-settings", icon: "display", title: "Display", detail: "Routing & alignment", tone: "blue" },
    { id: "pedals", icon: "pedal", title: "Pedals", detail: "Foot controls", tone: "amber" },
    { id: "system", icon: "system", title: "System", detail: "Core health", tone: "slate" },
];
export function Home({ state, navigate }) {
    return (React.createElement("div", { className: "home-page page-enter" },
        React.createElement("section", { className: "welcome-card glass-panel" },
            React.createElement("div", null,
                React.createElement("span", { className: "eyebrow" }, "READY FOR PROCEDURE"),
                React.createElement("h1", null,
                    "Precision vision,",
                    React.createElement("br", null),
                    "without delay."),
                React.createElement("p", null, "Native C++ camera acquisition drives the large SBS display while this touch UI controls every live setting.")),
            React.createElement("div", { className: "core-orbit" },
                React.createElement("span", { className: "orbit orbit-one" }),
                React.createElement("span", { className: "orbit orbit-two" }),
                React.createElement("span", { className: "core-dot" }, "P"))),
        React.createElement("section", { className: "home-cameras" }, state.cameras.map((camera, index) => (React.createElement("button", { className: "camera-launch glass-panel", key: camera.index, onClick: () => navigate(index === 0 ? "left-camera" : "right-camera") },
            React.createElement(CameraPreview, { index: index, online: camera.online, label: camera.label, compact: true }),
            React.createElement("div", { className: "camera-launch-copy" },
                React.createElement("span", null, camera.online ? "LIVE VIEW" : "CONNECTING"),
                React.createElement("strong", null, camera.label),
                React.createElement("small", null,
                    camera.fps.toFixed(1),
                    " fps \u00B7 ",
                    camera.model || "Galaxy SDK")))))),
        React.createElement("section", { className: "home-tiles" }, tiles.map((tile) => React.createElement("button", { className: `feature-tile glass-panel tone-${tile.tone}`, key: tile.id, onClick: () => navigate(tile.id) },
            React.createElement("span", { className: "feature-icon" },
                React.createElement(Icon, { name: tile.icon })),
            React.createElement("span", null,
                React.createElement("strong", null, tile.title),
                React.createElement("small", null, tile.detail)),
            React.createElement("b", null, "\u203A"))))));
}
