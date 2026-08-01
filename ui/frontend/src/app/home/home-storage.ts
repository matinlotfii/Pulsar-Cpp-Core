import { defaultHomeControls, homeLayoutStorageKey, type HomeControlDefinition } from "../model";

export function getInitialHomeControls() {
  if (typeof window === "undefined") {
    return defaultHomeControls;
  }

  try {
    const savedOrder = JSON.parse(window.localStorage.getItem(homeLayoutStorageKey) || "[]") as unknown;
    if (!Array.isArray(savedOrder)) {
      return defaultHomeControls;
    }
    const controlsById = new Map(defaultHomeControls.map((control) => [control.id, control]));
    const orderedControls = savedOrder
      .map((id) => (typeof id === "string" ? controlsById.get(id) : undefined))
      .filter((control): control is HomeControlDefinition => Boolean(control));
    const missingControls = defaultHomeControls.filter((control) => !orderedControls.some((saved) => saved.id === control.id));
    return [...orderedControls, ...missingControls];
  } catch {
    return defaultHomeControls;
  }
}

export function saveHomeControlsLayout(nextControls: HomeControlDefinition[]) {
  if (typeof window === "undefined") return;
  window.localStorage.setItem(homeLayoutStorageKey, JSON.stringify(nextControls.map((control) => control.id)));
}
