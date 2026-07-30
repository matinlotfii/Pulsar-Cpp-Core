import React from "react";
import type { PageId, PulsarState } from "../../types.js";
import { CameraPreview } from "../../components/CameraPreview.js";
import { Icon } from "../../components/Icon.js";
const tiles: Array<{
    id: PageId;
    icon: string;
    title: string;
    detail: string;
    tone: string;
}> = [
    { id: "stereo-3d", icon: "stereo", title: "3D (SBS)", detail: "Main display", tone: "violet" },
    { id: "recording", icon: "record", title: "Recording", detail: "Video & snapshots", tone: "red" },
    { id: "robotic-arm", icon: "robot", title: "Robotic Arm", detail: "Six motor axes", tone: "cyan" },
    { id: "display-settings", icon: "display", title: "Display", detail: "Routing & alignment", tone: "blue" },
    { id: "pedals", icon: "pedal", title: "Pedals", detail: "Foot controls", tone: "amber" },
    { id: "system", icon: "system", title: "System", detail: "Core health", tone: "slate" },
];
export function Home({ state, navigate }: {
    state: PulsarState;
    navigate: (page: PageId) => void;
}) {
    return (<div className="home-page page-enter">
      <section className="welcome-card glass-panel">
        <div><span className="eyebrow">READY FOR PROCEDURE</span><h1>Precision vision,<br />without delay.</h1><p>Native C++ camera acquisition drives the large SBS display while this touch UI controls every live setting.</p></div>
        <div className="core-orbit"><span className="orbit orbit-one"/><span className="orbit orbit-two"/><span className="core-dot">P</span></div>
      </section>

      <section className="home-cameras">
        {state.cameras.map((camera, index) => (<button className="camera-launch glass-panel" key={camera.index} onClick={() => navigate(index === 0 ? "left-camera" : "right-camera")}>
            <CameraPreview index={index as 0 | 1} online={camera.online} label={camera.label} compact/>
            <div className="camera-launch-copy"><span>{camera.online ? "LIVE VIEW" : "CONNECTING"}</span><strong>{camera.label}</strong><small>{camera.fps.toFixed(1)} fps · {camera.model || "Galaxy SDK"}</small></div>
          </button>))}
      </section>

      <section className="home-tiles">
        {tiles.map((tile) => <button className={`feature-tile glass-panel tone-${tile.tone}`} key={tile.id} onClick={() => navigate(tile.id)}><span className="feature-icon"><Icon name={tile.icon}/></span><span><strong>{tile.title}</strong><small>{tile.detail}</small></span><b>›</b></button>)}
      </section>
    </div>);
}
