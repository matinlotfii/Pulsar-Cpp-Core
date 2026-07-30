export type PageId = "home" | "left-camera" | "right-camera" | "stereo-3d" | "display-settings" | "recording" | "robotic-arm" | "pedals" | "system";
export interface CameraControls {
    zoom: number;
    focus: number;
    brightness: number;
    exposureUs: number;
    gainDb: number;
    autoExposure: boolean;
    whiteBalance: "Auto" | "Warm" | "Cool" | "Manual";
    enhance: "Low" | "Medium" | "High";
    rotation: number;
    frozen: boolean;
}
export interface CameraState {
    index: number;
    online: boolean;
    label: string;
    model: string;
    serial: string;
    error: string;
    fps: number;
    width: number;
    height: number;
    controls: CameraControls;
}
export interface DisplayState {
    swapEyes: boolean;
    gapPx: number;
    mirrorLeft: boolean;
    mirrorRight: boolean;
    stereoMode: "SBS" | "LineInterleaved";
    targetFps: number;
}
export interface RecordingState {
    active: boolean;
    lastFile: string;
    elapsedSeconds: number;
}
export interface RobotState {
    motors: number[];
}
export interface SystemState {
    memoryUsedPercent: number;
    cpuLoad: number;
    processRssBytes: number;
    uptimeSeconds: number;
    version: string;
}
export interface PulsarState {
    revision: number;
    cameras: [
        CameraState,
        CameraState
    ];
    display: DisplayState;
    recording: RecordingState;
    robot: RobotState;
    system: SystemState;
}
