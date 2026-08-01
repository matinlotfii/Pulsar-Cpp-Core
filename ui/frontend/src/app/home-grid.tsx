import {
  closestCenter,
  DndContext,
  DragOverlay,
  MouseSensor,
  TouchSensor,
  useSensor,
  useSensors,
  type DragEndEvent,
  type DragOverEvent,
  type DragStartEvent
} from "@dnd-kit/core";
import { arrayMove, rectSortingStrategy, SortableContext } from "@dnd-kit/sortable";
import type { ExactPageId, HomeControlDefinition } from "./model";
import { HomeCommandLayout } from "./home/home-command-layout";
import { HomeDragOverlay } from "./home/home-drag-overlay";

export function HomeControlGrid({
  controls,
  activeControl,
  onOpen,
  onDragStart,
  onDragOver,
  onDragCancel,
  onDragEnd
}: {
  controls: HomeControlDefinition[];
  activeControl: HomeControlDefinition | null;
  onOpen: (page: ExactPageId) => void;
  onDragStart: (event: DragStartEvent) => void;
  onDragOver: (event: DragOverEvent) => void;
  onDragCancel: () => void;
  onDragEnd: (event: DragEndEvent) => void;
}) {
  const touchOptimized = typeof navigator !== "undefined" && navigator.maxTouchPoints > 0;
  const sensors = useSensors(
    useSensor(MouseSensor, { activationConstraint: { distance: 6 } }),
    useSensor(TouchSensor, {
      activationConstraint: {
        delay: 180,
        tolerance: 10
      }
    })
  );

  return (
    <DndContext
      sensors={sensors}
      collisionDetection={closestCenter}
      onDragStart={onDragStart}
      onDragOver={onDragOver}
      onDragCancel={onDragCancel}
      onDragEnd={onDragEnd}
    >
      <SortableContext items={controls.map((control) => control.id)} strategy={rectSortingStrategy}>
        <HomeCommandLayout controls={controls} activeControl={activeControl} onOpen={onOpen} touchOptimized={touchOptimized} />
      </SortableContext>
      <DragOverlay dropAnimation={{ duration: 230, easing: "cubic-bezier(0.22, 1, 0.36, 1)" }}>
        <HomeDragOverlay control={activeControl} />
      </DragOverlay>
    </DndContext>
  );
}

export { arrayMove };
