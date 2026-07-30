import React from "react";
export function LoadingScreen({ error }) {
    return React.createElement("main", { className: "loading-screen" },
        React.createElement("div", { className: "loading-orbit" },
            React.createElement("span", null),
            React.createElement("span", null),
            React.createElement("span", null)),
        React.createElement("h1", null, "Pulsar C++ Core"),
        React.createElement("p", null, error || "Connecting to the real-time camera core…"));
}
