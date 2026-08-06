import { useEffect, useRef, useState } from "react";
import { HmiHeader } from "./chrome";
import { defaultStereoAutoAlign, requestStereoAutoAlign } from "./camera-stream";
import { renderDesignedPage, type HmiHandlers } from "./exact-screens";
import { installGlobalButtonFeedback, lightTapFeedback, playStartupFeedback, primeUiAudio, setUiFeedbackEnabled } from "./feedback";
import { useWifiManager } from "./hooks/use-wifi-manager";
import {
  defaultPedalMap,
  displayDefaults,
  enhanceModes,
  exactPages,
  initialHmiState,
  pedalActions,
  saveTargets,
  stereoRotations,
  whiteBalanceModes,
  type CameraControlState,
  type DisplayPortRole,
  type ExactPageId,
  type HmiControlState,
  type StereoMode,
  type StereoAutoAlignState
} from "./model";
import { WifiSheet } from "./wifi-sheet";
import { recordStateApiLatency } from "./runtime-telemetry";

interface BackendStatePayload {
  cameras?: Array<{
    controls?: Partial<CameraControlState>;
  }>;
  outputs?: Array<{
    id?: keyof typeof displayDefaults;
    label?: string;
    connector?: string;
    connected?: boolean;
    mode?: "2D" | "3D";
    volume?: number;
    muted?: boolean;
    buttonSoundEnabled?: boolean;
    sink?: string;
  }>;
  display?: {
    mainDisplayMode?: "2D" | "3D";
    stereoMode?: "SBS" | "LineInterleaved" | "Line Interleaved";
    swapEyes?: boolean;
  };
  displayPorts?: Array<{
    connector?: string;
    connected?: boolean;
    primary?: boolean;
    role?: DisplayPortRole;
    resolution?: string;
    position?: string;
    refreshRate?: string;
    summary?: string;
  }>;
  system?: {
    memoryUsedPercent?: number;
    cpuLoad?: number;
    processRssBytes?: number;
    uptimeSeconds?: number;
    version?: string;
  };
  systemDetails?: {
    storageFreeBytes?: number;
    storageTotalBytes?: number;
    storageUsedPercent?: number;
    storageMount?: string;
    updateStatus?: string;
    temperatureC?: number;
    fanRpm?: number;
    fanMode?: string;
    logLines?: number;
    connectedPortCount?: number;
    totalPortCount?: number;
    restartPending?: boolean;
    aboutProduct?: string;
    aboutCompany?: string;
    aboutWebsite?: string;
    aboutSummary?: string;
  };
}

function clamp(value: number, min: number, max: number) {
  return Math.min(max, Math.max(min, value));
}

function cycleValue<T>(values: readonly T[], current: T) {
  const index = values.indexOf(current);
  return values[(index + 1) % values.length];
}

function getInitialExactPage(): ExactPageId {
  if (typeof window === "undefined") return "home";
  const requestedPage = new URLSearchParams(window.location.search).get("page");
  return requestedPage && requestedPage in exactPages ? (requestedPage as ExactPageId) : "home";
}

function isBackendStatePayload(payload: unknown): payload is BackendStatePayload {
  return payload !== null && typeof payload === "object" && "display" in payload;
}

function uiStereoModeFromBackend(mode: string | undefined): StereoMode {
  return mode === "LineInterleaved" || mode === "Line Interleaved" ? "Line Interleaved" : "SBS";
}

