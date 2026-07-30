import React from "react";
import { api } from "../../api/client.js";
import { Icon } from "../../components/Icon.js";
import type { PulsarState } from "../../types.js";
const axes = ["Left Zoom", "Left Focus", "Left Iris", "Right Zoom", "Right Focus", "Right Iris"];
export function RoboticArm({ state, refresh }: {
    state: PulsarState;
    refresh: () => Promise<void>;
}) {
    const move = async (index: number, delta: number) => { const current = state.robot.motors[index] ?? 0; await api.robot({ [`motor${index}`]: current + delta }); await refresh(); };
    return <div className="robot-page page-enter">
    <section className="robot-visual glass-panel"><div className="robot-glow"/><div className="robot-arm"><div className="arm-base"/><div className="joint joint-a"/><div className="arm-segment segment-a"/><div className="joint joint-b"/><div className="arm-segment segment-b"/><div className="joint joint-c"/><div className="camera-head"><span /><span /></div></div><div className="robot-copy"><span className="eyebrow">MOTION CONTROLLER</span><h2>Six synchronized axes</h2><p>Commands are sent to the native C++ core. The transport layer is isolated so the final STM32/RS‑485 protocol can be added inside the camera/core folders without changing this UI.</p></div></section>
    <section className="motor-grid">{axes.map((axis, index) => <article className="motor-card glass-panel" key={axis}><div className="motor-card-title"><Icon name="robot"/><span><strong>{axis}</strong><small>Motor {index + 1}</small></span></div><div className="motor-position">{state.robot.motors[index] ?? 0}<small>steps</small></div><div className="motor-actions"><button onClick={() => void move(index, -10)}>−10</button><button onClick={() => void move(index, -1)}>−1</button><button onClick={() => void move(index, 1)}>+1</button><button onClick={() => void move(index, 10)}>+10</button></div></article>)}</section>
  </div>;
}
