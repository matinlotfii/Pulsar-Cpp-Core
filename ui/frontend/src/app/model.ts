import type { IconName, Tone } from "../types";

export type ExactPageId =
  | "home"
  | "left-camera"
  | "right-camera"
  | "stereo-3d"
  | "measurement"
  | "display-settings"
  | "recording"
  | "gallery"
  | "robotic-arm"
  | "pedals"
  | "system";

export interface ExactPage {
  id: ExactPageId;
  label: string;
}

export const exactPages: Record<ExactPageId, ExactPage> = {
  home: { id: "home", label: "Home" },
  "left-camera": { id: "left-camera", label: "Left Camera" },
  "right-camera": { id: "right-camera", label: "Right Camera" },
  "stereo-3d": { id: "stereo-3d", label: "3D SBS" },
  measurement: { id: "measurement", label: "Measurement" },
  "display-settings": { id: "display-settings", label: "Display Settings" },
  recording: { id: "recording", label: "Recording" },
  gallery: { id: "gallery", label: "Gallery" },
  "robotic-arm": { id: "robotic-arm", label: "Robotic Arm" },
  pedals: { id: "pedals", label: "Pedals" },
  system: { id: "system", label: "System" }
};

export type CameraField = "zoom" | "focus" | "brightness";
export type CameraCycleField = "whiteBalance" | "enhance";
export type WhiteBalanceMode = "Auto" | "Warm" | "Cool" | "Manual";
export type EnhanceMode = "Low" | "Medium" | "High";
export type DisplayEndpointId = "display" | "ar-glass-1" | "ar-glass-2";
export type DisplayMode = "2D" | "3D";
export type DisplayPortRole = "none" | "ui" | "display" | "ar-glass-1" | "ar-glass-2";
export type AudioSource = "Camera Left" | "Camera Right" | "Mixed";
export type SaveTarget = "Internal Storage" | "External USB" | "Network Share";
export type StereoMode = "SBS" | "Line Interleaved";
export type StereoSettingsPanel = "mode" | "calibration" | "auto-calibration" | "depth";
export type StereoCalibrationStatus = "idle" | "detecting" | "running" | "success" | "failed";
export type PedalSide = "left" | "right";
export type PedalGesture =
  | "Short Press"
  | "Long Press"
  | "Double Press"
  | "Hold"
  | "Hold + Left"
  | "Hold + Right";
export type PedalAction = "Snapshot" | "Record" | "Freeze" | "Zoom In" | "Zoom Out" | "Focus Near" | "Focus Far";
export type SystemPanelId =
  | "Storage"
  | "Network"
  | "System Update"
  | "Temperature"
  | "Fan Speed"
  | "Display Routing"
  | "Diagnostics"
  | "Logs"
  | "About";

export interface WifiNetwork {
  id: string;
  ssid: string;
  bssid: string;
  signal: number;
  security: string;
  requiresPassword: boolean;
  isConnected: boolean;
  channel: string;
  frequency: string;
  rate: string;
}

export interface WifiSnapshot {
  available: boolean;
  device: string | null;
  state: string;
  connected: boolean;
  ssid: string | null;
  signal: number;
  security: string;
  details: {
    connection: string;
    ipv4: string[];
    ipv6: string[];
    dns: string[];
    gateway4: string;
    gateway6: string;
    password?: string;
  } | null;
  usage: {
    rxBytes: number;
    txBytes: number;
    totalBytes: number;
    sessionBytes: number;
    connectedAt: string;
  } | null;
  networks: WifiNetwork[];
}

export type StereoAutoAlignTrigger = "Hold Button" | "Pedal" | "Hardware Zoom" | "Manual";

export interface StereoAutoAlignState {
  enabled: boolean;
  active: boolean;
  trigger: StereoAutoAlignTrigger;
  xOffset: number;
  yOffset: number;
  xRatio: number;
  yRatio: number;
  quality: number;
  samples: number;
  status: string;
  message: string;
}

export interface HomeControlDefinition {
  id: string;
  icon: IconName;
  title: string;
  subtitle: string;
  tone: Tone;
  page: ExactPageId;
}

export const homeLayoutStorageKey = "pulsar.home.layout.v3";

export const defaultHomeControls: HomeControlDefinition[] = [
  { id: "left-camera", icon: "Camera", title: "Left Camera", subtitle: "Live", tone: "green", page: "left-camera" },
  { id: "right-camera", icon: "Camera", title: "Right Camera", subtitle: "Live", tone: "blue", page: "right-camera" },
  { id: "stereo-3d", icon: "Layers3", title: "3D (SBS)", subtitle: "Stereo", tone: "violet", page: "stereo-3d" },
  { id: "recording", icon: "Clapperboard", title: "Recording", subtitle: "Capture", tone: "red", page: "recording" },
  { id: "display-settings", icon: "Monitor", title: "Display", subtitle: "Routing", tone: "green", page: "display-settings" },
  { id: "gallery", icon: "Image", title: "Gallery", subtitle: "Media", tone: "blue", page: "gallery" },
  { id: "measurement", icon: "Ruler", title: "Measurement", subtitle: "Tools", tone: "orange", page: "measurement" },
  { id: "robotic-arm", icon: "Bot", title: "Robotic Arm", subtitle: "Control", tone: "violet", page: "robotic-arm" },
  { id: "pedals", icon: "Gamepad2", title: "Pedals", subtitle: "Wireless", tone: "blue", page: "pedals" },
  { id: "system", icon: "Settings", title: "System", subtitle: "Settings", tone: "slate", page: "system" }
];

