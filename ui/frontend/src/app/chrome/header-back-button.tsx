import { ArrowLeft } from "lucide-react";
import { useRef } from "react";
import { lightTapFeedback } from "../feedback";

export function HeaderBackButton({ onBack }: { onBack?: () => void }) {
  const firedRef = useRef(false);

  function triggerBack() {
    if (!onBack || firedRef.current) return;
    firedRef.current = true;
    lightTapFeedback();
    onBack();
    window.setTimeout(() => {
      firedRef.current = false;
    }, 280);
  }

  return (
    <button
      type="button"
      className="hmi-back"
      aria-label="Back to home"
      disabled={!onBack}
      onPointerDown={(event) => {
        event.preventDefault();
        triggerBack();
      }}
      onKeyDown={(event) => {
        if (event.key !== "Enter" && event.key !== " ") return;
        event.preventDefault();
        triggerBack();
      }}
      onClick={triggerBack}
    >
      <ArrowLeft size={22} strokeWidth={2.8} aria-hidden="true" />
    </button>
  );
}
