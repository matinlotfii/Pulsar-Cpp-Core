import React from "react";
import { CameraControlPage } from "../../components/CameraControlPage.js";
import type { PulsarState } from "../../types.js";
export function RightCamera({ state, refresh }: {
    state: PulsarState;
    refresh: () => Promise<void>;
}) { return <CameraControlPage camera={state.cameras[1]} recording={state.recording} refresh={refresh}/>; }
