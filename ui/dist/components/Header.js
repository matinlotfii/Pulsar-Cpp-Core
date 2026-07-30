import React from "react";
import { useEffect, useState } from "react";
import { Icon } from "./Icon.js";
export function Header({ title, onBack }) {
    const [time, setTime] = useState(new Date());
    useEffect(() => {
        const timer = window.setInterval(() => setTime(new Date()), 1000);
        return () => window.clearInterval(timer);
    }, []);
    return (React.createElement("header", { className: "top-header" },
        React.createElement("div", { className: "header-title" },
            onBack ? React.createElement("button", { className: "icon-button", onClick: onBack, "aria-label": "Back" },
                React.createElement(Icon, { name: "back" })) : React.createElement("div", { className: "pulsar-mark" }, "P"),
            React.createElement("div", null,
                React.createElement("span", { className: "header-kicker" }, "PULSAR EXOSCOPE"),
                React.createElement("strong", null, title))),
        React.createElement("div", { className: "header-status" },
            React.createElement("span", { className: "status-dot" }),
            React.createElement(Icon, { name: "wifi" }),
            React.createElement("time", null, time.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })))));
}
