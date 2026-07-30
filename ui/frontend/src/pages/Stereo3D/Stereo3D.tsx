import React from "react";
import { api } from "../../api/client.js";
import { CameraPreview } from "../../components/CameraPreview.js";
import { StepControl, ToggleRow } from "../../components/ControlRow.js";
import type { PulsarState } from "../../types.js";
export function Stereo3D({ state, refresh }: {
    state: PulsarState;
    refresh: () => Promise<void>;
}) {
    const update = async (patch: Parameters<typeof api.display>[0]) => { await api.display(patch); await refresh(); };
    const order = state.display.swapEyes ? [1, 0] as const : [0, 1] as const;
    return <div className="stereo-page page-enter">
    <section className="stereo-view glass-panel" style={{ gap: state.display.gapPx }}>
      {order.map((index) => <CameraPreview key={index} index={index} online={state.cameras[index].online} label={state.cameras[index].label}/>)}
      <div className="stereo-center-line"/>
    </section>
    <aside className="stereo-controls glass-panel">
      <span className="eyebrow">NATIVE MAIN OUTPUT</span><h2>Stereo SBS</h2><p>The large monitor is rendered directly by SDL2 in C++. These controls update it immediately without passing full-resolution frames through the browser.</p>
      <ToggleRow label="Swap left and right eyes" value={state.display.swapEyes} onChange={(value) => void update({ swapEyes: value })}/>
      <ToggleRow label="Mirror left camera" value={state.display.mirrorLeft} onChange={(value) => void update({ mirrorLeft: value })}/>
      <ToggleRow label="Mirror right camera" value={state.display.mirrorRight} onChange={(value) => void update({ mirrorRight: value })}/>
      <StepControl label="Center gap" value={state.display.gapPx} suffix=" px" min={0} max={200} step={2} onChange={(value) => void update({ gapPx: value })}/>
      <StepControl label="Display target" value={state.display.targetFps} suffix=" fps" min={24} max={120} step={6} onChange={(value) => void update({ targetFps: value })}/>
      <div className="stereo-health"><span className={state.cameras[0].online ? "ok" : ""}>L</span><b>{state.cameras[0].fps.toFixed(1)} fps</b><span className={state.cameras[1].online ? "ok" : ""}>R</span><b>{state.cameras[1].fps.toFixed(1)} fps</b></div>
    </aside>
  </div>;
}
