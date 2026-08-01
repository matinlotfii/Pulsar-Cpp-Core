import type { WifiSnapshot } from "./model";
import { HeaderBackButton } from "./chrome/header-back-button";
import { HeaderClock } from "./chrome/header-clock";
import { HeaderWifiButton } from "./chrome/header-wifi-button";

export function HmiHeader({
  title,
  onBack,
  home = false,
  wifiSnapshot,
  onOpenWifi
}: {
  title: string;
  onBack?: () => void;
  home?: boolean;
  wifiSnapshot: WifiSnapshot | null;
  onOpenWifi: () => void;
}) {
  return (
    <header className={`hmi-header ${home ? "is-home" : ""}`}>
      {home ? <span className="hmi-home-spacer" aria-hidden="true" /> : <HeaderBackButton onBack={onBack} />}
      {!home ? <h1>{title}</h1> : null}
      <HeaderClock />
      <HeaderWifiButton snapshot={wifiSnapshot} onOpenWifi={onOpenWifi} />
    </header>
  );
}
