import React from "react";
import { api } from "../../api/client.js";
import { Segmented, StepControl, ToggleRow } from "../../components/ControlRow.js";
import type { PulsarState } from "../../types.js";
export function DisplaySettings({ state, refresh }: {
    state: PulsarState;
    refresh: () => Promise<void>;
}) {
    const update = async (patch: Parameters<typeof api.display>[0]) => { await api.display(patch); await refresh(); };
    return <div className="display-page page-enter">
    <section className="display-map glass-panel">
      <div className="display-map-title"><span className="eyebrow">OUTPUT ROUTING</span><h2>Two-screen topology</h2></div>
      <div className="screen-diagram">
        <div className="screen-node settings-screen"><small>SMALL TOUCH DISPLAY</small><strong>Control UI</strong><span>React · TSX · CSS</span></div>
        <div className="flow-line"><i /><i /><i /></div>
        <div className="core-node"><b>P</b><strong>C++ Core</strong><span>Shared settings</span></div>
        <div className="flow-line"><i /><i /><i /></div>
        <div className="screen-node main-screen"><small>LARGE MAIN DISPLAY</small><strong>Native SBS</strong><span>SDL2 · GPU path</span></div>
      </div>
      <div className="display-facts"><div><span>Camera transport</span><b>Galaxy SDK / USB3</b></div><div><span>Memory policy</span><b>Latest frame only</b></div><div><span>Network exposure</span><b>Loopback only</b></div></div>
    </section>
    <aside className="display-options glass-panel">
      <span className="eyebrow">DISPLAY SETTINGS</span><h2>Live output</h2>
      <div className="control-group"><label>Stereo format</label><Segmented value={state.display.stereoMode} options={["SBS", "LineInterleaved"] as const} onChange={(value) => void update({ stereoMode: value })}/></div>
      <ToggleRow label="Swap eye order" detail="Useful when HDMI routing is reversed" value={state.display.swapEyes} onChange={(value) => void update({ swapEyes: value })}/>
      <ToggleRow label="Mirror left" value={state.display.mirrorLeft} onChange={(value) => void update({ mirrorLeft: value })}/>
      <ToggleRow label="Mirror right" value={state.display.mirrorRight} onChange={(value) => void update({ mirrorRight: value })}/>
      <StepControl label="Image separation" value={state.display.gapPx} suffix=" px" min={0} max={200} step={2} onChange={(value) => void update({ gapPx: value })}/>
      <StepControl label="Refresh target" value={state.display.targetFps} suffix=" Hz" min={24} max={120} step={6} onChange={(value) => void update({ targetFps: value })}/>
    </aside>
  </div>;
}
