import { useEffect, useMemo, useState } from "react";
import { lightTapFeedback } from "../feedback";
import type { WifiNetwork, WifiSnapshot } from "../model";
import type { WifiSpeedTestResult, WifiSpeedTestState } from "../wifi-sheet";

const wifiPasswordStorageKey = "pulsar.wifi.passwords.v1";

interface ApiErrorPayload {
  error?: string;
}

function getInitialSavedWifiPasswords() {
  if (typeof window === "undefined") return {} as Record<string, string>;
  try {
    const saved = JSON.parse(window.localStorage.getItem(wifiPasswordStorageKey) || "{}") as unknown;
    if (!saved || typeof saved !== "object" || Array.isArray(saved)) return {};
    return Object.fromEntries(
      Object.entries(saved).filter((entry): entry is [string, string] => typeof entry[0] === "string" && typeof entry[1] === "string")
    );
  } catch {
    return {};
  }
}

function isApiErrorPayload(payload: unknown): payload is ApiErrorPayload {
  return payload !== null && typeof payload === "object" && "error" in payload;
}

function isWifiSnapshotPayload(payload: unknown): payload is WifiSnapshot {
  return payload !== null &&
    typeof payload === "object" &&
    "available" in payload &&
    "networks" in payload &&
    Array.isArray((payload as { networks?: unknown }).networks);
}

function isWifiSpeedTestResultPayload(payload: unknown): payload is WifiSpeedTestResult {
  return payload !== null &&
    typeof payload === "object" &&
    "latencyMs" in payload &&
    "downloadMbps" in payload &&
    "measuredAt" in payload;
}

async function readJsonResponse(response: Response): Promise<unknown> {
  const responseText = await response.text();
  if (!responseText.trim()) return null;
  try {
    return JSON.parse(responseText) as unknown;
  } catch {
    throw new Error("Invalid server response.");
  }
}

function getWifiRequestErrorMessage(error: unknown, fallback: string) {
  if (!(error instanceof Error)) return fallback;
  if (
    error.message === "Invalid server response." ||
    error.message.includes("Unexpected end of JSON input") ||
    error.message.includes("Failed to execute 'json'")
  ) {
    return fallback;
  }
  return error.message || fallback;
}

