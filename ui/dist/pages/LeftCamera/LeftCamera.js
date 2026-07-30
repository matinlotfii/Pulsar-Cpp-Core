import React from "react";
import { CameraControlPage } from "../../components/CameraControlPage.js";
export function LeftCamera({ state, refresh }) { return React.createElement(CameraControlPage, { camera: state.cameras[0], recording: state.recording, refresh: refresh }); }
