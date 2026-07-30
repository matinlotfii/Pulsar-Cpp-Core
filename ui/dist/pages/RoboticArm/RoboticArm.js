import React from "react";
import { api } from "../../api/client.js";
import { Icon } from "../../components/Icon.js";
const axes = ["Left Zoom", "Left Focus", "Left Iris", "Right Zoom", "Right Focus", "Right Iris"];
export function RoboticArm({ state, refresh }) {
    const move = async (index, delta) => { const current = state.robot.motors[index] ?? 0; await api.robot({ [`motor${index}`]: current + delta }); await refresh(); };
    return React.createElement("div", { className: "robot-page page-enter" },
        React.createElement("section", { className: "robot-visual glass-panel" },
            React.createElement("div", { className: "robot-glow" }),
            React.createElement("div", { className: "robot-arm" },
                React.createElement("div", { className: "arm-base" }),
                React.createElement("div", { className: "joint joint-a" }),
                React.createElement("div", { className: "arm-segment segment-a" }),
                React.createElement("div", { className: "joint joint-b" }),
                React.createElement("div", { className: "arm-segment segment-b" }),
                React.createElement("div", { className: "joint joint-c" }),
                React.createElement("div", { className: "camera-head" },
                    React.createElement("span", null),
                    React.createElement("span", null))),
            React.createElement("div", { className: "robot-copy" },
                React.createElement("span", { className: "eyebrow" }, "MOTION CONTROLLER"),
                React.createElement("h2", null, "Six synchronized axes"),
                React.createElement("p", null, "Commands are sent to the native C++ core. The transport layer is isolated so the final STM32/RS\u2011485 protocol can be added inside the camera/core folders without changing this UI."))),
        React.createElement("section", { className: "motor-grid" }, axes.map((axis, index) => React.createElement("article", { className: "motor-card glass-panel", key: axis },
            React.createElement("div", { className: "motor-card-title" },
                React.createElement(Icon, { name: "robot" }),
                React.createElement("span", null,
                    React.createElement("strong", null, axis),
                    React.createElement("small", null,
                        "Motor ",
                        index + 1))),
            React.createElement("div", { className: "motor-position" },
                state.robot.motors[index] ?? 0,
                React.createElement("small", null, "steps")),
            React.createElement("div", { className: "motor-actions" },
                React.createElement("button", { onClick: () => void move(index, -10) }, "\u221210"),
                React.createElement("button", { onClick: () => void move(index, -1) }, "\u22121"),
                React.createElement("button", { onClick: () => void move(index, 1) }, "+1"),
                React.createElement("button", { onClick: () => void move(index, 10) }, "+10"))))));
}
