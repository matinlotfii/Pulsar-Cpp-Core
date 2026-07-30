async function request(url, init) {
    const response = await fetch(url, {
        cache: "no-store",
        headers: { "Content-Type": "application/json", ...(init?.headers ?? {}) },
        ...init,
    });
    if (!response.ok)
        throw new Error(`${response.status} ${response.statusText}`);
    return response.json();
}
export const api = {
    state: () => request("/api/state"),
    camera: (index, patch) => request(`/api/camera/${index}`, { method: "POST", body: JSON.stringify(patch) }),
    display: (patch) => request("/api/display", { method: "POST", body: JSON.stringify(patch) }),
    startRecording: () => request("/api/recording/start", { method: "POST", body: "{}" }),
    stopRecording: () => request("/api/recording/stop", { method: "POST", body: "{}" }),
    snapshot: () => request("/api/recording/snapshot", { method: "POST", body: "{}" }),
    robot: (patch) => request("/api/robot", { method: "POST", body: JSON.stringify(patch) }),
};
