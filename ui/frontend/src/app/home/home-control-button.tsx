import { useSortable } from "@dnd-kit/sortable";
import { CSS } from "@dnd-kit/utilities";
import { type CSSProperties } from "react";
import { Button as AriaButton } from "react-aria-components";
import type { ExactPageId, HomeControlDefinition } from "../model";
import { HomeControlContent } from "./home-control-content";

const homeReorderMotion = [
  { delay: "-60ms", x: "0.8px", y: "-1.2px", xAlt: "-0.5px", yAlt: "0.7px", rotate: "-0.28deg", rotateAlt: "0.2deg", iconY: "-1px" },
  { delay: "-170ms", x: "-0.7px", y: "0.9px", xAlt: "0.6px", yAlt: "-0.5px", rotate: "0.22deg", rotateAlt: "-0.18deg", iconY: "0.8px" },
  { delay: "-260ms", x: "0.5px", y: "1.1px", xAlt: "-0.8px", yAlt: "-0.6px", rotate: "0.18deg", rotateAlt: "-0.24deg", iconY: "-0.7px" },
  { delay: "-110ms", x: "-0.9px", y: "-0.7px", xAlt: "0.4px", yAlt: "0.9px", rotate: "-0.2deg", rotateAlt: "0.26deg", iconY: "1px" },
  { delay: "-320ms", x: "0.7px", y: "0.6px", xAlt: "-0.6px", yAlt: "-1px", rotate: "0.26deg", rotateAlt: "-0.16deg", iconY: "-0.9px" },
  { delay: "-210ms", x: "-0.5px", y: "1px", xAlt: "0.8px", yAlt: "-0.4px", rotate: "0.16deg", rotateAlt: "-0.3deg", iconY: "0.6px" }
];

function getHomeReorderMotionStyle(index: number): CSSProperties {
  const motion = homeReorderMotion[index % homeReorderMotion.length];
  return {
    "--reorder-delay": motion.delay,
    "--reorder-x": motion.x,
    "--reorder-y": motion.y,
    "--reorder-x-alt": motion.xAlt,
    "--reorder-y-alt": motion.yAlt,
    "--reorder-rotate": motion.rotate,
    "--reorder-rotate-alt": motion.rotateAlt,
    "--reorder-icon-y": motion.iconY
  } as CSSProperties;
}

export function SortableHomeControlButton({
  control,
  index,
  onOpen,
  sortable
}: {
  control: HomeControlDefinition;
  index: number;
  onOpen: (page: ExactPageId) => void;
  sortable: boolean;
}) {
  const { attributes, listeners, setNodeRef, transform, transition, isDragging } = useSortable({
    id: control.id,
    transition: { duration: 230, easing: "cubic-bezier(0.22, 1, 0.36, 1)" }
  });

  return (
    <div
      ref={setNodeRef}
      className={`home-sortable-shell ${isDragging ? "is-dragging" : ""}`}
      style={{ transform: CSS.Transform.toString(transform), transition, ...getHomeReorderMotionStyle(index) } as CSSProperties}
    >
      <AriaButton
        className={`home-launch-button tone-${control.tone}`}
        aria-label={control.title}
        onPress={() => onOpen(control.page)}
        {...(sortable ? attributes : {})}
        {...(sortable ? listeners : {})}
      >
        <HomeControlContent control={control} />
      </AriaButton>
    </div>
  );
}
