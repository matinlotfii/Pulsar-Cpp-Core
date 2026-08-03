import { Glasses, Monitor, Volume2, VolumeX, type LucideIcon } from "lucide-react";
import type { ReactNode } from "react";
import { Button as AriaButton } from "react-aria-components";
import type { DisplayEndpointId, DisplayMode, HmiControlState } from "../model";

const displayIconMap: Record<string, LucideIcon> = {
  Glasses,
  Monitor
};

export function DisplayScreen({
  header,
  state,
  onSelectDisplay,
  onDisplayMode,
  onDisplayVolume,
  onDisplayMuteToggle
}: {
  header: ReactNode;
  state: HmiControlState;
  onSelectDisplay: (id: DisplayEndpointId) => void;
  onDisplayMode: (id: DisplayEndpointId, mode: DisplayMode) => void;
  onDisplayVolume: (id: DisplayEndpointId, value: number) => void;
  onDisplayMuteToggle: (id: DisplayEndpointId) => void;
}) {
  const allDisplays = Object.values(state.displays);
  const connectedDisplays = allDisplays.filter((display) => display.connected);
  const activeDisplay = state.displays[state.activeDisplay]?.connected
    ? state.displays[state.activeDisplay]
    : (connectedDisplays[0] ?? null);

  return (
    <div className="hmi-screen display-screen">
      {header}
      <main className="display-layout">
        <section className="display-list">
          {allDisplays.map((display) => {
            const Icon = displayIconMap[display.icon] ?? Monitor;
            return (
              <AriaButton
                className={`display-item ${activeDisplay?.id === display.id ? "is-active" : ""} ${display.connected ? "is-connected" : "is-disconnected"}`}
                key={display.id}
                onPress={() => {
                  if (!display.connected) return;
                  onSelectDisplay(display.id);
                }}
                isDisabled={!display.connected}
              >
                <span className={`display-status-dot ${display.connected ? "is-connected" : "is-disconnected"}`} aria-hidden="true" />
                <Icon size={28} />
                <div className="display-item-copy">
                  <span>{display.label}</span>
                  <small>{display.connected ? display.connector : "Not connected"}</small>
                </div>
              </AriaButton>
            );
          })}
        </section>

        <section className="display-detail">
          {!activeDisplay ? (
            <div className="display-empty display-empty-detail">Connect a display or AR output to open settings.</div>
          ) : (
            <>
              <h2>{activeDisplay.label}</h2>
              <small className="display-detail-connector">{activeDisplay.connector}</small>

              <div className="segmented">
                <button type="button" className={activeDisplay.mode === "2D" ? "is-active" : ""} onClick={() => onDisplayMode(activeDisplay.id, "2D")}>2D</button>
                <button type="button" className={activeDisplay.mode === "3D" ? "is-active" : ""} onClick={() => onDisplayMode(activeDisplay.id, "3D")}>3D</button>
              </div>

              <div className="display-volume-card">
                <div className="display-volume-row">
                  <button type="button" className={`display-mute-button ${activeDisplay.muted ? "is-muted" : ""}`} onClick={() => onDisplayMuteToggle(activeDisplay.id)} aria-label={activeDisplay.muted ? "Unmute output" : "Mute output"}>
                    {activeDisplay.muted ? <VolumeX size={18} /> : <Volume2 size={18} />}
                  </button>
                  <input
                    type="range"
                    min="0"
                    max="125"
                    value={activeDisplay.volume}
                    aria-label="Output volume"
                    onChange={(event) => onDisplayVolume(activeDisplay.id, Number(event.currentTarget.value))}
                  />
                  <strong>{activeDisplay.volume}</strong>
                </div>
              </div>
            </>
          )}
        </section>
      </main>
    </div>
  );
}
