import ReactDOM from "react-dom/client";
import { App } from "./app/App";
import { startRuntimeTelemetry } from "./app/runtime-telemetry";
import "./styles/global.css";
import "./styles/polish.css";

document.documentElement.classList.add("pulsar-realtime-ui", "pulsar-motion-enabled");
startRuntimeTelemetry();

ReactDOM.createRoot(document.getElementById("root") as HTMLElement).render(<App />);
