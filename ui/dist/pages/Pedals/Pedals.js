import React from "react";
import { useState } from "react";
import { Icon } from "../../components/Icon.js";
const actions = ["Snapshot", "Record", "Freeze", "Zoom In", "Zoom Out", "Focus Near", "Focus Far"];
const gestures = ["Left Short Press", "Left Long Press", "Left Double Press", "Right Short Press", "Right Long Press", "Right Double Press"];
export function Pedals() {
    const [mapping, setMapping] = useState(["Snapshot", "Freeze", "Zoom Out", "Record", "Zoom In", "Focus Near"]);
    return React.createElement("div", { className: "pedals-page page-enter" },
        React.createElement("section", { className: "pedal-visual glass-panel" },
            React.createElement("div", { className: "pedal-stage" },
                React.createElement("div", { className: "pedal left" },
                    React.createElement(Icon, { name: "pedal" }),
                    React.createElement("span", null, "LEFT")),
                React.createElement("div", { className: "pedal right" },
                    React.createElement(Icon, { name: "pedal" }),
                    React.createElement("span", null, "RIGHT"))),
            React.createElement("span", { className: "eyebrow" }, "FOOT CONTROL"),
            React.createElement("h2", null, "Hands-free actions"),
            React.createElement("p", null, "Mappings are separated in their own page and stylesheet, ready to be connected to the final USB or GPIO pedal input module in the C++ core.")),
        React.createElement("section", { className: "pedal-map glass-panel" },
            React.createElement("div", { className: "pedal-map-header" },
                React.createElement("div", null,
                    React.createElement("span", { className: "eyebrow" }, "GESTURE MAP"),
                    React.createElement("h2", null, "Pedal assignments")),
                React.createElement("button", { onClick: () => setMapping(["Snapshot", "Freeze", "Zoom Out", "Record", "Zoom In", "Focus Near"]) }, "Reset")),
            gestures.map((gesture, index) => React.createElement("label", { className: "pedal-row", key: gesture },
                React.createElement("span", null,
                    React.createElement("b", null, gesture),
                    React.createElement("small", null, index < 3 ? "Left pedal" : "Right pedal")),
                React.createElement("select", { value: mapping[index], onChange: (event) => setMapping((current) => current.map((value, i) => i === index ? event.target.value : value)) }, actions.map((action) => React.createElement("option", { key: action }, action)))))));
}
