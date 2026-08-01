import { Crosshair, Gauge, Ruler, ScanSearch } from "lucide-react";
import type { ReactNode } from "react";
import { Button as AriaButton } from "react-aria-components";

const measurementTools = [
  { title: "Distance", detail: "Point-to-point overlay", icon: Ruler },
  { title: "Depth Guide", detail: "Stereo alignment reference", icon: Gauge },
  { title: "Target Lock", detail: "Center framing marker", icon: Crosshair }
];

export function MeasurementScreen({
  header,
  onOpenStereo
}: {
  header: ReactNode;
  onOpenStereo: () => void;
}) {
  return (
    <div className="hmi-screen measurement-screen">
      {header}
      <main className="measurement-layout">
        <section className="measurement-overview-card">
          <div>
            <span className="measurement-eyebrow">Intraoperative Tools</span>
            <h2>Measurement</h2>
            <p>Keep calibration, visual guides, and quick distance tools grouped in one dedicated measurement module.</p>
          </div>
          <AriaButton className="measurement-primary-action" onPress={onOpenStereo}>
            <ScanSearch size={22} />
            Open 3D Calibration
          </AriaButton>
        </section>

        <section className="measurement-tool-grid" aria-label="Measurement tools">
          {measurementTools.map(({ title, detail, icon: Icon }) => (
            <article key={title} className="measurement-tool-card">
              <span className="measurement-tool-icon"><Icon size={24} /></span>
              <strong>{title}</strong>
              <small>{detail}</small>
            </article>
          ))}
        </section>
      </main>
    </div>
  );
}
