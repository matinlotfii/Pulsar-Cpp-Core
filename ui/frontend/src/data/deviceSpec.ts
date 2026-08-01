import type {
  DetailPanel,
  DeviceCard,
  OutputProfile,
  SceneAction,
  SettingsGroup
} from "../types";

export const sceneActions: SceneAction[] = [
  {
    id: "safe-view",
    label: "Safe 2D View",
    description: "Validated 2D fallback with stale-frame protection.",
    metric: "Live 2D",
    icon: "ShieldCheck",
    tone: "green"
  },
  {
    id: "camera-left",
    label: "Camera 1 Control",
    description: "Exposure, gain, white balance, ROI and trigger state.",
    metric: "42 ms",
    icon: "Camera",
    tone: "blue"
  },
  {
    id: "camera-right",
    label: "Camera 2 Control",
    description: "Linked stereo camera controls and diagnostics.",
    metric: "42 ms",
    icon: "Aperture",
    tone: "blue"
  },
  {
    id: "stereo-3d",
    label: "Stereo 3D Calibration",
    description: "Calibration validity, 3D comfort and fallback state.",
    metric: "Valid",
    icon: "Layers3",
    tone: "violet"
  },
  {
    id: "output-routing",
    label: "Output Routing",
    description: "Independent profiles for glasses, LCD, 4K and recorder.",
    metric: "5 paths",
    icon: "Route",
    tone: "orange"
  },
  {
    id: "zoom-focus",
    label: "Zoom And Focus",
    description: "Optical zoom, digital endpoint zoom and AF lock.",
    metric: "2.4x",
    icon: "Focus",
    tone: "green"
  },
  {
    id: "recording",
    label: "Recording And Gallery",
    description: "2D, SBS, dual-track capture, screenshots and exports.",
    metric: "118 min",
    icon: "Clapperboard",
    tone: "red"
  },
  {
    id: "robot-arm",
    label: "Robotic Arm Control",
    description: "Hold-to-move, fine/coarse motion, brakes and limits.",
    metric: "Parked",
    icon: "Bot",
    tone: "slate"
  },
  {
    id: "pedals",
    label: "Wireless Pedals",
    description: "Pairing, battery, RSSI, mapping scope and conflicts.",
    metric: "2 paired",
    icon: "Gamepad2",
    tone: "orange"
  },
  {
    id: "measurement",
    label: "Measurement And 3D",
    description: "Distance, confidence, uncertainty and volume staging.",
    metric: "0.2 mm",
    icon: "Ruler",
    tone: "violet"
  },
  {
    id: "diagnostics",
    label: "Diagnostics And Service",
    description: "Support bundle, USB, thermal, storage and audit state.",
    metric: "Nominal",
    icon: "Wrench",
    tone: "blue"
  },
  {
    id: "settings",
    label: "System Settings",
    description: "Appearance, profiles, users, updates and safe reset.",
    metric: "Ready",
    icon: "Settings",
    tone: "slate"
  }
];

export const deviceCards: DeviceCard[] = [
  {
    id: "glasses-1",
    title: "XREAL Glasses 1",
    status: "Primary surgeon",
    detail: "3D full SBS, overlays on",
    value: "60 Hz",
    icon: "Glasses",
    tone: "green",
    active: true
  },
  {
    id: "glasses-2",
    title: "XREAL Glasses 2",
    status: "Assistant",
    detail: "Independent digital zoom",
    value: "1.2x",
    icon: "Glasses",
    tone: "blue",
    active: true
  },
  {
    id: "touch-lcd",
    title: "Touch LCD",
    status: "Local control",
    detail: "20-inch surgical settings panel",
    value: "Live",
    icon: "Tablet",
    tone: "orange",
    active: true
  },
  {
    id: "display-4k",
    title: "4K Display",
    status: "Observer",
    detail: "Clean 2D feed with safe overlays",
    value: "2160p",
    icon: "Monitor",
    tone: "violet",
    active: true
  },
  {
    id: "recorder",
    title: "Recorder",
    status: "Armed",
    detail: "Dual-track 3D plus screenshots",
    value: "118 min",
    icon: "HardDrive",
    tone: "red",
    active: true
  },
  {
    id: "network",
    title: "Network",
    status: "Local-first",
    detail: "Camera path independent of Wi-Fi",
    value: "LAN",
    icon: "Network",
    tone: "slate",
    active: false
  }
];

