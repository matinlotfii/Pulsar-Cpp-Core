import { Film, FolderOpen, Image as ImageIcon, PlayCircle } from "lucide-react";
import type { ReactNode } from "react";
import { Button as AriaButton } from "react-aria-components";

const galleryCollections = [
  { title: "Latest Captures", meta: "12 stills", icon: ImageIcon },
  { title: "Procedure Clips", meta: "4 videos", icon: Film },
  { title: "Archived Cases", meta: "8 folders", icon: FolderOpen }
];

export function GalleryScreen({
  header,
  onOpenLatest,
  onOpenArchive
}: {
  header: ReactNode;
  onOpenLatest: () => void;
  onOpenArchive: () => void;
}) {
  return (
    <div className="hmi-screen gallery-screen">
      {header}
      <main className="gallery-layout">
        <section className="gallery-hero-card">
          <div>
            <span className="gallery-eyebrow">Media Library</span>
            <h2>Gallery</h2>
            <p>Review recent snapshots, recorded clips, and archived procedure sets from one touch-first screen.</p>
          </div>
          <AriaButton className="gallery-primary-action" onPress={onOpenLatest}>
            <PlayCircle size={22} />
            Open Latest
          </AriaButton>
        </section>

        <section className="gallery-collection-grid" aria-label="Gallery collections">
          {galleryCollections.map(({ title, meta, icon: Icon }) => (
            <article key={title} className="gallery-collection-card">
              <span className="gallery-collection-icon"><Icon size={24} /></span>
              <strong>{title}</strong>
              <small>{meta}</small>
            </article>
          ))}
        </section>

        <section className="gallery-footer-actions">
          <AriaButton className="gallery-secondary-action" onPress={onOpenLatest}>Snapshots</AriaButton>
          <AriaButton className="gallery-secondary-action" onPress={onOpenArchive}>Archive</AriaButton>
        </section>
      </main>
    </div>
  );
}
