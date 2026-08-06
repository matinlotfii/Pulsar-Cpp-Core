import { ChevronRight, Glasses, Monitor, Tablet, type LucideIcon } from "lucide-react";
import type { ReactNode } from "react";
import { Button as AriaButton } from "react-aria-components";
import type { DisplayEndpointId, DisplayMode, HmiControlState } from "../model";

const displayIconMap: Record<string, LucideIcon> = {
  Glasses,
  Monitor,
  Tablet
};

export function DisplayScreen({
  header,
  state,
  onSelectDisplay,
  onDisplayMode,
  onDisplayValue,
  onAudioSourceCycle
}: {
  header: ReactNode;
  state: HmiControlState;
  onSelectDisplay: (id: DisplayEndpointId) => void;
  onDisplayMode: (id: DisplayEndpointId, mode: DisplayMode) => void;
  onDisplayValue: (id: DisplayEndpointId, field: "brightness" | "volume", value: number) => void;
  onAudioSourceCycle: () => void;
}) {
  const activeDisplay = state.displays[state.activeDisplay];

  return (
    <div className="hmi-screen display-screen">
      {header}
      <main className="display-layout">
        <section className="display-list">
          {Object.values(state.displays).map((display) => {
            const Icon = displayIconMap[display.icon];
            return (
              <AriaButton className={`display-item ${state.activeDisplay === display.id ? "is-active" : ""}`} key={display.id} onPress={() => onSelectDisplay(display.id)}>
                <Icon size={30} />
                <span>{display.label}<small>{display.active ? `${display.mode} Active` : "Standby"}</small></span>
              </AriaButton>
            );
          })}
        </section>

        <section className="display-detail">
          <h2>{activeDisplay.label}</h2>
          <div className="segmented">
            <button type="button" className={activeDisplay.mode === "2D" ? "is-active" : ""} onClick={() => onDisplayMode(activeDisplay.id, "2D")}>2D</button>
            <button type="button" className={activeDisplay.mode === "3D" ? "is-active" : ""} onClick={() => onDisplayMode(activeDisplay.id, "3D")}>3D</button>
          </div>
          <label>Brightness <strong>{activeDisplay.brightness}</strong></label>
          <input type="range" min="0" max="100" value={activeDisplay.brightness} aria-label="Brightness" onChange={(event) => onDisplayValue(activeDisplay.id, "brightness", Number(event.currentTarget.value))} />
          <label>Volume <strong>{activeDisplay.volume}</strong></label>
          <input type="range" min="0" max="100" value={activeDisplay.volume} aria-label="Volume" onChange={(event) => onDisplayValue(activeDisplay.id, "volume", Number(event.currentTarget.value))} />
          <AriaButton className="quick-link" aria-label="Audio Source" onPress={onAudioSourceCycle}><span>Audio Source</span><strong>{state.audioSource}</strong><ChevronRight size={22} /></AriaButton>
          <div className="display-detail-output">Output locked to {activeDisplay.label}. Touch routing stays on Touch LCD.</div>
        </section>
      </main>
    </div>
  );
}
