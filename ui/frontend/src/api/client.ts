import type { CameraControls, DisplayState, PulsarState } from "../types.js";
async function request<T>(url: string, init?: RequestInit): Promise<T> {
    const response = await fetch(url, {
        cache: "no-store",
        headers: { "Content-Type": "application/json", ...(init?.headers ?? {}) },
        ...init,
    });
    if (!response.ok)
        throw new Error(`${response.status} ${response.statusText}`);
    return response.json() as Promise<T>;
}
export const api = {
    state: () => request<PulsarState>("/api/state"),
    camera: (index: 0 | 1, patch: Partial<CameraControls>) => request(`/api/camera/${index}`, { method: "POST", body: JSON.stringify(patch) }),
    display: (patch: Partial<DisplayState>) => request<PulsarState>("/api/display", { method: "POST", body: JSON.stringify(patch) }),
    startRecording: () => request<PulsarState>("/api/recording/start", { method: "POST", body: "{}" }),
    stopRecording: () => request<PulsarState>("/api/recording/stop", { method: "POST", body: "{}" }),
    snapshot: () => request<{
        file: string;
    }>("/api/recording/snapshot", { method: "POST", body: "{}" }),
    robot: (patch: Record<string, number>) => request<PulsarState>("/api/robot", { method: "POST", body: JSON.stringify(patch) }),
};
