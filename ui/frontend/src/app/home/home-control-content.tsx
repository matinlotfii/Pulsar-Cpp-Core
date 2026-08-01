import type { HomeControlDefinition } from "../model";
import { homeIconMap } from "./home-icons";

export function HomeControlContent({ control }: { control: HomeControlDefinition }) {
  const Icon = homeIconMap[control.icon as keyof typeof homeIconMap];
  return (
    <>
      <span className="home-launch-icon">
        <Icon size={29} strokeWidth={2.15} />
      </span>
      <span className="home-launch-copy">
        <strong>{control.title}</strong>
      </span>
    </>
  );
}
