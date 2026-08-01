import { HomePulsarCore } from "../home-core";
import type { ExactPageId, HomeControlDefinition } from "../model";
import { SortableHomeControlButton } from "./home-control-button";

export function HomeCommandLayout({
  controls,
  activeControl,
  onOpen,
  touchOptimized
}: {
  controls: HomeControlDefinition[];
  activeControl: HomeControlDefinition | null;
  onOpen: (page: ExactPageId) => void;
  touchOptimized: boolean;
}) {
  return (
    <div className={`home-command-layout ${activeControl ? "is-reordering" : ""}`} aria-label="Home controls">
      <div className="home-launch-column home-launch-column-left">
        {controls.slice(0, 5).map((control, index) => (
          <SortableHomeControlButton key={control.id} control={control} index={index} onOpen={onOpen} sortable={!touchOptimized} />
        ))}
      </div>
      <HomePulsarCore />
      <div className="home-launch-column home-launch-column-right">
        {controls.slice(5).map((control, index) => (
          <SortableHomeControlButton key={control.id} control={control} index={index + 5} onOpen={onOpen} sortable={!touchOptimized} />
        ))}
      </div>
    </div>
  );
}
