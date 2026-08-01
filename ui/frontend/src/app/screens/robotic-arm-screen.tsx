import { ArrowDown, ArrowLeft, ArrowRight, ArrowUp, Home } from "lucide-react";
import type { ReactNode } from "react";
import { Button as AriaButton } from "react-aria-components";

export function RoboticArmScreen({
  header,
  status,
  vector,
  onCommand
}: {
  header: ReactNode;
  status: string;
  vector: string;
  onCommand: (command: string) => void;
}) {
  const directionalControls = [
    { label: "Up", icon: ArrowUp },
    { label: "Left", icon: ArrowLeft },
    { label: "Home", icon: Home },
    { label: "Right", icon: ArrowRight },
    { label: "Down", icon: ArrowDown }
  ];

  return (
    <div className="hmi-screen robot-screen">
      {header}
      <main className="robot-layout">
        <div className="robot-graphic" aria-hidden="true">
          <span className="robot-base" />
          <span className="robot-joint j1" />
          <span className="robot-link l1" />
          <span className="robot-joint j2" />
          <span className="robot-link l2" />
          <span className="robot-camera" />
        </div>
        <section className="direction-pad" aria-label="Arm direction controls">
          {directionalControls.map(({ label, icon: Icon }) => (
            <AriaButton key={label} aria-label={`Move arm ${label}`} onPress={() => onCommand(label)}>
              <Icon size={28} strokeWidth={2.5} />
            </AriaButton>
          ))}
        </section>
        <section className="arm-command-list">
          {["Up", "Down", "Left", "Right"].map((item) => (
            <AriaButton key={item} onPress={() => onCommand(item)}>{item}</AriaButton>
          ))}
          <span className="robot-status-pill">{status} · {vector}</span>
        </section>
        <section className="robot-bottom">
          {["Raise", "Lower", "Home Position"].map((item) => (
            <AriaButton key={item} onPress={() => onCommand(item)}>{item}</AriaButton>
          ))}
        </section>
      </main>
    </div>
  );
}
