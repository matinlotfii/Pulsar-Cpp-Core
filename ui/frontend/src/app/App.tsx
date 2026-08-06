import { useEffect, useRef, useState } from "react";
import { HmiHeader } from "./chrome";
import { defaultStereoAutoAlign, requestStereoAutoAlign } from "./camera-stream";
import { renderDesignedPage, type HmiHandlers } from "./exact-screens";
import { lightTapFeedback } from "./feedback";
import { useWifiManager } from "./hooks/use-wifi-manager";
import {
  audioSources,
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
  type ExactPageId,
  type HmiControlState,
  type StereoMode,
  type StereoAutoAlignState
} from "./model";
import { WifiSheet } from "./wifi-sheet";

interface BackendCameraPayload {
  index?: number;
  online?: boolean;
  error?: string;
  controls?: Partial<CameraControlState>;
}

interface BackendStatePayload {
  cameras?: BackendCameraPayload[];
  display?: {
    mainDisplayMode?: "2D" | "3D";
    stereoMode?: "SBS" | "LineInterleaved" | "Line Interleaved";
    swapEyes?: boolean;
  };
  recording?: {
    active?: boolean;
    elapsedSeconds?: number;
    lastFile?: string;
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
  return payload !== null && typeof payload === "object" && ("display" in payload || "cameras" in payload || "recording" in payload);
}

function isBackendCameraPayload(payload: unknown): payload is BackendCameraPayload {
  return payload !== null && typeof payload === "object" && "controls" in payload;
}

function requestErrorMessage(payload: unknown, fallback: string) {
  if (payload !== null && typeof payload === "object" && "error" in payload && typeof payload.error === "string" && payload.error.trim()) {
    return payload.error;
  }
  return fallback;
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
    let alive = true;
    const loadBackendState = async () => {
      try {
        const response = await fetch("/api/state", { cache: "no-store" });
        const payload = await readJsonResponse(response);
        if (!alive || !response.ok || !isBackendStatePayload(payload)) return;
        applyBackendState(payload);
      } catch {
        // Keep the last confirmed state while the backend reconnects.
      }
    };
    void loadBackendState();
    const timer = window.setInterval(loadBackendState, 1000);
    return () => {
      alive = false;
      window.clearInterval(timer);
    };
  }, []);

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
      const mainDisplayMode = payload.display?.mainDisplayMode === "2D" ? "2D" : "3D";
      const nonTouchDisplays = Object.fromEntries(
        Object.entries(current.displays).map(([id, display]) => [
          id,
          id === "touch-lcd" ? display : { ...display, mode: mainDisplayMode }
        ])
      ) as typeof displayDefaults;

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

      const recordingActive = typeof payload.recording?.active === "boolean" ? payload.recording.active : current.recordingActive;
      const recordingElapsed = typeof payload.recording?.elapsedSeconds === "number" ? payload.recording.elapsedSeconds : current.recordingElapsed;
      const recordingCameras = cameras.map((camera) => ({
        ...camera,
        recording: recordingActive,
        status: recordingActive ? "Recording" : camera.status === "Recording" ? "Live" : camera.status
      })) as [CameraControlState, CameraControlState];

      return {
        ...current,
        cameras: recordingCameras,
        displays: nonTouchDisplays,
        recordingActive,
        recordingElapsed,
        stereoMode: uiStereoModeFromBackend(payload.display?.stereoMode),
        eyeSwap: typeof payload.display?.swapEyes === "boolean" ? payload.display.swapEyes : current.eyeSwap
      };
    });
  }

  function showToast(message: string) {
    setHmiState((current) => ({ ...current, toast: message }));
  }

  function applyCameraPayload(cameraIndex: number, payload: BackendCameraPayload, statusMessage: string) {
    setHmiState((current) => {
      const cameras = [...current.cameras] as [CameraControlState, CameraControlState];
      const camera = cameras[cameraIndex];
      const controls = payload.controls;
      cameras[cameraIndex] = {
        ...camera,
        zoom: typeof controls?.zoom === "number" ? controls.zoom : camera.zoom,
        focus: typeof controls?.focus === "number" ? controls.focus : camera.focus,
        brightness: typeof controls?.brightness === "number" ? controls.brightness : camera.brightness,
        whiteBalance: typeof controls?.whiteBalance === "string" ? controls.whiteBalance as CameraControlState["whiteBalance"] : camera.whiteBalance,
        enhance: typeof controls?.enhance === "string" ? controls.enhance as CameraControlState["enhance"] : camera.enhance,
        frozen: typeof controls?.frozen === "boolean" ? controls.frozen : camera.frozen,
        rotation: typeof controls?.rotation === "number" ? controls.rotation : camera.rotation,
        status: statusMessage
      };
      return { ...current, cameras, toast: statusMessage };
    });
  }

  async function pushCameraPatch(cameraIndex: number, patch: Record<string, unknown>, successMessage: string) {
    try {
      const response = await fetch(`/api/camera/${cameraIndex}`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(patch)
      });
      const payload = await readJsonResponse(response);
      if (!response.ok || !isBackendCameraPayload(payload)) {
        throw new Error(requestErrorMessage(payload, "Camera command failed."));
      }
      applyCameraPayload(cameraIndex, payload, successMessage);
      return true;
    } catch (error) {
      showToast(error instanceof Error ? error.message : "Camera command failed.");
      return false;
    }
  }

  async function setRecording(active: boolean) {
    try {
      const response = await fetch(active ? "/api/recording/start" : "/api/recording/stop", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: "{}"
      });
      const payload = await readJsonResponse(response);
      if (!response.ok || !isBackendStatePayload(payload)) {
        throw new Error(requestErrorMessage(payload, active ? "Could not start recording." : "Could not stop recording."));
      }
      applyBackendState(payload);
      showToast(active ? "Recording started" : "Recording stopped");
    } catch (error) {
      showToast(error instanceof Error ? error.message : "Recording command failed.");
    }
  }

  async function takeSnapshot(cameraIndex: number) {
    try {
      const response = await fetch("/api/recording/snapshot", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: "{}"
      });
      const payload = await readJsonResponse(response);
      if (!response.ok) throw new Error(requestErrorMessage(payload, "Snapshot failed."));
      const side = cameraIndex === 0 ? "Left" : "Right";
      showToast(`${side} camera snapshot saved`);
    } catch (error) {
      showToast(error instanceof Error ? error.message : "Snapshot failed.");
    }
  }

  async function pushDisplayPatch(patch: Record<string, unknown>) {
    try {
      const response = await fetch("/api/display", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(patch)
      });
      const payload = await readJsonResponse(response);
      if (!response.ok || !isBackendStatePayload(payload)) {
        throw new Error(requestErrorMessage(payload, "Display command failed."));
      }
      applyBackendState(payload);
    } catch (error) {
      showToast(error instanceof Error ? error.message : "Display command failed.");
    }
  }

  const handlers: HmiHandlers = {
    onCameraAction(cameraIndex, action) {
      lightTapFeedback();
      const camera = hmiState.cameras[cameraIndex];
      if (action === "snapshot") {
        void takeSnapshot(cameraIndex);
        return;
      }
      if (action === "record") {
        void setRecording(!hmiState.recordingActive);
        return;
      }
      if (action === "freeze") {
        const frozen = !camera.frozen;
        void pushCameraPatch(cameraIndex, { frozen }, frozen ? "Frame frozen" : "Live stream resumed");
        return;
      }
      if (action === "rotate") {
        const rotation = (camera.rotation + 90) % 360;
        void pushCameraPatch(cameraIndex, { rotation }, `View rotated ${rotation} deg`);
        return;
      }
      showToast("Advanced controls are active");
    },
    onCameraAdjust(cameraIndex, field, delta) {
      lightTapFeedback();
      const camera = hmiState.cameras[cameraIndex];
      let value: number;
      if (field === "zoom") value = Number(clamp(camera.zoom + delta, 1, 6).toFixed(1));
      else if (field === "focus") value = clamp(camera.focus + delta, -40, 40);
      else value = clamp(camera.brightness + delta, 0, 100);

      void pushCameraPatch(cameraIndex, { [field]: value }, `${field} updated`).then((ok) => {
        if (ok && field === "zoom") {
          void requestStereoAutoAlign("?action=sample").then(setAutoAlign).catch(() => undefined);
        }
      });
    },
    onCameraCycle(cameraIndex, field) {
      lightTapFeedback();
      const camera = hmiState.cameras[cameraIndex];
      if (field === "whiteBalance") {
        const whiteBalance = cycleValue(whiteBalanceModes, camera.whiteBalance);
        void pushCameraPatch(cameraIndex, { whiteBalance }, "White balance updated");
      } else {
        const enhance = cycleValue(enhanceModes, camera.enhance);
        void pushCameraPatch(cameraIndex, { enhance }, "Enhancement updated");
      }
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
        if (id !== "touch-lcd") {
          void pushDisplayPatch({ mainDisplayMode: mode });
        }
        return { ...current, displays: { ...current.displays, [id]: { ...current.displays[id], mode, active: true } }, toast: `${current.displays[id].label}: ${mode}` };
      });
    },
    onDisplayValue(id, field, value) {
      setHmiState((current) => ({ ...current, displays: { ...current.displays, [id]: { ...current.displays[id], [field]: clamp(value, 0, 100), active: true } }, toast: `${field} updated` }));
    },
    onAudioSourceCycle() {
      lightTapFeedback();
      setHmiState((current) => {
        const audioSource = cycleValue(audioSources, current.audioSource);
        return { ...current, audioSource, toast: `Audio source: ${audioSource}` };
      });
    },
    onToggleRecording() {
      lightTapFeedback();
      void setRecording(!hmiState.recordingActive);
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
      setHmiState((current) => ({
        ...current,
        robotStatus: "Adapter required",
        robotVector: command,
        toast: "Robot hardware mapping is not configured"
      }));
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
