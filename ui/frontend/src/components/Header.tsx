import React from "react";
import { useEffect, useState } from "react";
import { Icon } from "./Icon.js";
export function Header({ title, onBack }: {
    title: string;
    onBack?: () => void;
}) {
    const [time, setTime] = useState(new Date());
    useEffect(() => {
        const timer = window.setInterval(() => setTime(new Date()), 1000);
        return () => window.clearInterval(timer);
    }, []);
    return (<header className="top-header">
      <div className="header-title">
        {onBack ? <button className="icon-button" onClick={onBack} aria-label="Back"><Icon name="back"/></button> : <div className="pulsar-mark">P</div>}
        <div><span className="header-kicker">PULSAR EXOSCOPE</span><strong>{title}</strong></div>
      </div>
      <div className="header-status">
        <span className="status-dot"/>
        <Icon name="wifi"/>
        <time>{time.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}</time>
      </div>
    </header>);
}