export const outputProfiles: OutputProfile[] = [
  {
    id: "g1",
    endpoint: "Glasses 1",
    source: "Stereo pair",
    mode: "3D full SBS",
    overlays: "Safe overlays",
    timing: "Low latency",
    icon: "Glasses"
  },
  {
    id: "g2",
    endpoint: "Glasses 2",
    source: "Stereo pair",
    mode: "3D comfort",
    overlays: "Assistant tools",
    timing: "Locked",
    icon: "Glasses"
  },
  {
    id: "lcd",
    endpoint: "Touch LCD",
    source: "HMI preview",
    mode: "2D monitor",
    overlays: "Full settings",
    timing: "Interactive",
    icon: "Tablet"
  },
  {
    id: "display",
    endpoint: "4K Display",
    source: "Clean feed",
    mode: "2D observer",
    overlays: "Minimal",
    timing: "Stable",
    icon: "Monitor"
  },
  {
    id: "record",
    endpoint: "Recording",
    source: "Stereo + audio",
    mode: "Dual track",
    overlays: "Selectable",
    timing: "Stamped",
    icon: "Disc3"
  }
];

export const settingsGroups: SettingsGroup[] = [
  {
    id: "appearance",
    title: "Appearance And Profiles",
    summary: "Light clinical theme, surgeon layout profiles and reduced motion.",
    items: ["Light theme", "High contrast option", "Surgeon profile hierarchy"],
    icon: "Sparkles",
    tone: "blue"
  },
  {
    id: "routing",
    title: "Display Routing",
    summary: "OutputProfile control for every endpoint without interrupting surgery.",
    items: ["Source mode", "2D/3D mode", "Crop, orientation, overlays and audio"],
    icon: "Route",
    tone: "orange"
  },
  {
    id: "camera",
    title: "Camera Linked Controls",
    summary: "Stereo-safe transactions for exposure, gain, gamma and white balance.",
    items: ["Histogram preview", "USB diagnostics", "Restore preset and compare"],
    icon: "Camera",
    tone: "green"
  },
  {
    id: "recording",
    title: "Recording Policy",
    summary: "2D, overlay, side-by-side and dual-track capture choices.",
    items: ["Codec and storage", "Gallery export/delete", "Voice command grammar"],
    icon: "Clapperboard",
    tone: "red"
  },
  {
    id: "security",
    title: "Users And Security",
    summary: "Roles, audit visibility, signed updates and no secret display.",
    items: ["Surgeon/operator/service roles", "Audit events", "Signed update policy"],
    icon: "Users",
    tone: "violet"
  },
  {
    id: "recovery",
    title: "Diagnostics And Safe Reset",
    summary: "Support bundle, stale-frame policy and validated 2D recovery.",
    items: ["Thermal and frame freshness", "Support bundle preview", "Safe reset"],
    icon: "ShieldCheck",
    tone: "slate"
  }
];

