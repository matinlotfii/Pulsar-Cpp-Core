import type { HomeControlDefinition } from "../model";
import { HomeControlContent } from "./home-control-content";

export function HomeDragOverlay({ control }: { control: HomeControlDefinition | null }) {
  if (!control) return null;
  return (
    <div className={`home-drag-overlay home-launch-button tone-${control.tone}`} aria-hidden="true">
      <HomeControlContent control={control} />
    </div>
  );
}
