import React from "react";
import { Icon } from "./Icon.js";
export function StepControl({ label, value, suffix = "", onChange, min, max, step = 1 }: {
    label: string;
    value: number;
    suffix?: string;
    onChange: (value: number) => void;
    min: number;
    max: number;
    step?: number;
}) {
    const update = (delta: number) => onChange(Math.min(max, Math.max(min, Number((value + delta).toFixed(2)))));
    return (<div className="step-control">
      <div><span>{label}</span><strong>{value}{suffix}</strong></div>
      <div className="step-actions">
        <button onClick={() => update(-step)}><Icon name="minus"/></button>
        <input aria-label={label} type="range" min={min} max={max} step={step} value={value} onChange={(event: Event) => onChange(Number((event.target as HTMLInputElement).value))}/>
        <button onClick={() => update(step)}><Icon name="plus"/></button>
      </div>
    </div>);
}
export function ToggleRow({ label, detail, value, onChange }: {
    label: string;
    detail?: string;
    value: boolean;
    onChange: (value: boolean) => void;
}) {
    return <label className="toggle-row"><span><strong>{label}</strong>{detail && <small>{detail}</small>}</span><input type="checkbox" checked={value} onChange={(event: Event) => onChange((event.target as HTMLInputElement).checked)}/><i /></label>;
}
export function Segmented<T extends string>({ value, options, onChange }: {
    value: T;
    options: readonly T[];
    onChange: (value: T) => void;
}) {
    return <div className="segmented">{options.map((option) => <button key={option} className={option === value ? "is-active" : ""} onClick={() => onChange(option)}>{option}</button>)}</div>;
}
