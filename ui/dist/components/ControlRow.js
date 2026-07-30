import React from "react";
import { Icon } from "./Icon.js";
export function StepControl({ label, value, suffix = "", onChange, min, max, step = 1 }) {
    const update = (delta) => onChange(Math.min(max, Math.max(min, Number((value + delta).toFixed(2)))));
    return (React.createElement("div", { className: "step-control" },
        React.createElement("div", null,
            React.createElement("span", null, label),
            React.createElement("strong", null,
                value,
                suffix)),
        React.createElement("div", { className: "step-actions" },
            React.createElement("button", { onClick: () => update(-step) },
                React.createElement(Icon, { name: "minus" })),
            React.createElement("input", { "aria-label": label, type: "range", min: min, max: max, step: step, value: value, onChange: (event) => onChange(Number(event.target.value)) }),
            React.createElement("button", { onClick: () => update(step) },
                React.createElement(Icon, { name: "plus" })))));
}
export function ToggleRow({ label, detail, value, onChange }) {
    return React.createElement("label", { className: "toggle-row" },
        React.createElement("span", null,
            React.createElement("strong", null, label),
            detail && React.createElement("small", null, detail)),
        React.createElement("input", { type: "checkbox", checked: value, onChange: (event) => onChange(event.target.checked) }),
        React.createElement("i", null));
}
export function Segmented({ value, options, onChange }) {
    return React.createElement("div", { className: "segmented" }, options.map((option) => React.createElement("button", { key: option, className: option === value ? "is-active" : "", onClick: () => onChange(option) }, option)));
}
