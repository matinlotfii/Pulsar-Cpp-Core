declare namespace JSX {
    interface IntrinsicElements {
        [name: string]: any;
    }
    interface Element {
    }
    interface IntrinsicAttributes {
        key?: string | number;
    }
}
declare module "react" {
    export type CSSProperties = Record<string, string | number>;
    export type SVGProps<T> = Record<string, any>;
    export function useState<T>(initial: T | (() => T)): [
        T,
        (next: T | ((current: T) => T)) => void
    ];
    export function useEffect(effect: () => void | (() => void), deps?: readonly unknown[]): void;
    export function useRef<T>(initial: T): {
        current: T;
    };
    export function useMemo<T>(factory: () => T, deps: readonly unknown[]): T;
    export function useCallback<T extends (...args: any[]) => any>(callback: T, deps: readonly unknown[]): T;
    export function createContext<T>(value: T): any;
    export function useContext<T>(context: any): T;
    const React: {
        createElement: (...args: any[]) => any;
        Fragment: any;
        StrictMode: any;
    };
    export default React;
}
declare module "react-dom/client" {
    export interface Root {
        render(node: any): void;
        unmount(): void;
    }
    export function createRoot(element: Element): Root;
    const ReactDOM: {
        createRoot: typeof createRoot;
    };
    export default ReactDOM;
}