function backendStereoModeFromUi(mode: StereoMode) {
  return mode === "Line Interleaved" ? "LineInterleaved" : mode;
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

function AppRoot() {
  const [activePage, setActivePage] = useState<ExactPageId>(getInitialExactPage);
  const [hmiState, setHmiState] = useState<HmiControlState>(initialHmiState);
  const [autoAlign, setAutoAlign] = useState<StereoAutoAlignState>(defaultStereoAutoAlign);
  const toastTimerRef = useRef<number | null>(null);
  const page = exactPages[activePage];
  const wifi = useWifiManager({
    notify(message) {
      setHmiState((current) => ({ ...current, toast: message }));
    }
  });

  useEffect(() => {
    document.title = `PULSAR - ${page.label}`;
  }, [page.label]);

  useEffect(() => {
    primeUiAudio();
    playStartupFeedback();
    return installGlobalButtonFeedback();
  }, []);

  useEffect(() => {
    const selectedDisplay = hmiState.displays[hmiState.activeDisplay];
    setUiFeedbackEnabled(selectedDisplay?.muted !== true);
  }, [hmiState.activeDisplay, hmiState.displays]);

  useEffect(() => {
    let alive = true;
    const syncAutoAlign = async () => {
      try {
        const state = await requestStereoAutoAlign();
        if (alive) setAutoAlign(state);
      } catch {
      }
    };
    void syncAutoAlign();
    const timer = window.setInterval(syncAutoAlign, autoAlign.active ? 180 : 900);
    return () => {
      alive = false;
      window.clearInterval(timer);
    };
  }, [autoAlign.active]);

  useEffect(() => {
    const loadBackendState = async () => {
      const requestStartedAt = performance.now();
      try {
        const response = await fetch("/api/state", { cache: "no-store" });
        const payload = await response.json().catch(() => null);
        recordStateApiLatency(performance.now() - requestStartedAt);
        if (!response.ok || !isBackendStatePayload(payload)) return;
        applyBackendState(payload);
      } catch {
        recordStateApiLatency(performance.now() - requestStartedAt);
      }
    };
    void loadBackendState();
    const refreshMs = activePage === "display-settings" ? 500 : activePage === "system" ? 3000 : 5000;
    const timer = window.setInterval(loadBackendState, refreshMs);
    return () => {
      window.clearInterval(timer);
    };
  }, [activePage]);

  useEffect(() => {
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        event.preventDefault();
        void fetch("/api/system/exit", { method: "POST" }).catch(() => undefined);
        return;
      }
      if ((event.ctrlKey || event.metaKey) && ["+", "=", "-", "0"].includes(event.key)) {
        event.preventDefault();
      }
    };
    const handleWheel = (event: WheelEvent) => {
      if (event.ctrlKey) event.preventDefault();
    };

    window.addEventListener("keydown", handleKeyDown, { capture: true });
    window.addEventListener("wheel", handleWheel, { passive: false });
    return () => {
      window.removeEventListener("keydown", handleKeyDown, { capture: true });
      window.removeEventListener("wheel", handleWheel);
    };
  }, []);

  useEffect(() => {
    if (!hmiState.recordingActive) return undefined;
    const interval = window.setInterval(() => {
      setHmiState((current) => ({ ...current, recordingElapsed: current.recordingElapsed + 1 }));
    }, 1000);
    return () => window.clearInterval(interval);
  }, [hmiState.recordingActive]);

  useEffect(() => () => {
    if (toastTimerRef.current !== null) window.clearTimeout(toastTimerRef.current);
  }, []);

  useEffect(() => {
    if (!hmiState.toast) return undefined;
    if (toastTimerRef.current !== null) window.clearTimeout(toastTimerRef.current);
    toastTimerRef.current = window.setTimeout(() => {
      setHmiState((current) => ({ ...current, toast: "" }));
      toastTimerRef.current = null;
    }, 1500);
    return () => {
      if (toastTimerRef.current !== null) {
        window.clearTimeout(toastTimerRef.current);
        toastTimerRef.current = null;
      }
    };
  }, [hmiState.toast]);

  function openPage(target: ExactPageId) {
    lightTapFeedback();
    setActivePage(target);
    if (typeof window !== "undefined") {
      const nextUrl = target === "home" ? "/" : `/?page=${target}`;
      window.history.replaceState(null, "", nextUrl);
    }
  }

  function applyBackendState(payload: BackendStatePayload) {
    setHmiState((current) => {
      const nextDisplays = { ...current.displays };
      for (const [id, display] of Object.entries(nextDisplays) as Array<[keyof typeof displayDefaults, typeof displayDefaults[keyof typeof displayDefaults]]>) {
        nextDisplays[id] = { ...display, connected: false, active: false };
      }
      for (const output of payload.outputs ?? []) {
        if (!output.id || !(output.id in nextDisplays)) continue;
        const currentDisplay = nextDisplays[output.id];
        nextDisplays[output.id] = {
          ...currentDisplay,
          label: typeof output.label === "string" ? output.label : currentDisplay.label,
          connector: typeof output.connector === "string" ? output.connector : currentDisplay.connector,
          connected: output.connected === true,
          mode: output.mode === "2D" ? "2D" : "3D",
          volume: typeof output.volume === "number" ? clamp(output.volume, 0, 125) : currentDisplay.volume,
          muted: typeof output.muted === "boolean" ? output.muted : currentDisplay.muted,
          buttonSoundEnabled: typeof output.buttonSoundEnabled === "boolean" ? output.buttonSoundEnabled : currentDisplay.buttonSoundEnabled,
          active: output.connected === true
        };
      }

      const cameras = current.cameras.map((camera, index) => {
        const controls = payload.cameras?.[index]?.controls;
        if (!controls) return camera;
        return {
          ...camera,
          zoom: typeof controls.zoom === "number" ? controls.zoom : camera.zoom,
          focus: typeof controls.focus === "number" ? controls.focus : camera.focus,
          brightness: typeof controls.brightness === "number" ? controls.brightness : camera.brightness,
          whiteBalance: typeof controls.whiteBalance === "string" ? controls.whiteBalance as CameraControlState["whiteBalance"] : camera.whiteBalance,
          enhance: typeof controls.enhance === "string" ? controls.enhance as CameraControlState["enhance"] : camera.enhance,
          frozen: typeof controls.frozen === "boolean" ? controls.frozen : camera.frozen,
          rotation: typeof controls.rotation === "number" ? controls.rotation : camera.rotation
        };
      }) as [CameraControlState, CameraControlState];

      const fallbackDisplay = (Object.values(nextDisplays).find((display) => display.connected)?.id ?? current.activeDisplay);
      const displayPorts = (payload.displayPorts ?? []).map((port) => {
        const role: DisplayPortRole =
          port.role === "ui" ||
          port.role === "display" ||
          port.role === "ar-glass-1" ||
          port.role === "ar-glass-2"
            ? port.role
            : "none";
        return {
          connector: typeof port.connector === "string" ? port.connector : "",
          connected: port.connected === true,
          primary: port.primary === true,
          role,
          resolution: typeof port.resolution === "string" ? port.resolution : "",
          position: typeof port.position === "string" ? port.position : "",
          refreshRate: typeof port.refreshRate === "string" ? port.refreshRate : "",
          summary: typeof port.summary === "string" ? port.summary : ""
        };
      });

      return {
        ...current,
        cameras,
        displays: nextDisplays,
        activeDisplay: nextDisplays[current.activeDisplay].connected ? current.activeDisplay : fallbackDisplay,
        stereoMode: uiStereoModeFromBackend(payload.display?.stereoMode),
        eyeSwap: typeof payload.display?.swapEyes === "boolean" ? payload.display.swapEyes : current.eyeSwap,
        displayPorts,
        systemInfo: {
          ...current.systemInfo,
          storageFreeBytes: typeof payload.systemDetails?.storageFreeBytes === "number" ? payload.systemDetails.storageFreeBytes : current.systemInfo.storageFreeBytes,
          storageTotalBytes: typeof payload.systemDetails?.storageTotalBytes === "number" ? payload.systemDetails.storageTotalBytes : current.systemInfo.storageTotalBytes,
          storageUsedPercent: typeof payload.systemDetails?.storageUsedPercent === "number" ? payload.systemDetails.storageUsedPercent : current.systemInfo.storageUsedPercent,
          storageMount: typeof payload.systemDetails?.storageMount === "string" ? payload.systemDetails.storageMount : current.systemInfo.storageMount,
          updateStatus: typeof payload.systemDetails?.updateStatus === "string" ? payload.systemDetails.updateStatus : current.systemInfo.updateStatus,
          temperatureC: typeof payload.systemDetails?.temperatureC === "number" ? payload.systemDetails.temperatureC : current.systemInfo.temperatureC,
          fanRpm: typeof payload.systemDetails?.fanRpm === "number" ? payload.systemDetails.fanRpm : current.systemInfo.fanRpm,
          fanMode: typeof payload.systemDetails?.fanMode === "string" ? payload.systemDetails.fanMode : current.systemInfo.fanMode,
          logLines: typeof payload.systemDetails?.logLines === "number" ? payload.systemDetails.logLines : current.systemInfo.logLines,
          connectedPortCount: typeof payload.systemDetails?.connectedPortCount === "number" ? payload.systemDetails.connectedPortCount : current.systemInfo.connectedPortCount,
          totalPortCount: typeof payload.systemDetails?.totalPortCount === "number" ? payload.systemDetails.totalPortCount : current.systemInfo.totalPortCount,
          restartPending: typeof payload.systemDetails?.restartPending === "boolean" ? payload.systemDetails.restartPending : current.systemInfo.restartPending,
          aboutProduct: typeof payload.systemDetails?.aboutProduct === "string" ? payload.systemDetails.aboutProduct : current.systemInfo.aboutProduct,
          aboutCompany: typeof payload.systemDetails?.aboutCompany === "string" ? payload.systemDetails.aboutCompany : current.systemInfo.aboutCompany,
          aboutWebsite: typeof payload.systemDetails?.aboutWebsite === "string" ? payload.systemDetails.aboutWebsite : current.systemInfo.aboutWebsite,
          aboutSummary: typeof payload.systemDetails?.aboutSummary === "string" ? payload.systemDetails.aboutSummary : current.systemInfo.aboutSummary,
          uptimeSeconds: typeof payload.system?.uptimeSeconds === "number" ? payload.system.uptimeSeconds : current.systemInfo.uptimeSeconds,
          cpuLoad: typeof payload.system?.cpuLoad === "number" ? payload.system.cpuLoad : current.systemInfo.cpuLoad,
          memoryUsedPercent: typeof payload.system?.memoryUsedPercent === "number" ? payload.system.memoryUsedPercent : current.systemInfo.memoryUsedPercent,
          processRssBytes: typeof payload.system?.processRssBytes === "number" ? payload.system.processRssBytes : current.systemInfo.processRssBytes
        }
      };
    });
  }

  async function pushDisplayPatch(patch: Record<string, unknown>) {
    try {
      const response = await fetch("/api/display", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(patch)
      });
      const payload = await readJsonResponse(response);
      if (response.ok && isBackendStatePayload(payload)) {
        applyBackendState(payload);
      }
    } catch {
    }
  }

  async function pushDisplayRoutingPatch(connector: string, role: DisplayPortRole) {
    try {
      const response = await fetch("/api/system/display-routing", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ connector, role })
      });
      const payload = await readJsonResponse(response);
      if (response.ok && isBackendStatePayload(payload)) {
        applyBackendState(payload);
      }
    } catch {
    }
  }

  const handlers: HmiHandlers = {
    onCameraAction(cameraIndex, action) {
      lightTapFeedback();
      setHmiState((current) => {
        const cameras = [...current.cameras] as [CameraControlState, CameraControlState];
        const camera = cameras[cameraIndex];
        let nextCamera = camera;
        let message = "";
        if (action === "snapshot") {
          nextCamera = { ...camera, status: "Snapshot saved" };
          message = `${cameraIndex === 0 ? "Left" : "Right"} camera snapshot saved`;
        }
        if (action === "record") {
          const recording = !camera.recording;
          nextCamera = { ...camera, recording, status: recording ? "Camera recording" : "Camera record stopped" };
          message = recording ? "Camera recording started" : "Camera recording stopped";
        }
        if (action === "freeze") {
          const frozen = !camera.frozen;
          nextCamera = { ...camera, frozen, status: frozen ? "Frame frozen" : "Live stream resumed" };
          message = nextCamera.status;
        }
        if (action === "rotate") {
          const rotation = (camera.rotation + 90) % 360;
          nextCamera = { ...camera, rotation, status: `View rotated ${rotation} deg` };
          message = nextCamera.status;
        }
        if (action === "more") {
          nextCamera = { ...camera, status: "Advanced controls shown" };
          message = "Quick controls are active";
        }
        cameras[cameraIndex] = nextCamera;
        return { ...current, cameras, toast: message };
      });
    },
    onCameraAdjust(cameraIndex, field, delta) {
      lightTapFeedback();
      if (field === "zoom") {
        void requestStereoAutoAlign("?action=sample").then(setAutoAlign).catch(() => undefined);
      }
      setHmiState((current) => {
        const cameras = [...current.cameras] as [CameraControlState, CameraControlState];
        const camera = cameras[cameraIndex];
        const nextCamera = { ...camera };
        if (field === "zoom") nextCamera.zoom = Number(clamp(camera.zoom + delta, 1, 6).toFixed(1));
        if (field === "focus") nextCamera.focus = clamp(camera.focus + delta, -40, 40);
        if (field === "brightness") nextCamera.brightness = clamp(camera.brightness + delta, 0, 100);
        nextCamera.status = `${field} set`;
        cameras[cameraIndex] = nextCamera;
        return { ...current, cameras, toast: `${field} updated` };
      });
    },
    onCameraCycle(cameraIndex, field) {
      lightTapFeedback();
      setHmiState((current) => {
        const cameras = [...current.cameras] as [CameraControlState, CameraControlState];
        const camera = cameras[cameraIndex];
        const nextCamera = field === "whiteBalance"
          ? { ...camera, whiteBalance: cycleValue(whiteBalanceModes, camera.whiteBalance), status: "White balance updated" }
          : { ...camera, enhance: cycleValue(enhanceModes, camera.enhance), status: "Enhancement updated" };
        cameras[cameraIndex] = nextCamera;
        return { ...current, cameras, toast: nextCamera.status };
      });
    },
    onStereoModeChange(mode) {
      lightTapFeedback();
      setHmiState((current) => ({ ...current, stereoMode: mode, toast: `Stereo mode: ${mode}` }));
      void pushDisplayPatch({ stereoMode: backendStereoModeFromUi(mode) });
    },
    onStereoDepthChange(depth) {
      setHmiState((current) => ({ ...current, stereoDepth: clamp(depth, 1, 10), toast: "Stereo depth updated" }));
    },
    onStereoRotationCycle() {
      lightTapFeedback();
      setHmiState((current) => ({ ...current, stereoRotation: cycleValue(stereoRotations, current.stereoRotation), toast: "3D rotation changed" }));
    },
    onEyeSwapToggle() {
      lightTapFeedback();
      setHmiState((current) => {
        const nextEyeSwap = !current.eyeSwap;
        void pushDisplayPatch({ swapEyes: nextEyeSwap });
        return { ...current, eyeSwap: nextEyeSwap, toast: current.eyeSwap ? "Eye swap off" : "Eye swap on" };
      });
    },
    onSelectDisplay(id) {
      lightTapFeedback();
      setHmiState((current) => ({ ...current, activeDisplay: id, toast: `${current.displays[id].label} selected` }));
    },
    onDisplayMode(id, mode) {
      lightTapFeedback();
      setHmiState((current) => {
        void pushDisplayPatch({ outputId: id, mode });
        return { ...current, displays: { ...current.displays, [id]: { ...current.displays[id], mode, active: true } }, toast: `${current.displays[id].label}: ${mode}` };
      });
    },
    onDisplayVolume(id, value) {
      setHmiState((current) => {
        void pushDisplayPatch({ outputId: id, volume: clamp(value, 0, 125) });
        return { ...current, displays: { ...current.displays, [id]: { ...current.displays[id], volume: clamp(value, 0, 125), active: true } }, toast: "Volume updated" };
      });
    },
    onDisplayMuteToggle(id) {
      lightTapFeedback();
      setHmiState((current) => {
        const muted = !current.displays[id].muted;
        void pushDisplayPatch({ outputId: id, muted });
        return { ...current, displays: { ...current.displays, [id]: { ...current.displays[id], muted, active: true } }, toast: muted ? `${current.displays[id].label} muted` : `${current.displays[id].label} unmuted` };
      });
    },
    onDisplayButtonSoundToggle(id) {
      lightTapFeedback();
      setHmiState((current) => {
        const buttonSoundEnabled = !current.displays[id].buttonSoundEnabled;
        void pushDisplayPatch({ outputId: id, buttonSoundEnabled });
        return { ...current, displays: { ...current.displays, [id]: { ...current.displays[id], buttonSoundEnabled, active: true } }, toast: buttonSoundEnabled ? "Button sound on" : "Button sound off" };
      });
    },
    onToggleRecording() {
      lightTapFeedback();
      setHmiState((current) => ({ ...current, recordingActive: !current.recordingActive, toast: current.recordingActive ? "Recording stopped" : "Recording started" }));
    },
    onSaveTargetCycle() {
      lightTapFeedback();
      setHmiState((current) => {
        const saveTarget = cycleValue(saveTargets, current.saveTarget);
        return { ...current, saveTarget, toast: `Save target: ${saveTarget}` };
      });
    },
    onOpenRecordings() {
      lightTapFeedback();
      setHmiState((current) => ({ ...current, toast: "Recordings list opened" }));
    },
    onRobotCommand(command) {
      lightTapFeedback();
      setHmiState((current) => ({ ...current, robotStatus: command === "Home" || command === "Home Position" ? "Homing" : "Moving", robotVector: command, toast: `Robot: ${command}` }));
    },
    onSelectPedal(side) {
      lightTapFeedback();
      setHmiState((current) => ({ ...current, selectedPedal: side, toast: `${side === "left" ? "Left" : "Right"} pedal selected` }));
    },
    onCyclePedalMapping(gesture) {
      lightTapFeedback();
      setHmiState((current) => {
        const currentAction = current.pedalMaps[current.selectedPedal][gesture];
        const nextAction = cycleValue(pedalActions, currentAction);
        return {
          ...current,
          pedalMaps: {
            ...current.pedalMaps,
            [current.selectedPedal]: {
              ...current.pedalMaps[current.selectedPedal],
              [gesture]: nextAction
            }
          },
          toast: `${gesture}: ${nextAction}`
        };
      });
    },
    onCustomizePedal() {
      lightTapFeedback();
      setHmiState((current) => ({ ...current, pedalMaps: { ...current.pedalMaps, [current.selectedPedal]: { ...defaultPedalMap } }, toast: "Pedal map reset" }));
    },
    onOpenSystemPanel(panel) {
      lightTapFeedback();
      if (panel === "Network") {
        wifi.openSheet();
      }
      setHmiState((current) => ({ ...current, systemPanel: panel, systemChecks: panel === "Diagnostics" ? current.systemChecks + 1 : current.systemChecks, toast: panel === "Diagnostics" ? "Diagnostics complete" : `${panel} opened` }));
    },
    onAssignDisplayPort(connector, role) {
      lightTapFeedback();
      setHmiState((current) => ({
        ...current,
        displayPorts: current.displayPorts.map((port) => {
          if (port.connector === connector) return { ...port, role };
          if (role !== "none" && port.role === role) return { ...port, role: "none" };
          return port;
        }),
        systemPanel: "Display Routing",
        toast: `Routing ${connector} updated`
      }));
      void pushDisplayRoutingPatch(connector, role);
    }
  };

  return (
    <main className="designed-app-root">
      <section className="designed-hmi-frame" aria-label={`PULSAR ${page.label}`}>
        {renderDesignedPage({
          page: activePage,
          openPage,
          state: hmiState,
          handlers,
          autoAlign,
          setAutoAlign,
          renderHeader: (title, onBack, home = false) => <HmiHeader title={title} onBack={onBack} home={home} wifiSnapshot={wifi.snapshot} onOpenWifi={wifi.openSheet} />,
          wifiSnapshot: wifi.snapshot,
          onOpenWifi: wifi.openSheet
        })}

        <WifiSheet
          open={wifi.sheetOpen}
          snapshot={wifi.snapshot}
          loading={wifi.loading}
          selectedNetwork={wifi.selectedNetwork}
          password={wifi.password}
          savedPassword={wifi.savedPassword}
          showSavedPassword={wifi.showSavedPassword}
          keyboardOpen={wifi.keyboardOpen}
          keyboardShift={wifi.keyboardShift}
          connectPending={wifi.connectPending}
          connectError={wifi.connectError || wifi.apiError}
          speedTest={wifi.speedTest}
          onSelectNetwork={wifi.selectNetwork}
          onOpenKeyboard={() => {
            if (wifi.selectedNetwork?.requiresPassword && !wifi.selectedNetwork.isConnected) wifi.setKeyboardOpen(true);
          }}
          onCloseKeyboard={() => {
            wifi.setKeyboardOpen(false);
            wifi.setKeyboardShift(false);
          }}
          onKeyboardInput={(key) => {
            wifi.setPassword((current) => current + key);
            if (wifi.keyboardShift) wifi.setKeyboardShift(false);
          }}
          onKeyboardBackspace={wifi.handleKeyboardBackspace}
          onKeyboardClear={wifi.handleKeyboardClear}
          onKeyboardShiftToggle={() => wifi.setKeyboardShift((current) => !current)}
          onToggleSavedPassword={() => wifi.setShowSavedPassword((current) => !current)}
          onConnect={() => {
            void wifi.connectSelected();
          }}
          onDisconnect={() => {
            void wifi.disconnectSelected();
          }}
          onClose={wifi.closeSheet}
        />

        {hmiState.toast ? <div className="hmi-toast" role="status">{hmiState.toast}</div> : null}
      </section>
    </main>
  );
}

export function App() {
  return <AppRoot />;
}