export function useWifiManager({ notify }: { notify: (message: string) => void }) {
  const [snapshot, setSnapshot] = useState<WifiSnapshot | null>(null);
  const [loading, setLoading] = useState(true);
  const [sheetOpen, setSheetOpen] = useState(false);
  const [apiError, setApiError] = useState("");
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [password, setPassword] = useState("");
  const [savedPasswords, setSavedPasswords] = useState<Record<string, string>>(getInitialSavedWifiPasswords);
  const [showSavedPassword, setShowSavedPassword] = useState(false);
  const [keyboardOpen, setKeyboardOpen] = useState(false);
  const [keyboardShift, setKeyboardShift] = useState(false);
  const [connectPending, setConnectPending] = useState(false);
  const [connectError, setConnectError] = useState("");
  const [speedTest, setSpeedTest] = useState<WifiSpeedTestState>({
    status: "idle",
    result: null,
    error: ""
  });

  const selectedNetwork = useMemo(
    () =>
      snapshot?.networks.find((network) => network.id === selectedId && (network.requiresPassword || network.isConnected)) ||
      snapshot?.networks.find((network) => network.isConnected) ||
      snapshot?.networks.find((network) => network.requiresPassword || network.isConnected) ||
      null,
    [selectedId, snapshot]
  );

  const savedPassword = selectedNetwork
    ? savedPasswords[selectedNetwork.ssid] || (selectedNetwork.isConnected ? snapshot?.details?.password || "" : "")
    : "";

  useEffect(() => {
    void loadSnapshot();
    const interval = window.setInterval(() => {
      void loadSnapshot(true);
    }, 20_000);
    return () => window.clearInterval(interval);
  }, []);

  useEffect(() => {
    if (!sheetOpen) return;
    void loadSnapshot(true);
    const interval = window.setInterval(() => {
      void loadSnapshot(true);
    }, 8_000);
    return () => window.clearInterval(interval);
  }, [sheetOpen]);

  useEffect(() => {
    if (!sheetOpen || !snapshot?.connected) return;
    void runSpeedTest({ silent: true });
    const interval = window.setInterval(() => {
      void runSpeedTest({ silent: true });
    }, 45_000);
    return () => window.clearInterval(interval);
  }, [sheetOpen, snapshot?.connected]);

  useEffect(() => {
    if (typeof window === "undefined") return;
    window.localStorage.setItem(wifiPasswordStorageKey, JSON.stringify(savedPasswords));
  }, [savedPasswords]);

  useEffect(() => {
    setShowSavedPassword(false);
    if (!selectedNetwork?.requiresPassword || selectedNetwork.isConnected) {
      setKeyboardOpen(false);
      setKeyboardShift(false);
    }
  }, [selectedNetwork?.id, selectedNetwork?.isConnected, selectedNetwork?.requiresPassword]);

  async function loadSnapshot(refresh = false) {
    if (!refresh) setLoading(true);
    try {
      const response = await fetch(`/api/wifi/status${refresh ? "?refresh=1" : ""}`, { cache: "no-store" });
      const payload = await readJsonResponse(response);
      if (!response.ok || isApiErrorPayload(payload) || !isWifiSnapshotPayload(payload)) {
        throw new Error(isApiErrorPayload(payload) ? payload.error || "Failed to load Wi-Fi state." : "Failed to load Wi-Fi state.");
      }
      setSnapshot(payload);
      setApiError("");
      setSelectedId((current) => {
        if (current && payload.networks.some((network) => network.id === current)) return current;
        return payload.networks.find((network) => network.isConnected)?.id || payload.networks.find((network) => network.requiresPassword || network.isConnected)?.id || null;
      });
    } catch (error) {
      setApiError(getWifiRequestErrorMessage(error, "Failed to load Wi-Fi state."));
    } finally {
      setLoading(false);
    }
  }

  function openSheet() {
    lightTapFeedback();
    setSheetOpen(true);
    setConnectError("");
    setApiError("");
  }

  function closeSheet() {
    lightTapFeedback();
    setSheetOpen(false);
    setKeyboardOpen(false);
    setKeyboardShift(false);
    setShowSavedPassword(false);
  }

  function selectNetwork(network: WifiNetwork) {
    lightTapFeedback();
    setSelectedId(network.id);
    setConnectError("");
    setShowSavedPassword(false);
    if (network.isConnected || !network.requiresPassword) {
      setPassword("");
      setKeyboardOpen(false);
      setKeyboardShift(false);
    } else {
      setPassword(savedPasswords[network.ssid] || "");
    }
  }

  function handleKeyboardBackspace() {
    setPassword((current) => {
      const nextValue = current.slice(0, -1);
      if (!nextValue && selectedNetwork?.ssid) {
        setSavedPasswords((saved) => {
          if (!(selectedNetwork.ssid in saved)) return saved;
          const nextSaved = { ...saved };
          delete nextSaved[selectedNetwork.ssid];
          return nextSaved;
        });
      }
      return nextValue;
    });
  }

  function handleKeyboardClear() {
    setPassword("");
    if (selectedNetwork?.ssid) {
      setSavedPasswords((saved) => {
        if (!(selectedNetwork.ssid in saved)) return saved;
        const nextSaved = { ...saved };
        delete nextSaved[selectedNetwork.ssid];
        return nextSaved;
      });
    }
  }

  async function connectSelected() {
    if (!selectedNetwork) return;
    if (selectedNetwork.requiresPassword && !password.trim()) {
      setConnectError("Enter the Wi-Fi password to connect.");
      return;
    }

    setConnectPending(true);
    setConnectError("");
    try {
      const response = await fetch("/api/wifi/connect", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ ssid: selectedNetwork.ssid, password: selectedNetwork.requiresPassword ? password : "" })
      });
      const payload = await readJsonResponse(response);
      if (!response.ok || isApiErrorPayload(payload) || !isWifiSnapshotPayload(payload)) {
        throw new Error(isApiErrorPayload(payload) ? payload.error || "Wi-Fi connection failed." : "Wi-Fi connection failed.");
      }

      setSnapshot(payload);
      setSelectedId(payload.networks.find((network) => network.isConnected)?.id || payload.networks[0]?.id || null);
      if (selectedNetwork.requiresPassword && password.trim()) {
        setSavedPasswords((current) => ({ ...current, [selectedNetwork.ssid]: password }));
      }
      setPassword("");
      setKeyboardOpen(false);
      setKeyboardShift(false);
      setShowSavedPassword(false);
      setSpeedTest({ status: "idle", result: null, error: "" });
      notify(payload.connected ? `Wi-Fi connected: ${payload.ssid || "Network"}` : "Wi-Fi updated");
    } catch (error) {
      setConnectError(getWifiRequestErrorMessage(error, "Wi-Fi connection failed."));
      setSpeedTest({ status: "idle", result: null, error: "" });
    } finally {
      setConnectPending(false);
    }
  }

  async function disconnectSelected() {
    if (!snapshot?.connected) return;
    setConnectPending(true);
    setConnectError("");
    try {
      const response = await fetch("/api/wifi/disconnect", { method: "POST" });
      const payload = await readJsonResponse(response);
      if (!response.ok || isApiErrorPayload(payload) || !isWifiSnapshotPayload(payload)) {
        throw new Error(isApiErrorPayload(payload) ? payload.error || "Wi-Fi disconnect failed." : "Wi-Fi disconnect failed.");
      }

      setSnapshot(payload);
      setSelectedId(payload.networks.find((network) => network.isConnected)?.id || payload.networks.find((network) => network.requiresPassword || network.isConnected)?.id || null);
      setPassword("");
      setKeyboardOpen(false);
      setKeyboardShift(false);
      setShowSavedPassword(false);
      setSpeedTest({ status: "idle", result: null, error: "" });
      notify("Wi-Fi disconnected");
    } catch (error) {
      setConnectError(getWifiRequestErrorMessage(error, "Wi-Fi disconnect failed."));
    } finally {
      setConnectPending(false);
    }
  }

  async function runSpeedTest({ silent = false }: { silent?: boolean } = {}) {
    if (!snapshot?.connected || speedTest.status === "running") return;
    setSpeedTest({ status: "running", result: speedTest.result, error: "" });
    try {
      const response = await fetch("/api/wifi/speedtest", { method: "POST" });
      const payload = await readJsonResponse(response);
      if (!response.ok || isApiErrorPayload(payload) || !isWifiSpeedTestResultPayload(payload)) {
        throw new Error(isApiErrorPayload(payload) ? payload.error || "Speed test failed." : "Speed test failed.");
      }
      setSpeedTest({ status: "done", result: payload, error: "" });
      if (!silent) notify("Speed test complete");
    } catch {
      setSpeedTest((current) => (silent ? { status: current.result ? "done" : "idle", result: current.result, error: "" } : { status: "error", result: current.result, error: "" }));
      if (!silent) notify("Speed test failed");
    }
  }

  return {
    snapshot,
    loading,
    sheetOpen,
    apiError,
    selectedNetwork,
    password,
    savedPassword,
    showSavedPassword,
    keyboardOpen,
    keyboardShift,
    connectPending,
    connectError,
    speedTest,
    openSheet,
    closeSheet,
    selectNetwork,
    setPassword,
    setKeyboardOpen,
    setKeyboardShift,
    setShowSavedPassword,
    handleKeyboardBackspace,
    handleKeyboardClear,
    connectSelected,
    disconnectSelected
  };
}
