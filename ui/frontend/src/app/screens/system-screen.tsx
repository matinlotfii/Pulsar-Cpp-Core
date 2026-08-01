import type { ReactNode } from "react";
import { Button as AriaButton } from "react-aria-components";
import type { IconName } from "../../types";
import type { SystemPanelId, WifiSnapshot } from "../model";
import { systemIconMap } from "./system-icons";

export function SystemScreen({
  header,
  activePanel,
  checkCount,
  onOpenPanel,
  snapshot,
  onOpenWifi
}: {
  header: ReactNode;
  activePanel: SystemPanelId;
  checkCount: number;
  onOpenPanel: (panel: SystemPanelId) => void;
  snapshot: WifiSnapshot | null;
  onOpenWifi: () => void;
}) {
  const networkValue = snapshot?.connected ? snapshot.ssid || "Connected" : snapshot?.available ? "Disconnected" : "Unavailable";
  const items: Array<{ icon: IconName; title: SystemPanelId; value: string }> = [
    { icon: "HardDrive", title: "Storage", value: "1.2 TB Free" },
    { icon: "Wifi", title: "Network", value: networkValue },
    { icon: "RefreshCcw", title: "System Update", value: "Up to date" },
    { icon: "Activity", title: "Temperature", value: "42 C" },
    { icon: "Sparkles", title: "Fan Speed", value: "Normal" },
    { icon: "ShieldCheck", title: "Power", value: "AC Connected" },
    { icon: "Wrench", title: "Diagnostics", value: checkCount > 0 ? `Checked ${checkCount}x` : "Ready" },
    { icon: "Disc3", title: "Logs", value: "128 events" },
    { icon: "BadgeCheck", title: "About", value: "PULSAR HMI 0.1" }
  ];

  const panelDetails: Record<SystemPanelId, string> = {
    Storage: "Recording target online. Internal SSD has enough free space for the current 4K session.",
    Network: snapshot?.available ? snapshot.connected ? `Connected to ${snapshot.ssid || "Wi-Fi"} on ${snapshot.device || "wireless adapter"}.` : "Wi-Fi is available but not connected. Use the Wi-Fi panel to search and join a network." : "No Wi-Fi adapter is currently available through NetworkManager.",
    "System Update": "No update is pending. Runtime is ready for Ubuntu Core packaging.",
    Temperature: "Device temperature is within the safe operating range.",
    "Fan Speed": "Fan control is normal. No thermal throttling detected.",
    Power: "AC power is connected and battery reserve is available.",
    Diagnostics: checkCount > 0 ? "Last diagnostic pass completed from the touch HMI." : "Tap Diagnostics to run a visible local check.",
    Logs: "Recent system and camera events are available for service review.",
    About: "PULSAR medical HMI for dual camera exoscope monitoring."
  };

  return (
    <div className="hmi-screen system-screen">
      {header}
      <main className="system-layout">
        <section className="system-grid">
          {items.map(({ icon, title, value }) => {
            const Icon = systemIconMap[icon];
            return (
              <AriaButton className={`system-tile ${activePanel === title ? "is-active" : ""}`} key={title} onPress={() => onOpenPanel(title)}>
                <Icon size={42} />
                <span><strong>{title}</strong>{value ? <small>{value}</small> : null}</span>
              </AriaButton>
            );
          })}
        </section>

        <section className="system-panel" aria-live="polite">
          <strong>{activePanel}</strong>
          {activePanel === "Network" ? (
            <div className="system-network-panel">
              <p>{panelDetails[activePanel]}</p>
              <div className="system-network-meta">
                <span>{snapshot?.security || "Wi-Fi"}</span>
                <span>{snapshot?.connected ? `${snapshot.signal}% signal` : "Search nearby networks"}</span>
              </div>
              <button type="button" className="system-network-cta" onClick={onOpenWifi}>Open Wi-Fi</button>
            </div>
          ) : (
            <p>{panelDetails[activePanel]}</p>
          )}
        </section>
      </main>
    </div>
  );
}
