const Fragment = Symbol("Fragment");
let rootContainer = null;
let rootVNode = null;
let oldTree = null;
let scheduled = false;
let currentHooks = null;
let hookIndex = 0;
const hookBuckets = new Map();
let pendingEffects = [];

function flatten(input, output = []) {
  for (const item of input) {
    if (Array.isArray(item)) flatten(item, output);
    else if (item !== null && item !== undefined && item !== false && item !== true) output.push(item);
  }
  return output;
}

function createElement(type, props, ...children) {
  return { type, props: { ...(props || {}), children: flatten(children) }, key: props?.key ?? null };
}

function depsChanged(previous, next) {
  if (!previous || !next || previous.length !== next.length) return true;
  return next.some((value, index) => !Object.is(value, previous[index]));
}

function scheduleRender() {
  if (scheduled) return;
  scheduled = true;
  queueMicrotask(() => {
    scheduled = false;
    performRender();
  });
}

function useState(initial) {
  if (!currentHooks) throw new Error("Hooks must be called inside a component");
  const hooks = currentHooks;
  const index = hookIndex++;
  if (!(index in hooks)) hooks[index] = typeof initial === "function" ? initial() : initial;
  const setState = (next) => {
    const value = typeof next === "function" ? next(hooks[index]) : next;
    if (!Object.is(value, hooks[index])) {
      hooks[index] = value;
      scheduleRender();
    }
  };
  return [hooks[index], setState];
}

function useRef(initial) {
  if (!currentHooks) throw new Error("Hooks must be called inside a component");
  const index = hookIndex++;
  if (!(index in currentHooks)) currentHooks[index] = { current: initial };
  return currentHooks[index];
}

function useEffect(effect, deps) {
  if (!currentHooks) throw new Error("Hooks must be called inside a component");
  const hooks = currentHooks;
  const index = hookIndex++;
  const previous = hooks[index];
  if (!previous || depsChanged(previous.deps, deps)) {
    pendingEffects.push(() => {
      if (previous?.cleanup) previous.cleanup();
      const cleanup = effect();
      hooks[index] = { deps, cleanup: typeof cleanup === "function" ? cleanup : undefined };
    });
  }
}

function useMemo(factory, deps) {
  if (!currentHooks) throw new Error("Hooks must be called inside a component");
  const index = hookIndex++;
  const previous = currentHooks[index];
  if (!previous || depsChanged(previous.deps, deps)) currentHooks[index] = { deps, value: factory() };
  return currentHooks[index].value;
}

function useCallback(callback, deps) { return useMemo(() => callback, deps); }
function createContext(defaultValue) { return { value: defaultValue, Provider: ({ value, children }) => { this.value = value; return children; } }; }
function useContext(context) { return context.value; }

function resolve(vnode, path = "0") {
  if (vnode === null || vnode === undefined || vnode === false || vnode === true) return null;
  if (typeof vnode === "string" || typeof vnode === "number") return { type: "#text", value: String(vnode), key: null };
  if (Array.isArray(vnode)) return { type: Fragment, props: { children: flatten(vnode) }, key: null, children: flatten(vnode).map((child, i) => resolve(child, `${path}.${i}`)).filter(Boolean) };
  if (typeof vnode.type === "function") {
    const componentId = `${path}:${vnode.type.name || "Anonymous"}:${String(vnode.key ?? "")}`;
    const previousHooks = currentHooks;
    const previousIndex = hookIndex;
    currentHooks = hookBuckets.get(componentId) || [];
    hookBuckets.set(componentId, currentHooks);
    hookIndex = 0;
    const rendered = vnode.type(vnode.props || {});
    currentHooks = previousHooks;
    hookIndex = previousIndex;
    return resolve(rendered, `${path}.c`);
  }
  if (vnode.type === Fragment) {
    const children = flatten(vnode.props?.children || []).map((child, i) => resolve(child, `${path}.${i}`)).filter(Boolean);
    return { type: Fragment, props: {}, key: vnode.key, children };
  }
  const children = flatten(vnode.props?.children || []).map((child, i) => resolve(child, `${path}.${vnode.key ?? i}`)).filter(Boolean);
  return { type: vnode.type, props: vnode.props || {}, key: vnode.key, children };
}

