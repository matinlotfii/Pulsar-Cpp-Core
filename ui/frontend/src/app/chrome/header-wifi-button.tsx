import { Button as AriaButton } from "react-aria-components";
import type { WifiSnapshot } from "../model";
import { WifiSignalBars } from "../wifi-ui";

function getWifiAriaLabel(snapshot: WifiSnapshot | null) {
  if (!snapshot) return "Wi-Fi is loading. Tap to manage Wi-Fi.";
  if (!snapshot.available) return "Wi-Fi adapter unavailable. Tap to view Wi-Fi controls.";
  if (!snapshot.connected || !snapshot.ssid) return "Wi-Fi disconnected. Tap to search for networks.";
  return `Connected to ${snapshot.ssid}. Signal ${snapshot.signal} percent. Tap to manage Wi-Fi.`;
}

export function HeaderWifiButton({
  snapshot,
  onOpenWifi
}: {
  snapshot: WifiSnapshot | null;
  onOpenWifi: () => void;
}) {
  return (
    <div className="hmi-status" aria-label="Wi-Fi status">
      <AriaButton className="hmi-wifi-button" aria-label={getWifiAriaLabel(snapshot)} onPress={onOpenWifi}>
        <WifiSignalBars signal={snapshot?.connected ? snapshot.signal : 0} active={Boolean(snapshot?.connected)} compact />
      </AriaButton>
    </div>
  );
}
