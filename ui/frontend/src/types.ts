export type Tone = "blue" | "green" | "orange" | "red" | "violet" | "slate";

export type IconName =
  | "Activity"
  | "Aperture"
  | "AudioWaveform"
  | "Axis3D"
  | "BadgeCheck"
  | "Bluetooth"
  | "Bot"
  | "Camera"
  | "CircleGauge"
  | "CircleStop"
  | "Clapperboard"
  | "Crosshair"
  | "Disc3"
  | "Eye"
  | "Focus"
  | "Gamepad2"
  | "Gauge"
  | "Glasses"
  | "HardDrive"
  | "Image"
  | "Layers3"
  | "Monitor"
  | "Move3D"
  | "Network"
  | "Power"
  | "Radar"
  | "RefreshCcw"
  | "Route"
  | "Ruler"
  | "ScanLine"
  | "Settings"
  | "ShieldCheck"
  | "SlidersHorizontal"
  | "Sparkles"
  | "Tablet"
  | "UploadCloud"
  | "Usb"
  | "Users"
  | "WandSparkles"
  | "Wifi"
  | "Wrench";

export interface SceneAction {
  id: string;
  label: string;
  description: string;
  metric: string;
  icon: IconName;
  tone: Tone;
}

export interface DeviceCard {
  id: string;
  title: string;
  status: string;
  detail: string;
  value: string;
  icon: IconName;
  tone: Tone;
  active: boolean;
}

export interface OutputProfile {
  id: string;
  endpoint: string;
  source: string;
  mode: string;
  overlays: string;
  timing: string;
  icon: IconName;
}

export interface SettingsGroup {
  id: string;
  title: string;
  summary: string;
  items: string[];
  icon: IconName;
  tone: Tone;
}

export interface DetailPanel {
  id: string;
  title: string;
  subtitle: string;
  metrics: Array<{ label: string; value: string }>;
  actions: string[];
}
