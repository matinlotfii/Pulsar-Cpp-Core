import React from "react";
import { useCallback, useEffect, useState } from "react";
import { Header } from "./components/Header.js";
import { Icon } from "./components/Icon.js";
import { LoadingScreen } from "./components/LoadingScreen.js";
import { usePulsarState } from "./hooks/usePulsarState.js";
import { Home } from "./pages/Home/Home.js";
import { LeftCamera } from "./pages/LeftCamera/LeftCamera.js";
import { RightCamera } from "./pages/RightCamera/RightCamera.js";
import { Stereo3D } from "./pages/Stereo3D/Stereo3D.js";
import { DisplaySettings } from "./pages/DisplaySettings/DisplaySettings.js";
import { Recording } from "./pages/Recording/Recording.js";
import { RoboticArm } from "./pages/RoboticArm/RoboticArm.js";
import { Pedals } from "./pages/Pedals/Pedals.js";
import { System } from "./pages/System/System.js";
const pages = [
    { id: "home", title: "Home", icon: "home" },
    { id: "left-camera", title: "Left Camera", icon: "camera" },
    { id: "right-camera", title: "Right Camera", icon: "camera" },
    { id: "stereo-3d", title: "Stereo 3D", icon: "stereo" },
    { id: "display-settings", title: "Display Settings", icon: "display" },
    { id: "recording", title: "Recording", icon: "record" },
    { id: "robotic-arm", title: "Robotic Arm", icon: "robot" },
    { id: "pedals", title: "Pedals", icon: "pedal" },
    { id: "system", title: "System", icon: "system" },
];
function initialPage() {
    const page = new URLSearchParams(window.location.search).get("page");
    return pages.some((entry) => entry.id === page) ? page : "home";
}
export default function App() {
    const [page, setPage] = useState(initialPage);
    const { state, error, refresh } = usePulsarState();
    const navigate = useCallback((next) => {
        setPage(next);
        const url = next === "home" ? window.location.pathname : `${window.location.pathname}?page=${next}`;
        window.history.pushState({ page: next }, "", url);
    }, []);
    useEffect(() => {
        const onPop = () => setPage(initialPage());
        window.addEventListener("popstate", onPop);
        return () => window.removeEventListener("popstate", onPop);
    }, []);
    if (!state)
        return React.createElement(LoadingScreen, { error: error });
    const current = pages.find((entry) => entry.id === page) ?? pages[0];
    const content = (() => {
        switch (page) {
            case "home": return React.createElement(Home, { state: state, navigate: navigate });
            case "left-camera": return React.createElement(LeftCamera, { state: state, refresh: refresh });
            case "right-camera": return React.createElement(RightCamera, { state: state, refresh: refresh });
            case "stereo-3d": return React.createElement(Stereo3D, { state: state, refresh: refresh });
            case "display-settings": return React.createElement(DisplaySettings, { state: state, refresh: refresh });
            case "recording": return React.createElement(Recording, { state: state, refresh: refresh });
            case "robotic-arm": return React.createElement(RoboticArm, { state: state, refresh: refresh });
            case "pedals": return React.createElement(Pedals, null);
            case "system": return React.createElement(System, { state: state, error: error });
        }
    })();
    return (React.createElement("div", { className: "app-shell" },
        React.createElement("aside", { className: "side-nav", "aria-label": "Main navigation" },
            React.createElement("div", { className: "nav-brand" }, "P"),
            React.createElement("nav", null, pages.map((entry) => React.createElement("button", { key: entry.id, title: entry.title, className: entry.id === page ? "is-active" : "", onClick: () => navigate(entry.id) },
                React.createElement(Icon, { name: entry.icon }),
                React.createElement("span", null, entry.title)))),
            React.createElement("div", { className: `core-indicator ${error ? "has-error" : ""}`, title: error || "C++ core online" },
                React.createElement("span", null))),
        React.createElement("div", { className: "app-main" },
            React.createElement(Header, { title: current.title, onBack: page === "home" ? undefined : () => navigate("home") }),
            React.createElement("main", { className: "content-shell" }, content))));
}
