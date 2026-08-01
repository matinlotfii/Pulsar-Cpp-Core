import { Eye, EyeOff, LockKeyhole, LockOpen } from "lucide-react";
import type { WifiNetwork, WifiSnapshot } from "./model";
import { WifiSignalBars } from "./wifi-ui";

export interface WifiSpeedTestResult {
  latencyMs: number;
  downloadMbps: number;
  transferredBytes: number;
  measuredAt: string;
  source: string;
}

export interface WifiSpeedTestState {
  status: "idle" | "running" | "done" | "error";
  result: WifiSpeedTestResult | null;
  error: string;
}

const wifiKeyboardRows = [
  ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
  ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
  ["a", "s", "d", "f", "g", "h", "j", "k", "l"],
  ["z", "x", "c", "v", "b", "n", "m"],
  ["@", ".", "-", "_", "!", "#", "$", "%", "&", "*"]
] as const;

let wifiKeyboardAudioContext: AudioContext | null = null;

function formatWifiUsage(totalBytes: number) {
  if (totalBytes >= 1_000_000_000) {
    return `${(totalBytes / 1_000_000_000).toFixed(totalBytes >= 10_000_000_000 ? 0 : 2)} GB`;
  }
  if (totalBytes >= 1_000_000) {
    return `${(totalBytes / 1_000_000).toFixed(totalBytes >= 100_000_000 ? 0 : 1)} MB`;
  }
  return `${Math.max(0, Math.round(totalBytes / 1_000))} KB`;
}

function playWifiKeyboardTapSound() {
  if (typeof window === "undefined") return;
  const AudioContextClass = window.AudioContext || (window as typeof window & { webkitAudioContext?: typeof AudioContext }).webkitAudioContext;
  if (!AudioContextClass) return;
  if (!wifiKeyboardAudioContext) {
    wifiKeyboardAudioContext = new AudioContextClass();
  }

  const context = wifiKeyboardAudioContext;
  if (context.state === "suspended") {
    void context.resume();
  }

  const oscillator = context.createOscillator();
  const gainNode = context.createGain();
  const now = context.currentTime;
  oscillator.type = "triangle";
  oscillator.frequency.setValueAtTime(780, now);
  oscillator.frequency.exponentialRampToValueAtTime(620, now + 0.045);
  gainNode.gain.setValueAtTime(0.0001, now);
  gainNode.gain.exponentialRampToValueAtTime(0.028, now + 0.008);
  gainNode.gain.exponentialRampToValueAtTime(0.0001, now + 0.05);
  oscillator.connect(gainNode);
  gainNode.connect(context.destination);
  oscillator.start(now);
  oscillator.stop(now + 0.055);
}

function getWifiNetworkHint(network: WifiNetwork) {
  return [network.frequency || null, network.channel ? `Ch ${network.channel}` : null, network.rate || null].filter(Boolean).join(" · ");
}

function WifiPasswordKeyboard({
  value,
  open,
  shift,
  onKeyPress,
  onShiftToggle,
  onBackspace,
  onClear,
  onClose
}: {
  value: string;
  open: boolean;
  shift: boolean;
  onKeyPress: (key: string) => void;
  onShiftToggle: () => void;
  onBackspace: () => void;
  onClear: () => void;
  onClose: () => void;
}) {
  function handleKeyPress(nextKey: string) {
    playWifiKeyboardTapSound();
    onKeyPress(nextKey);
  }

  function handleAction(action: () => void) {
    playWifiKeyboardTapSound();
    action();
  }

  return (
    <div className={`wifi-keyboard ${open ? "is-open" : "is-hidden"}`} aria-label="On-screen password keyboard" onClick={(event) => event.stopPropagation()} onPointerDown={(event) => event.stopPropagation()}>
      <div className="wifi-keyboard-handle" aria-hidden="true" />
      <div className="wifi-keyboard-preview">
        <small>Password</small>
        <strong>{value}</strong>
      </div>
      <div className="wifi-keyboard-rows">
        {wifiKeyboardRows.map((row, index) => (
          <div className="wifi-keyboard-row" key={index}>
            {index === 3 ? (
              <button type="button" className={`wifi-keyboard-key is-wide is-shift ${shift ? "is-active" : ""}`} onClick={() => handleAction(onShiftToggle)} aria-label={shift ? "Disable uppercase" : "Enable uppercase"}>
                <span className="wifi-shift-icon" aria-hidden="true" />
              </button>
            ) : null}
            {row.map((key) => (
              <button type="button" className="wifi-keyboard-key" key={key} onClick={() => handleKeyPress(shift ? key.toUpperCase() : key)}>
                {shift ? key.toUpperCase() : key}
              </button>
            ))}
            {index === 3 ? (
              <button type="button" className="wifi-keyboard-key is-wide" onClick={() => handleAction(onBackspace)}>Back</button>
            ) : null}
          </div>
        ))}
        <div className="wifi-keyboard-row is-bottom">
          <button type="button" className="wifi-keyboard-key is-wide" onClick={() => handleAction(onClear)}>Clear</button>
          <button type="button" className="wifi-keyboard-key is-space" onClick={() => handleKeyPress(" ")}>Space</button>
          <button type="button" className="wifi-keyboard-key is-wide" onClick={() => handleAction(onClose)}>Hide</button>
        </div>
      </div>
    </div>
  );
}

