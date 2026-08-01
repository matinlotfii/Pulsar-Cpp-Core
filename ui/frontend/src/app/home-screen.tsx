import { type DragEndEvent, type DragOverEvent, type DragStartEvent } from "@dnd-kit/core";
import { useEffect, useRef, useState, type ReactNode } from "react";
import { lightTapFeedback } from "./feedback";
import { HomeControlGrid, arrayMove } from "./home-grid";
import { getInitialHomeControls, saveHomeControlsLayout } from "./home/home-storage";
import { type ExactPageId, type HomeControlDefinition } from "./model";

export function HomeScreen({
  header,
  openPage
}: {
  header: ReactNode;
  openPage: (page: ExactPageId) => void;
}) {
  const [controls, setControls] = useState<HomeControlDefinition[]>(getInitialHomeControls);
  const [activeControlId, setActiveControlId] = useState<string | null>(null);
  const dragSuppressRef = useRef(false);
  const dragSuppressTimerRef = useRef<number | null>(null);
  const dragReorderedRef = useRef(false);
  const activeControl = activeControlId ? controls.find((control) => control.id === activeControlId) ?? null : null;

  useEffect(() => {
    return () => {
      if (dragSuppressTimerRef.current !== null) {
        window.clearTimeout(dragSuppressTimerRef.current);
      }
    };
  }, []);

  function beginDragReorder(event: DragStartEvent) {
    dragSuppressRef.current = true;
    dragReorderedRef.current = false;
    setActiveControlId(String(event.active.id));
    lightTapFeedback("drag");
    if (dragSuppressTimerRef.current !== null) {
      window.clearTimeout(dragSuppressTimerRef.current);
    }
  }

  function releaseDragReorder() {
    setActiveControlId(null);
    if (dragSuppressTimerRef.current !== null) {
      window.clearTimeout(dragSuppressTimerRef.current);
    }
    dragSuppressTimerRef.current = window.setTimeout(() => {
      dragSuppressRef.current = false;
      dragSuppressTimerRef.current = null;
    }, 220);
  }

  function openControlPage(page: ExactPageId) {
    if (dragSuppressRef.current) return;
    lightTapFeedback("tap");
    openPage(page);
  }

  function reorderControls(event: DragEndEvent | DragOverEvent) {
    const { active, over } = event;
    if (!over || active.id === over.id) return false;
    let changed = false;
    setControls((currentControls) => {
      const oldIndex = currentControls.findIndex((control) => control.id === active.id);
      const newIndex = currentControls.findIndex((control) => control.id === over.id);
      if (oldIndex < 0 || newIndex < 0) return currentControls;
      const nextControls = arrayMove(currentControls, oldIndex, newIndex);
      saveHomeControlsLayout(nextControls);
      changed = true;
      dragReorderedRef.current = true;
      return nextControls;
    });
    return changed;
  }

  return (
    <div className="hmi-screen home-screen">
      {header}
      <section className="home-modern-stage" aria-label="PULSAR controls">
        <HomeControlGrid
          controls={controls}
          activeControl={activeControl}
          onOpen={openControlPage}
          onDragStart={beginDragReorder}
          onDragOver={reorderControls}
          onDragCancel={releaseDragReorder}
          onDragEnd={(event: DragEndEvent) => {
            const alreadyReordered = dragReorderedRef.current;
            const changed = alreadyReordered ? false : reorderControls(event);
            if (alreadyReordered || changed) {
              lightTapFeedback("drop");
            }
            releaseDragReorder();
          }}
        />
      </section>
    </div>
  );
}
