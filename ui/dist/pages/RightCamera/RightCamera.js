import React from "react";
import { CameraControlPage } from "../../components/CameraControlPage.js";
export function RightCamera({ state, refresh }) { return React.createElement(CameraControlPage, { camera: state.cameras[1], recording: state.recording, refresh: refresh }); }
