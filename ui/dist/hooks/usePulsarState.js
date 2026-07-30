import { useCallback, useEffect, useRef, useState } from "react";
import { api } from "../api/client.js";
export function usePulsarState() {
    const [state, setState] = useState(null);
    const [error, setError] = useState("");
    const mounted = useRef(true);
    const refresh = useCallback(async () => {
        try {
            const next = await api.state();
            if (mounted.current) {
                setState(next);
                setError("");
            }
        }
        catch (reason) {
            if (mounted.current)
                setError(reason instanceof Error ? reason.message : "Core unavailable");
        }
    }, []);
    useEffect(() => {
        mounted.current = true;
        void refresh();
        const timer = window.setInterval(() => void refresh(), 1000);
        return () => {
            mounted.current = false;
            window.clearInterval(timer);
        };
    }, [refresh]);
    return { state, error, refresh, setState };
}
