import type { CSSProperties } from "react";

function getWifiSignalLevel(signal: number) {
  if (signal >= 80) return 4;
  if (signal >= 60) return 3;
  if (signal >= 35) return 2;
  if (signal >= 10) return 1;
  return 0;
}

export function WifiSignalBars({
  signal,
  active = true,
  compact = false
}: {
  signal: number;
  active?: boolean;
  compact?: boolean;
}) {
  const level = active ? getWifiSignalLevel(signal) : 0;
  const heights = compact ? [5, 8, 11, 14] : [8, 12, 16, 20];

  return (
    <span className={`wifi-signal-bars ${compact ? "is-compact" : ""}`} aria-hidden="true">
      {heights.map((height, index) => (
        <span
          key={height}
          className={index < level ? "is-filled" : ""}
          style={{ "--wifi-bar-height": `${height}px` } as CSSProperties}
        />
      ))}
    </span>
  );
}
