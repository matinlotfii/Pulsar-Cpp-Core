import type { ReactNode } from "react";
import { HomeScreen } from "./home-screen";
import type {
  CameraCycleField,
  CameraField,
  DisplayEndpointId,
  DisplayPortRole,
  DisplayMode,
  ExactPageId,
  HmiControlState,
  PedalGesture,
  PedalSide,
  SaveTarget,
  StereoAutoAlignState,
  StereoMode,
  SystemPanelId,
  WifiSnapshot
} from "./model";
import { CameraScreen } from "./screens/camera-screen";
import { DisplayScreen } from "./screens/display-screen";
import { GalleryScreen } from "./screens/gallery-screen";
import { MeasurementScreen } from "./screens/measurement-screen";
import { PedalsScreen } from "./screens/pedals-screen";
import { RecordingScreen } from "./screens/recording-screen";
import { RoboticArmScreen } from "./screens/robotic-arm-screen";
import { StereoScreen } from "./screens/stereo-screen";
import { SystemScreen } from "./screens/system-screen";

export interface HmiHandlers {
  onCameraAction: (cameraIndex: 0 | 1, action: "snapshot" | "record" | "freeze" | "rotate" | "more") => void;
  onCameraAdjust: (cameraIndex: 0 | 1, field: CameraField, delta: number) => void;
  onCameraCycle: (cameraIndex: 0 | 1, field: CameraCycleField) => void;
  onStereoModeChange: (mode: StereoMode) => void;
  onStereoDepthChange: (depth: number) => void;
  onStereoRotationCycle: () => void;
  onEyeSwapToggle: () => void;
  onSelectDisplay: (id: DisplayEndpointId) => void;
  onDisplayMode: (id: DisplayEndpointId, mode: DisplayMode) => void;
  onDisplayVolume: (id: DisplayEndpointId, value: number) => void;
  onDisplayMuteToggle: (id: DisplayEndpointId) => void;
  onDisplayButtonSoundToggle: (id: DisplayEndpointId) => void;
  onToggleRecording: () => void;
  onSaveTargetCycle: () => void;
  onOpenRecordings: () => void;
  onRobotCommand: (command: string) => void;
  onSelectPedal: (side: PedalSide) => void;
  onCyclePedalMapping: (gesture: PedalGesture) => void;
  onCustomizePedal: () => void;
  onOpenSystemPanel: (panel: SystemPanelId) => void;
  onAssignDisplayPort: (connector: string, role: DisplayPortRole) => void;
}

export function renderDesignedPage({
  page,
  openPage,
  state,
  handlers,
  autoAlign,
  setAutoAlign,
  renderHeader,
  wifiSnapshot,
  onOpenWifi
}: {
  page: ExactPageId;
  openPage: (page: ExactPageId) => void;
  state: HmiControlState;
  handlers: HmiHandlers;
  autoAlign: StereoAutoAlignState;
  setAutoAlign: (state: StereoAutoAlignState) => void;
  renderHeader: (title: string, onBack?: () => void, home?: boolean) => ReactNode;
  wifiSnapshot: WifiSnapshot | null;
  onOpenWifi: () => void;
}) {
  const back = () => openPage("home");

  switch (page) {
    case "left-camera":
      return <CameraScreen header={renderHeader("Left Camera", back)} cameraIndex={0} camera={state.cameras[0]} autoAlign={autoAlign} onCameraAction={handlers.onCameraAction} onCameraAdjust={handlers.onCameraAdjust} onCameraCycle={handlers.onCameraCycle} />;
    case "right-camera":
      return <CameraScreen header={renderHeader("Right Camera", back)} cameraIndex={1} camera={state.cameras[1]} autoAlign={autoAlign} onCameraAction={handlers.onCameraAction} onCameraAdjust={handlers.onCameraAdjust} onCameraCycle={handlers.onCameraCycle} />;
    case "stereo-3d":
      return <StereoScreen header={renderHeader("3D", back)} mode={state.stereoMode} depth={state.stereoDepth} rotation={state.stereoRotation} eyeSwap={state.eyeSwap} autoAlign={autoAlign} setAutoAlign={setAutoAlign} onModeChange={handlers.onStereoModeChange} onDepthChange={handlers.onStereoDepthChange} onRotationCycle={handlers.onStereoRotationCycle} onEyeSwapToggle={handlers.onEyeSwapToggle} />;
    case "measurement":
      return <MeasurementScreen header={renderHeader("Measurement", back)} onOpenStereo={() => openPage("stereo-3d")} />;
    case "display-settings":
      return <DisplayScreen header={renderHeader("Display Settings", back)} state={state} onSelectDisplay={handlers.onSelectDisplay} onDisplayMode={handlers.onDisplayMode} onDisplayVolume={handlers.onDisplayVolume} onDisplayMuteToggle={handlers.onDisplayMuteToggle} />;
    case "recording":
      return <RecordingScreen header={renderHeader("Recording", back)} recordingActive={state.recordingActive} elapsed={state.recordingElapsed} saveTarget={state.saveTarget as SaveTarget} onToggleRecording={handlers.onToggleRecording} onSaveTargetCycle={handlers.onSaveTargetCycle} onOpenRecordings={handlers.onOpenRecordings} />;
    case "gallery":
      return <GalleryScreen header={renderHeader("Gallery", back)} onOpenLatest={handlers.onOpenRecordings} onOpenArchive={handlers.onOpenRecordings} />;
    case "robotic-arm":
      return <RoboticArmScreen header={renderHeader("Robotic Arm Control", back)} status={state.robotStatus} vector={state.robotVector} onCommand={handlers.onRobotCommand} />;
    case "pedals":
      return <PedalsScreen header={renderHeader("Pedals", back)} selectedPedal={state.selectedPedal} mappings={state.pedalMaps[state.selectedPedal]} onSelectPedal={handlers.onSelectPedal} onCycleMapping={handlers.onCyclePedalMapping} onCustomize={handlers.onCustomizePedal} />;
    case "system":
      return <SystemScreen header={renderHeader("System", back)} state={state} activePanel={state.systemPanel} checkCount={state.systemChecks} onOpenPanel={handlers.onOpenSystemPanel} onAssignDisplayPort={handlers.onAssignDisplayPort} snapshot={wifiSnapshot} onOpenWifi={onOpenWifi} />;
    default:
      return <HomeScreen header={renderHeader("Home", undefined, true)} openPage={openPage} />;
  }
}
