import React from "react";
export function LoadingScreen({ error }: {
    error?: string;
}) {
    return <main className="loading-screen"><div className="loading-orbit"><span /><span /><span /></div><h1>Pulsar C++ Core</h1><p>{error || "Connecting to the real-time camera core…"}</p></main>;
}
