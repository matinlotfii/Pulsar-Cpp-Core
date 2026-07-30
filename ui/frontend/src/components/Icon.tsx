import React from "react";
import type { SVGProps } from "react";
const paths: Record<string, JSX.Element> = {
    home: <><path d="m3 11 9-8 9 8"/><path d="M5 10v10h14V10"/><path d="M9 20v-6h6v6"/></>,
    camera: <><rect x="3" y="6" width="18" height="13" rx="3"/><path d="m8 6 1.5-3h5L16 6"/><circle cx="12" cy="12.5" r="3.5"/></>,
    stereo: <><rect x="2" y="6" width="9" height="12" rx="2"/><rect x="13" y="6" width="9" height="12" rx="2"/><path d="M11 10h2M11 14h2"/></>,
    display: <><rect x="2" y="3" width="20" height="14" rx="2"/><path d="M8 21h8M12 17v4"/></>,
    record: <><circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="4"/></>,
    robot: <><path d="M5 20h14M8 20v-5l4-3 2-5 4 2"/><circle cx="8" cy="14" r="2"/><circle cx="14" cy="7" r="2"/><circle cx="19" cy="9" r="2"/></>,
    pedal: <><path d="M7 4h10l3 16H4L7 4Z"/><path d="M8 9h8M9 13h6"/></>,
    system: <><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.9l.1.1-2.8 2.8-.1-.1a1.7 1.7 0 0 0-1.9-.3 1.7 1.7 0 0 0-1 1.6v.2h-4V21a1.7 1.7 0 0 0-1-1.6 1.7 1.7 0 0 0-1.9.3l-.1.1L4.2 17l.1-.1a1.7 1.7 0 0 0 .3-1.9A1.7 1.7 0 0 0 3 14H2.8v-4H3a1.7 1.7 0 0 0 1.6-1 1.7 1.7 0 0 0-.3-1.9L4.2 7 7 4.2l.1.1A1.7 1.7 0 0 0 9 4.6a1.7 1.7 0 0 0 1-1.6v-.2h4V3a1.7 1.7 0 0 0 1 1.6 1.7 1.7 0 0 0 1.9-.3l.1-.1L19.8 7l-.1.1a1.7 1.7 0 0 0-.3 1.9 1.7 1.7 0 0 0 1.6 1h.2v4H21a1.7 1.7 0 0 0-1.6 1Z"/></>,
    back: <path d="m15 18-6-6 6-6"/>,
    wifi: <><path d="M5 9a11 11 0 0 1 14 0M8 12.5a6 6 0 0 1 8 0M11 16a2 2 0 0 1 2 0"/><circle cx="12" cy="19" r="1"/></>,
    check: <path d="m5 12 4 4L19 6"/>,
    plus: <path d="M12 5v14M5 12h14"/>,
    minus: <path d="M5 12h14"/>,
};
export function Icon({ name, ...props }: SVGProps<SVGSVGElement> & {
    name: string;
}) {
    return <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" {...props}>{paths[name]}</svg>;
}