export function WifiSheet({
  open,
  snapshot,
  loading,
  selectedNetwork,
  password,
  savedPassword,
  showSavedPassword,
  keyboardOpen,
  keyboardShift,
  connectPending,
  connectError,
  speedTest,
  onSelectNetwork,
  onOpenKeyboard,
  onCloseKeyboard,
  onKeyboardInput,
  onKeyboardBackspace,
  onKeyboardClear,
  onKeyboardShiftToggle,
  onToggleSavedPassword,
  onConnect,
  onDisconnect,
  onClose
}: {
  open: boolean;
  snapshot: WifiSnapshot | null;
  loading: boolean;
  selectedNetwork: WifiNetwork | null;
  password: string;
  savedPassword: string;
  showSavedPassword: boolean;
  keyboardOpen: boolean;
  keyboardShift: boolean;
  connectPending: boolean;
  connectError: string;
  speedTest: WifiSpeedTestState;
  onSelectNetwork: (network: WifiNetwork) => void;
  onOpenKeyboard: () => void;
  onCloseKeyboard: () => void;
  onKeyboardInput: (key: string) => void;
  onKeyboardBackspace: () => void;
  onKeyboardClear: () => void;
  onKeyboardShiftToggle: () => void;
  onToggleSavedPassword: () => void;
  onConnect: () => void;
  onDisconnect: () => void;
  onClose: () => void;
}) {
  if (!open) return null;

  const requiresPassword = Boolean(selectedNetwork?.requiresPassword && !selectedNetwork.isConnected);
  const keyboardVisible = requiresPassword && keyboardOpen;
  const canConnect = Boolean(selectedNetwork && !selectedNetwork.isConnected && (!requiresPassword || password.trim().length > 0));
  const visibleNetworks = snapshot?.networks.filter((network) => network.requiresPassword || network.isConnected) || [];
  const hasNetworks = visibleNetworks.length > 0;
  const liveSpeedResult = speedTest.result;
  const showTryAgain = Boolean(connectError && requiresPassword);
  const maskedPassword = password ? "•".repeat(password.length) : "";

  return (
    <div className="wifi-sheet-backdrop" role="presentation">
      <section className={`wifi-sheet ${keyboardVisible ? "is-keyboard-open" : ""}`} role="dialog" aria-modal="true" aria-label="Wi-Fi manager" onClick={() => {
        if (keyboardVisible) onCloseKeyboard();
      }}>
        <div className="wifi-sheet-header">
          <strong>Network</strong>
          <div className="wifi-sheet-actions">
            <button type="button" className="wifi-ghost-button is-header-done" onClick={onClose}>Done</button>
          </div>
        </div>

        <div className="wifi-speed-panel" aria-live="polite">
          <span><small>Ping</small><strong>{snapshot?.connected && liveSpeedResult ? `${liveSpeedResult.latencyMs} ms` : "--"}</strong></span>
          <span><small>Down</small><strong>{snapshot?.connected && liveSpeedResult ? `${liveSpeedResult.downloadMbps} Mbps` : "--"}</strong></span>
          <span><small>Data Used</small><strong>{snapshot?.connected && snapshot.usage ? formatWifiUsage(snapshot.usage.totalBytes) : "--"}</strong></span>
        </div>

        <div className="wifi-sheet-body">
          <div className="wifi-network-list" role="list" aria-label="Available Wi-Fi networks">
            {loading ? <div className="wifi-empty-state">Loading Wi-Fi networks...</div> : null}
            {!loading && !hasNetworks ? <div className="wifi-empty-state">{snapshot?.available ? "No Wi-Fi networks were found in range." : "Wi-Fi adapter unavailable."}</div> : null}
            {!loading && visibleNetworks.map((network) => (
              <button type="button" className={`wifi-network-row ${selectedNetwork?.id === network.id ? "is-selected" : ""}`} key={network.id} onClick={() => onSelectNetwork(network)}>
                <span className="wifi-network-lock" aria-hidden="true">{network.isConnected ? <LockOpen size={16} /> : <LockKeyhole size={16} />}</span>
                <div className="wifi-network-copy"><strong>{network.ssid}</strong></div>
                <div className="wifi-network-meta"><WifiSignalBars signal={network.signal} /></div>
              </button>
            ))}
          </div>

          <div className="wifi-connect-card">
            {selectedNetwork ? (
              <form className="wifi-connect-form" onSubmit={(event) => {
                event.preventDefault();
                if (canConnect) onConnect();
              }}>
                <div className="wifi-connect-header">
                  <div>
                    <strong>Wi-Fi</strong>
                    {selectedNetwork.isConnected ? <span>{getWifiNetworkHint(selectedNetwork) || "Connected"}</span> : null}
                  </div>
                </div>

                {requiresPassword ? (
                  <label className="wifi-password-field">
                    <span>Password</span>
                    <div className="wifi-password-input-row">
                      <button
                        type="button"
                        className={`wifi-password-input ${password ? "" : "is-placeholder"}`}
                        aria-label="Enter Wi-Fi password"
                        onClick={onOpenKeyboard}
                        onPointerDown={(event) => {
                          event.preventDefault();
                          event.stopPropagation();
                          onOpenKeyboard();
                        }}
                        onMouseDown={(event) => {
                          event.preventDefault();
                          event.stopPropagation();
                          onOpenKeyboard();
                        }}
                      >
                        {password ? (showSavedPassword ? password : maskedPassword) : "Password"}
                      </button>
                      <button type="button" className="wifi-password-toggle" onClick={onToggleSavedPassword} disabled={!password} aria-label={showSavedPassword ? "Hide password" : "Show password"}>
                        {showSavedPassword ? <EyeOff size={17} /> : <Eye size={17} />}
                      </button>
                    </div>
                  </label>
                ) : selectedNetwork.isConnected ? (
                  <div className="wifi-network-details">
                    <span><small>DNS</small><strong>{snapshot?.details?.dns[0] || "-"}</strong></span>
                    <span><small>IPv4</small><strong>{snapshot?.details?.ipv4[0] || "-"}</strong></span>
                    <span><small>IPv6</small><strong>{snapshot?.details?.ipv6[0] || "-"}</strong></span>
                    <div className="wifi-password-reveal">
                      <div className="wifi-password-reveal-copy">
                        <small>Password</small>
                        <strong>{savedPassword ? (showSavedPassword ? savedPassword : "••••••••") : "-"}</strong>
                      </div>
                      <button type="button" className="wifi-password-toggle" onClick={onToggleSavedPassword} disabled={!savedPassword} aria-label={showSavedPassword ? "Hide password" : "Show password"}>
                        {showSavedPassword ? <EyeOff size={17} /> : <Eye size={17} />}
                      </button>
                    </div>
                  </div>
                ) : (
                  <div className="wifi-inline-message">Select a secured network</div>
                )}

                {(requiresPassword || selectedNetwork.isConnected) ? (
                  <div className="wifi-connect-actions">
                    {selectedNetwork.isConnected ? (
                      <button type="button" className="wifi-connect-indicator is-disconnect" onClick={onDisconnect} disabled={!snapshot?.connected || connectPending}>
                        {connectPending ? "Disconnecting..." : "Disconnect"}
                      </button>
                    ) : showTryAgain ? (
                      <button type="button" className="wifi-connect-indicator is-error" onClick={onConnect} disabled={!canConnect || connectPending}>
                        {connectPending ? "Connecting..." : "Try again"}
                      </button>
                    ) : (
                      <button type="button" className="wifi-connect-indicator is-connect" onClick={onConnect} disabled={!canConnect || connectPending}>
                        {connectPending ? "Connecting..." : "Connect"}
                      </button>
                    )}
                  </div>
                ) : null}

                {connectError && !requiresPassword ? <div className="wifi-inline-message is-error">{connectError}</div> : null}
              </form>
            ) : (
              <div className="wifi-empty-state">Select a network</div>
            )}
          </div>
        </div>

        {keyboardVisible ? (
          <WifiPasswordKeyboard
            value={password}
            open
            shift={keyboardShift}
            onKeyPress={onKeyboardInput}
            onShiftToggle={onKeyboardShiftToggle}
            onBackspace={onKeyboardBackspace}
            onClear={onKeyboardClear}
            onClose={onCloseKeyboard}
          />
        ) : null}
      </section>
    </div>
  );
}
