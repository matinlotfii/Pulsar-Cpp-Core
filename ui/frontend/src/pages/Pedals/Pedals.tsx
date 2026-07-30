import React from "react";
import { useState } from "react";
import { Icon } from "../../components/Icon.js";
const actions = ["Snapshot", "Record", "Freeze", "Zoom In", "Zoom Out", "Focus Near", "Focus Far"];
const gestures = ["Left Short Press", "Left Long Press", "Left Double Press", "Right Short Press", "Right Long Press", "Right Double Press"];
export function Pedals() {
    const [mapping, setMapping] = useState(["Snapshot", "Freeze", "Zoom Out", "Record", "Zoom In", "Focus Near"]);
    return <div className="pedals-page page-enter"><section className="pedal-visual glass-panel"><div className="pedal-stage"><div className="pedal left"><Icon name="pedal"/><span>LEFT</span></div><div className="pedal right"><Icon name="pedal"/><span>RIGHT</span></div></div><span className="eyebrow">FOOT CONTROL</span><h2>Hands-free actions</h2><p>Mappings are separated in their own page and stylesheet, ready to be connected to the final USB or GPIO pedal input module in the C++ core.</p></section><section className="pedal-map glass-panel"><div className="pedal-map-header"><div><span className="eyebrow">GESTURE MAP</span><h2>Pedal assignments</h2></div><button onClick={() => setMapping(["Snapshot", "Freeze", "Zoom Out", "Record", "Zoom In", "Focus Near"])}>Reset</button></div>{gestures.map((gesture, index) => <label className="pedal-row" key={gesture}><span><b>{gesture}</b><small>{index < 3 ? "Left pedal" : "Right pedal"}</small></span><select value={mapping[index]} onChange={(event: Event) => setMapping((current) => current.map((value, i) => i === index ? (event.target as HTMLSelectElement).value : value))}>{actions.map((action) => <option key={action}>{action}</option>)}</select></label>)}</section></div>;
}
