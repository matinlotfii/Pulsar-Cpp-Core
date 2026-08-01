import { ChevronRight } from "lucide-react";
import type { ReactNode } from "react";
import { Button as AriaButton } from "react-aria-components";
import type { PedalGesture, PedalMap, PedalSide } from "../model";

export function PedalsScreen({
  header,
  selectedPedal,
  mappings,
  onSelectPedal,
  onCycleMapping,
  onCustomize
}: {
  header: ReactNode;
  selectedPedal: PedalSide;
  mappings: PedalMap;
  onSelectPedal: (side: PedalSide) => void;
  onCycleMapping: (gesture: PedalGesture) => void;
  onCustomize: () => void;
}) {
  return (
    <div className="hmi-screen pedals-screen">
      {header}
      <main className="pedals-layout">
        <section className="pedal-visual-panel">
          <div className="segmented">
            <button type="button" className={selectedPedal === "left" ? "is-active" : ""} onClick={() => onSelectPedal("left")}>Pedal Left</button>
            <button type="button" className={selectedPedal === "right" ? "is-active" : ""} onClick={() => onSelectPedal("right")}>Pedal Right</button>
          </div>
          <div className="pedal-graphic" aria-hidden="true">
            <span className="pedal-base" />
            <span className="pedal-left" />
            <span className="pedal-right" />
            <span className="pedal-button b1" />
            <span className="pedal-button b2" />
            <span className="pedal-led" />
          </div>
          <span className="battery-note">▰ Battery: 100%</span>
        </section>

        <section className="pedal-map-panel">
          {(Object.keys(mappings) as PedalGesture[]).map((gesture) => (
            <AriaButton className="quick-link" key={gesture} aria-label={`${gesture}: ${mappings[gesture]}`} onPress={() => onCycleMapping(gesture)}>
              <span>{gesture}</span><strong>{mappings[gesture]}</strong><ChevronRight size={20} />
            </AriaButton>
          ))}
          <AriaButton className="recordings-button" onPress={onCustomize}>Customize</AriaButton>
        </section>
      </main>
    </div>
  );
}