function setProp(element, key, value, oldValue, isSvg) {
  if (key === "children" || key === "key") return;
  if (key === "className") { element.setAttribute("class", value || ""); return; }
  if (key === "style" && value && typeof value === "object") {
    const previous = oldValue && typeof oldValue === "object" ? oldValue : {};
    for (const name of Object.keys(previous)) if (!(name in value)) element.style[name] = "";
    for (const [name, styleValue] of Object.entries(value)) element.style[name] = typeof styleValue === "number" && !["opacity","zIndex","fontWeight","lineHeight","flex","order"].includes(name) ? `${styleValue}px` : styleValue;
    return;
  }
  if (key.startsWith("on") && typeof value === "function") { element[key.toLowerCase()] = value; return; }
  if (key.startsWith("on") && !value) { element[key.toLowerCase()] = null; return; }
  if (key === "checked" || key === "value" || key === "selected" || key === "disabled") { element[key] = value ?? false; return; }
  const attribute = isSvg ? key.replace(/[A-Z]/g, (letter) => `-${letter.toLowerCase()}`) : key;
  if (value === false || value === null || value === undefined) element.removeAttribute(attribute);
  else if (value === true) element.setAttribute(attribute, "");
  else element.setAttribute(attribute, String(value));
}

function updateProps(element, oldProps, newProps, isSvg) {
  for (const key of Object.keys(oldProps || {})) if (!(key in (newProps || {}))) setProp(element, key, null, oldProps[key], isSvg);
  for (const [key, value] of Object.entries(newProps || {})) if (!Object.is(value, oldProps?.[key])) setProp(element, key, value, oldProps?.[key], isSvg);
}

function createDom(vnode, isSvg = false) {
  if (vnode.type === "#text") return document.createTextNode(vnode.value);
  if (vnode.type === Fragment) {
    const fragment = document.createDocumentFragment();
    for (const child of vnode.children || []) fragment.appendChild(createDom(child, isSvg));
    return fragment;
  }
  const svg = isSvg || vnode.type === "svg";
  const element = svg ? document.createElementNS("http://www.w3.org/2000/svg", vnode.type) : document.createElement(vnode.type);
  updateProps(element, {}, vnode.props, svg);
  for (const child of vnode.children || []) element.appendChild(createDom(child, svg));
  vnode.dom = element;
  return element;
}

function sameNode(a, b) { return a && b && a.type === b.type && a.key === b.key; }

function patch(parent, oldNode, newNode, index = 0, isSvg = false) {
  const dom = parent.childNodes[index];
  if (!oldNode && newNode) { parent.appendChild(createDom(newNode, isSvg)); return; }
  if (oldNode && !newNode) { if (dom) parent.removeChild(dom); return; }
  if (!oldNode || !newNode) return;
  if (!sameNode(oldNode, newNode)) { parent.replaceChild(createDom(newNode, isSvg), dom); return; }
  if (newNode.type === "#text") { if (oldNode.value !== newNode.value) dom.nodeValue = newNode.value; return; }
  if (newNode.type === Fragment) {
    const oldChildren = oldNode.children || [];
    const newChildren = newNode.children || [];
    const max = Math.max(oldChildren.length, newChildren.length);
    for (let i = max - 1; i >= 0; --i) if (i >= newChildren.length) patch(parent, oldChildren[i], null, index + i, isSvg);
    for (let i = 0; i < newChildren.length; ++i) patch(parent, oldChildren[i], newChildren[i], index + i, isSvg);
    return;
  }
  const svg = isSvg || newNode.type === "svg";
  updateProps(dom, oldNode.props, newNode.props, svg);
  const oldChildren = oldNode.children || [];
  const newChildren = newNode.children || [];
  const max = Math.max(oldChildren.length, newChildren.length);
  for (let i = max - 1; i >= 0; --i) if (i >= newChildren.length) patch(dom, oldChildren[i], null, i, svg);
  for (let i = 0; i < newChildren.length; ++i) patch(dom, oldChildren[i], newChildren[i], i, svg);
}

function performRender() {
  if (!rootContainer || !rootVNode) return;
  pendingEffects = [];
  const newTree = resolve(rootVNode);
  if (!oldTree) rootContainer.appendChild(createDom(newTree));
  else patch(rootContainer, oldTree, newTree);
  oldTree = newTree;
  const effects = pendingEffects;
  pendingEffects = [];
  for (const effect of effects) effect();
}

function createRoot(container) {
  rootContainer = container;
  return { render(vnode) { rootVNode = vnode; performRender(); }, unmount() { container.textContent = ""; oldTree = null; rootVNode = null; } };
}

const React = { createElement, Fragment, StrictMode: Fragment };
export { createElement, Fragment, useState, useEffect, useRef, useMemo, useCallback, createContext, useContext, createRoot };
export default React;
