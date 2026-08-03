import type { ChangeEvent, ReactNode } from "react";
import { Button as AriaButton } from "react-aria-components";
import type { IconName } from "../../types";
import type { DisplayPortRole, HmiControlState, SystemPanelId, WifiSnapshot } from "../model";
import { systemIconMap } from "./system-icons";

function formatBytes(bytes: number) {
  if (bytes <= 0) return "0 B";
  const units = ["B", "KB", "MB", "GB", "TB"];
  let value = bytes;
  let unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex += 1;
  }
  return `${value >= 100 ? value.toFixed(0) : value.toFixed(1)} ${units[unitIndex]}`;
}

function formatUptime(seconds: number) {
  if (seconds <= 0) return "0m";
  const days = Math.floor(seconds / 86400);
  const hours = Math.floor((seconds % 86400) / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  if (days > 0) return `${days}d ${hours}h`;
  if (hours > 0) return `${hours}h ${minutes}m`;
  return `${minutes}m`;
}

function roleLabel(role: DisplayPortRole) {
  switch (role) {
    case "ui":
      return "UI Setting";
    case "display":
      return "Display";
    case "ar-glass-1":
      return "AR 1";
    case "ar-glass-2":
      return "AR 2";
    case "ar-glass-3":
      return "AR 3";
    default:
      return "Off";
  }
}

export function SystemScreen({
  header,
  state,
  activePanel,
  checkCount,
  onOpenPanel,
  onAssignDisplayPort,
  snapshot,
  onOpenWifi
}: {
  header: ReactNode;
  state: HmiControlState;
  activePanel: SystemPanelId;
  checkCount: number;
  onOpenPanel: (panel: SystemPanelId) => void;
  onAssignDisplayPort: (connector: string, role: DisplayPortRole) => void;
  snapshot: WifiSnapshot | null;
  onOpenWifi: () => void;
}) {
  const info = state.systemInfo;
  const networkValue = snapshot?.connected ? snapshot.ssid || "Connected" : snapshot?.available ? "Disconnected" : "Unavailable";
  const activeIconMap: Record<SystemPanelId, IconName> = {
    Storage: "HardDrive",
    Network: "Wifi",
    "System Update": "RefreshCcw",
    Temperature: "Activity",
    "Fan Speed": "Sparkles",
    "Display Routing": "Route",
    Diagnostics: "Wrench",
    Logs: "Disc3",
    About: "BadgeCheck"
  };
  const items: Array<{ icon: IconName; title: SystemPanelId; value: string }> = [
    { icon: "HardDrive", title: "Storage", value: `${formatBytes(info.storageFreeBytes)} free` },
    { icon: "Wifi", title: "Network", value: networkValue },
    { icon: "RefreshCcw", title: "System Update", value: info.updateStatus },
    { icon: "Activity", title: "Temperature", value: `${info.temperatureC.toFixed(1)} C` },
    { icon: "Sparkles", title: "Fan Speed", value: info.fanRpm > 0 ? `${info.fanRpm} RPM` : info.fanMode },
    { icon: "Route", title: "Display Routing", value: `${info.connectedPortCount}/${info.totalPortCount} ports live` },
    { icon: "Wrench", title: "Diagnostics", value: checkCount > 0 ? `Checked ${checkCount}x` : "Ready" },
    { icon: "Disc3", title: "Logs", value: `${info.logLines} lines` },
    { icon: "BadgeCheck", title: "About", value: info.aboutProduct }
  ];
  const DetailIcon = systemIconMap[activeIconMap[activePanel]];

  function onRoleChange(connector: string, event: ChangeEvent<HTMLSelectElement>) {
    onAssignDisplayPort(connector, event.currentTarget.value as DisplayPortRole);
  }

  return (
    <div className="hmi-screen system-screen">
      {header}
      <main className="system-layout">
        <section className="system-grid">
          {items.map(({ icon, title, value }) => {
            const Icon = systemIconMap[icon];
            return (
              <AriaButton className={`system-tile ${activePanel === title ? "is-active" : ""}`} key={title} onPress={() => onOpenPanel(title)}>
                <Icon size={40} />
                <span>
                  <strong>{title}</strong>
                  <small>{value}</small>
                </span>
              </AriaButton>
            );
          })}
        </section>

        <section className="system-panel" aria-live="polite">
          <div className="system-panel-header">
            <div>
              <strong>{activePanel}</strong>
              <small className="system-panel-subtitle">
                {activePanel === "Storage" ? "Live storage and capture path" : null}
                {activePanel === "Network" ? "Wireless status and Wi-Fi control" : null}
                {activePanel === "System Update" ? "System image and service state" : null}
                {activePanel === "Temperature" ? "Thermal, CPU and memory telemetry" : null}
                {activePanel === "Fan Speed" ? "Cooling state and fan reading" : null}
                {activePanel === "Display Routing" ? "Map UI, Display and AR outputs to real ports" : null}
                {activePanel === "Diagnostics" ? "Quick service health view" : null}
                {activePanel === "Logs" ? "Recent service activity" : null}
                {activePanel === "About" ? "Product and company information" : null}
              </small>
            </div>
            <div className="system-panel-icon">
              <DetailIcon size={58} />
            </div>
          </div>

          {activePanel === "Storage" ? (
            <div className="system-detail-grid">
              <div className="system-stat-card"><span>Free</span><strong>{formatBytes(info.storageFreeBytes)}</strong></div>
              <div className="system-stat-card"><span>Total</span><strong>{formatBytes(info.storageTotalBytes)}</strong></div>
              <div className="system-stat-card"><span>Used</span><strong>{info.storageUsedPercent}%</strong></div>
              <div className="system-stat-card"><span>Path</span><strong>{info.storageMount}</strong></div>
            </div>
          ) : null}

          {activePanel === "Network" ? (
            <div className="system-network-panel">
              <p>{snapshot?.available ? snapshot.connected ? `Connected to ${snapshot.ssid || "Wi-Fi"} on ${snapshot.device || "wireless adapter"}.` : "Wi-Fi is available but not connected. Open the Wi-Fi panel to join a network." : "No Wi-Fi adapter is currently available through NetworkManager."}</p>
              <div className="system-network-meta">
                <span>{snapshot?.security || "Wi-Fi"}</span>
                <span>{snapshot?.connected ? `${snapshot.signal}% signal` : "Search nearby networks"}</span>
                <span>{snapshot?.details?.ipv4?.[0] || "No IP address"}</span>
              </div>
              <button type="button" className="system-network-cta" onClick={onOpenWifi}>Open Wi-Fi</button>
            </div>
          ) : null}

          {activePanel === "System Update" ? (
            <div className="system-detail-grid">
              <div className="system-stat-card"><span>Status</span><strong>{info.updateStatus}</strong></div>
              <div className="system-stat-card"><span>Version</span><strong>{info.aboutProduct}</strong></div>
              <div className="system-stat-card"><span>Uptime</span><strong>{formatUptime(info.uptimeSeconds)}</strong></div>
              <div className="system-stat-card"><span>Service</span><strong>pulsar-kiosk</strong></div>
            </div>
          ) : null}

          {activePanel === "Temperature" ? (
            <div className="system-detail-grid">
              <div className="system-stat-card"><span>System Temp</span><strong>{info.temperatureC.toFixed(1)} C</strong></div>
              <div className="system-stat-card"><span>CPU Load</span><strong>{info.cpuLoad.toFixed(2)}</strong></div>
              <div className="system-stat-card"><span>RAM Used</span><strong>{info.memoryUsedPercent.toFixed(1)}%</strong></div>
              <div className="system-stat-card"><span>Process RSS</span><strong>{formatBytes(info.processRssBytes)}</strong></div>
            </div>
          ) : null}

          {activePanel === "Fan Speed" ? (
            <div className="system-detail-grid">
              <div className="system-stat-card"><span>Mode</span><strong>{info.fanMode}</strong></div>
              <div className="system-stat-card"><span>RPM</span><strong>{info.fanRpm > 0 ? `${info.fanRpm}` : "N/A"}</strong></div>
              <div className="system-stat-card"><span>Thermal</span><strong>{info.temperatureC.toFixed(1)} C</strong></div>
              <div className="system-stat-card"><span>Uptime</span><strong>{formatUptime(info.uptimeSeconds)}</strong></div>
            </div>
          ) : null}

          {activePanel === "Display Routing" ? (
            <div className="system-routing-panel">
              <div className="system-network-meta">
                <span>{info.connectedPortCount} connected</span>
                <span>{info.totalPortCount} total ports</span>
                <span>{info.restartPending ? "Restart queued" : "Auto hotplug enabled"}</span>
              </div>
              <div className="system-port-list">
                {state.displayPorts.map((port) => (
                  <div className="system-port-row" key={port.connector}>
                    <div className="system-port-copy">
                      <strong>{port.connector}</strong>
                      <small>{port.summary}{port.position ? ` ${port.position}` : ""}{port.primary ? " • Primary" : ""}</small>
                    </div>
                    <div className="system-port-controls">
                      <span className={`system-port-dot ${port.connected ? "is-live" : ""}`} aria-hidden="true" />
                      <select value={port.role} onChange={(event) => onRoleChange(port.connector, event)}>
                        <option value="none">{roleLabel("none")}</option>
                        <option value="ui">{roleLabel("ui")}</option>
                        <option value="display">{roleLabel("display")}</option>
                        <option value="ar-glass-1">{roleLabel("ar-glass-1")}</option>
                        <option value="ar-glass-2">{roleLabel("ar-glass-2")}</option>
                        <option value="ar-glass-3">{roleLabel("ar-glass-3")}</option>
                      </select>
                    </div>
                  </div>
                ))}
              </div>
            </div>
          ) : null}

          {activePanel === "Diagnostics" ? (
            <div className="system-detail-grid">
              <div className="system-stat-card"><span>Status</span><strong>{checkCount > 0 ? "Checked" : "Ready"}</strong></div>
              <div className="system-stat-card"><span>Displays</span><strong>{info.connectedPortCount}</strong></div>
              <div className="system-stat-card"><span>Logs</span><strong>{info.logLines}</strong></div>
              <div className="system-stat-card"><span>Wi-Fi</span><strong>{networkValue}</strong></div>
            </div>
          ) : null}

          {activePanel === "Logs" ? (
            <div className="system-detail-grid">
              <div className="system-stat-card"><span>Recent Lines</span><strong>{info.logLines}</strong></div>
              <div className="system-stat-card"><span>Service</span><strong>pulsar-kiosk</strong></div>
              <div className="system-stat-card"><span>Core RSS</span><strong>{formatBytes(info.processRssBytes)}</strong></div>
              <div className="system-stat-card"><span>Uptime</span><strong>{formatUptime(info.uptimeSeconds)}</strong></div>
            </div>
          ) : null}

          {activePanel === "About" ? (
            <div className="system-about-panel">
              <div className="system-detail-grid">
                <div className="system-stat-card"><span>Product</span><strong>{info.aboutProduct}</strong></div>
                <div className="system-stat-card"><span>Company</span><strong>{info.aboutCompany}</strong></div>
                <div className="system-stat-card"><span>Website</span><strong>{info.aboutWebsite}</strong></div>
                <div className="system-stat-card"><span>Version</span><strong>PULSAR HMI</strong></div>
              </div>
              <p>{info.aboutSummary}. Built for real-time 3D microscope and stereo imaging workflows.</p>
            </div>
          ) : null}
        </section>
      </main>
    </div>
  );
}