export interface CameraControlState {
  zoom: number;
  focus: number;
  brightness: number;
  whiteBalance: WhiteBalanceMode;
  enhance: EnhanceMode;
  frozen: boolean;
  recording: boolean;
  rotation: number;
  status: string;
}

export interface DisplayEndpointState {
  id: DisplayEndpointId;
  icon: IconName;
  label: string;
  connector: string;
  connected: boolean;
  mode: DisplayMode;
  volume: number;
  muted: boolean;
  buttonSoundEnabled: boolean;
  active: boolean;
}

export interface DisplayPortState {
  connector: string;
  connected: boolean;
  primary: boolean;
  role: DisplayPortRole;
  resolution: string;
  position: string;
  refreshRate: string;
  summary: string;
}

export interface SystemInfoState {
  storageFreeBytes: number;
  storageTotalBytes: number;
  storageUsedPercent: number;
  storageMount: string;
  updateStatus: string;
  temperatureC: number;
  fanRpm: number;
  fanMode: string;
  logLines: number;
  uptimeSeconds: number;
  cpuLoad: number;
  memoryUsedPercent: number;
  processRssBytes: number;
  connectedPortCount: number;
  totalPortCount: number;
  restartPending: boolean;
  aboutProduct: string;
  aboutCompany: string;
  aboutWebsite: string;
  aboutSummary: string;
}

export type PedalMap = Record<PedalGesture, PedalAction>;

export interface HmiControlState {
  cameras: [CameraControlState, CameraControlState];
  activeDisplay: DisplayEndpointId;
  displays: Record<DisplayEndpointId, DisplayEndpointState>;
  audioSource: AudioSource;
  saveTarget: SaveTarget;
  recordingActive: boolean;
  recordingElapsed: number;
  stereoMode: StereoMode;
  stereoDepth: number;
  stereoRotation: number;
  eyeSwap: boolean;
  selectedPedal: PedalSide;
  pedalMaps: Record<PedalSide, PedalMap>;
  robotStatus: string;
  robotVector: string;
  systemPanel: SystemPanelId;
  systemChecks: number;
  systemInfo: SystemInfoState;
  displayPorts: DisplayPortState[];
  toast: string;
}

export const whiteBalanceModes: WhiteBalanceMode[] = ["Auto", "Warm", "Cool", "Manual"];
export const enhanceModes: EnhanceMode[] = ["Low", "Medium", "High"];
export const audioSources: AudioSource[] = ["Camera Left", "Camera Right", "Mixed"];
export const saveTargets: SaveTarget[] = ["Internal Storage", "External USB", "Network Share"];
export const stereoRotations = [0, 90, 180, 270];
export const pedalActions: PedalAction[] = ["Snapshot", "Record", "Freeze", "Zoom In", "Zoom Out", "Focus Near", "Focus Far"];

export const displayDefaults: Record<DisplayEndpointId, DisplayEndpointState> = {
  display: { id: "display", icon: "Monitor", label: "Display", connector: "", connected: false, mode: "2D", volume: 125, muted: false, buttonSoundEnabled: true, active: true },
  "ar-glass-1": { id: "ar-glass-1", icon: "Glasses", label: "AR Glass 1", connector: "", connected: false, mode: "3D", volume: 125, muted: false, buttonSoundEnabled: true, active: false },
  "ar-glass-2": { id: "ar-glass-2", icon: "Glasses", label: "AR Glass 2", connector: "", connected: false, mode: "3D", volume: 125, muted: false, buttonSoundEnabled: true, active: false }
};

export const initialSystemInfo: SystemInfoState = {
  storageFreeBytes: 0,
  storageTotalBytes: 0,
  storageUsedPercent: 0,
  storageMount: "/data",
  updateStatus: "Checking",
  temperatureC: 0,
  fanRpm: 0,
  fanMode: "Auto",
  logLines: 0,
  uptimeSeconds: 0,
  cpuLoad: 0,
  memoryUsedPercent: 0,
  processRssBytes: 0,
  connectedPortCount: 0,
  totalPortCount: 0,
  restartPending: false,
  aboutProduct: "PULSAR",
  aboutCompany: "NAP Tech",
  aboutWebsite: "nap-tech.com",
  aboutSummary: "3D microscope platform"
};

export const defaultPedalMap: PedalMap = {
  "Short Press": "Snapshot",
  "Long Press": "Record",
  "Double Press": "Freeze",
  Hold: "Zoom In",
  "Hold + Left": "Focus Near",
  "Hold + Right": "Focus Far"
};

export const initialHmiState: HmiControlState = {
  cameras: [
    { zoom: 2.1, focus: 15, brightness: 60, whiteBalance: "Auto", enhance: "Medium", frozen: false, recording: false, rotation: 0, status: "Live" },
    { zoom: 2.1, focus: 15, brightness: 60, whiteBalance: "Auto", enhance: "Medium", frozen: false, recording: false, rotation: 0, status: "Live" }
  ],
  activeDisplay: "display",
  displays: displayDefaults,
  audioSource: "Camera Left",
  saveTarget: "Internal Storage",
  recordingActive: true,
  recordingElapsed: 12 * 60 + 35,
  stereoMode: "SBS",
  stereoDepth: 5,
  stereoRotation: 0,
  eyeSwap: true,
  selectedPedal: "left",
  pedalMaps: {
    left: { ...defaultPedalMap },
    right: { ...defaultPedalMap, "Short Press": "Freeze", "Long Press": "Zoom Out" }
  },
  robotStatus: "Ready",
  robotVector: "Home",
  systemPanel: "Storage",
  systemChecks: 0,
  systemInfo: initialSystemInfo,
  displayPorts: [],
  toast: ""
};