export const detailPanels: DetailPanel[] = [
  {
    id: "safe-view",
    title: "Safe 2D View",
    subtitle: "Never silently show an old surgical frame as live video.",
    metrics: [
      { label: "Frame freshness", value: "Live" },
      { label: "Fallback", value: "Validated 2D" },
      { label: "Recovery", value: "< 3 sec" }
    ],
    actions: ["Stale-frame guard", "2D fallback", "Safe overlays"]
  },
  {
    id: "camera-left",
    title: "Camera 1 Control",
    subtitle: "DAHENG camera controls with live histogram and USB diagnostics.",
    metrics: [
      { label: "Exposure", value: "5.8 ms" },
      { label: "Gain", value: "3.0 dB" },
      { label: "White balance", value: "Linked" }
    ],
    actions: ["ROI", "Pixel format", "Trigger", "Reverse X/Y"]
  },
  {
    id: "camera-right",
    title: "Camera 2 Control",
    subtitle: "Stereo-pair state follows linked transaction rules.",
    metrics: [
      { label: "Skew", value: "0.4 ms" },
      { label: "Focus score", value: "92%" },
      { label: "USB", value: "Nominal" }
    ],
    actions: ["Compare", "Restore preset", "Color transform", "Black level"]
  },
  {
    id: "stereo-3d",
    title: "Stereo 3D Calibration",
    subtitle: "Calibration gates 3D, measurement and comfort controls.",
    metrics: [
      { label: "Calibration", value: "Valid" },
      { label: "3D mode", value: "Full SBS" },
      { label: "Comfort", value: "Neutral" }
    ],
    actions: ["View only", "Expired", "Failed", "2D fallback"]
  },
  {
    id: "output-routing",
    title: "Independent Output Routing",
    subtitle: "Each endpoint keeps its own source, overlays and timing profile.",
    metrics: [
      { label: "Endpoints", value: "5" },
      { label: "Glasses", value: "2" },
      { label: "Recorder", value: "Dual" }
    ],
    actions: ["Source mode", "Orientation", "Crop", "Audio prompt routing"]
  },
  {
    id: "zoom-focus",
    title: "Zoom And Focus",
    subtitle: "Global optical zoom plus endpoint digital zoom and AF lock.",
    metrics: [
      { label: "Optical", value: "2.4x" },
      { label: "Digital G2", value: "1.2x" },
      { label: "AF", value: "Locked" }
    ],
    actions: ["Fit", "Reset", "Near/far stops", "Working distance preset"]
  },
  {
    id: "recording",
    title: "Recording And Gallery",
    subtitle: "Surgical recording, screenshots, gallery exports and voice commands.",
    metrics: [
      { label: "Remaining", value: "118 min" },
      { label: "Mode", value: "Dual track" },
      { label: "Queue", value: "Clear" }
    ],
    actions: ["Screenshot", "Export", "Delete", "Voice grammar"]
  },
  {
    id: "robot-arm",
    title: "Robotic Arm Control",
    subtitle: "Hold-to-move pad, limits, brakes, home, park and visible E-stop.",
    metrics: [
      { label: "State", value: "Parked" },
      { label: "Speed", value: "Fine" },
      { label: "Limits", value: "Clear" }
    ],
    actions: ["Approach", "Retract", "Home", "Emergency stop"]
  },
  {
    id: "pedals",
    title: "Wireless Pedals",
    subtitle: "Two pedal sets with battery, RSSI, firmware and conflict detection.",
    metrics: [
      { label: "Pedal sets", value: "2" },
      { label: "Battery", value: "88%" },
      { label: "RSSI", value: "-52 dBm" }
    ],
    actions: ["Optical zoom", "Record", "Screenshot", "3D/2D toggle"]
  },
  {
    id: "measurement",
    title: "Measurement And 3D",
    subtitle: "Distance, staged area, surface and volume with uncertainty display.",
    metrics: [
      { label: "Confidence", value: "96%" },
      { label: "Uncertainty", value: "0.2 mm" },
      { label: "Calibration", value: "Valid" }
    ],
    actions: ["Point-to-point", "Area", "Surface", "Volume"]
  },
  {
    id: "diagnostics",
    title: "Diagnostics And Service",
    subtitle: "Frame, thermal, storage, audit and service support bundle preview.",
    metrics: [
      { label: "Thermal", value: "42 C" },
      { label: "Storage", value: "72%" },
      { label: "Audit", value: "Clean" }
    ],
    actions: ["Support bundle", "USB bus", "Frame jitter", "Service mode"]
  },
  {
    id: "settings",
    title: "System Settings",
    subtitle: "Appearance, profile, routing, security, updates and safe reset.",
    metrics: [
      { label: "Theme", value: "Light" },
      { label: "Updates", value: "Signed" },
      { label: "Reset", value: "Safe" }
    ],
    actions: ["Profiles", "Users", "Updates", "Safe reset"]
  }
];

export const clinicalStats = [
  { label: "Camera latency", value: "42 ms" },
  { label: "Stereo skew", value: "0.4 ms" },
  { label: "Frame freshness", value: "Live" },
  { label: "Thermal", value: "42 C" }
];

export const pedalMappings = [
  "Pedal 1 rocker: optical zoom",
  "Pedal 1 aux: record / screenshot",
  "Pedal 2 rocker: Glasses 2 digital zoom",
  "Pedal 2 aux: 3D / 2D toggle"
];
