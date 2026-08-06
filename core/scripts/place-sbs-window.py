#!/usr/bin/env python3
# PULSAR_MULTI_OUTPUT_PLACER_V2
import ctypes
import ctypes.util
import os
import pathlib
import re
import time


def env_int(name: str, fallback: int) -> int:
    try:
        return int(os.environ.get(name, ""))
    except ValueError:
        return fallback


def parse_geometry(value: str):
    match = re.fullmatch(r"(\d+)x(\d+)\+(-?\d+)\+(-?\d+)", value.strip())
    if not match:
        return None
    width, height, x, y = map(int, match.groups())
    if width <= 0 or height <= 0:
        return None
    return x, y, width, height


def target_geometry():
    value = os.environ.get("PULSAR_VIEWER_CANVAS_GEOMETRY", "")
    parsed = parse_geometry(value)
    if parsed:
        return parsed

    data_root = pathlib.Path(os.environ.get("PULSAR_DATA_DIR", ""))
    layout_path = data_root / "viewer-layout.env"
    try:
        for line in layout_path.read_text().splitlines():
            if line.startswith("PULSAR_VIEWER_CANVAS_GEOMETRY="):
                parsed = parse_geometry(line.split("=", 1)[1])
                if parsed:
                    return parsed
    except OSError:
        pass

    return (
        env_int("PULSAR_MAIN_X", 0),
        env_int("PULSAR_MAIN_Y", 0),
        env_int("PULSAR_MAIN_WIDTH", 0),
        env_int("PULSAR_MAIN_HEIGHT", 0),
    )


TARGET_X, TARGET_Y, TARGET_W, TARGET_H = target_geometry()
ATTEMPTS = max(1, env_int("PULSAR_SBS_PLACE_ATTEMPTS", 50))
DELAY = float(os.environ.get("PULSAR_SBS_PLACE_DELAY", "0.1"))
if TARGET_W <= 0 or TARGET_H <= 0:
    raise SystemExit("Invalid Pulsar viewer target geometry")

lib = ctypes.CDLL(ctypes.util.find_library("X11") or "libX11.so.6")
Display = ctypes.c_void_p
Window = ctypes.c_ulong
Atom = ctypes.c_ulong

lib.XOpenDisplay.argtypes = [ctypes.c_char_p]
lib.XOpenDisplay.restype = Display
lib.XDefaultRootWindow.argtypes = [Display]
lib.XDefaultRootWindow.restype = Window
lib.XQueryTree.argtypes = [
    Display, Window, ctypes.POINTER(Window), ctypes.POINTER(Window),
    ctypes.POINTER(ctypes.POINTER(Window)), ctypes.POINTER(ctypes.c_uint),
]
lib.XQueryTree.restype = ctypes.c_int
lib.XFetchName.argtypes = [Display, Window, ctypes.POINTER(ctypes.c_char_p)]
lib.XFetchName.restype = ctypes.c_int
lib.XFree.argtypes = [ctypes.c_void_p]
lib.XInternAtom.argtypes = [Display, ctypes.c_char_p, ctypes.c_int]
lib.XInternAtom.restype = Atom
lib.XDeleteProperty.argtypes = [Display, Window, Atom]
lib.XMoveResizeWindow.argtypes = [Display, Window, ctypes.c_int, ctypes.c_int, ctypes.c_uint, ctypes.c_uint]
lib.XMapRaised.argtypes = [Display, Window]
lib.XFlush.argtypes = [Display]
lib.XCloseDisplay.argtypes = [Display]


def find_viewer(display, root):
    exact = []
    fallback = []

    def walk(window):
        name = ctypes.c_char_p()
        if lib.XFetchName(display, window, ctypes.byref(name)) and name.value:
            title = name.value.decode(errors="replace")
            lib.XFree(name)
            if title in ("Pulsar Multi-Output Viewer", "Pulsar SBS Main"):
                exact.append(window)
            elif "Pulsar" in title and ("Viewer" in title or "SBS" in title):
                fallback.append(window)

        root_return = Window()
        parent_return = Window()
        children = ctypes.POINTER(Window)()
        count = ctypes.c_uint()
        if not lib.XQueryTree(
            display, window, ctypes.byref(root_return), ctypes.byref(parent_return),
            ctypes.byref(children), ctypes.byref(count)
        ):
            return
        try:
            for index in range(count.value):
                walk(children[index])
        finally:
            if children:
                lib.XFree(children)

    walk(root)
    return exact[-1] if exact else (fallback[-1] if fallback else None)


def place_once():
    display = lib.XOpenDisplay(os.environ.get("DISPLAY", ":0").encode())
    if not display:
        return False
    try:
        root = lib.XDefaultRootWindow(display)
        window = find_viewer(display, root)
        if not window:
            return False
        for atom_name in (b"_NET_WM_STATE", b"_NET_WM_FULLSCREEN_MONITORS"):
            atom = lib.XInternAtom(display, atom_name, 1)
            if atom:
                lib.XDeleteProperty(display, window, atom)
        lib.XMoveResizeWindow(display, window, TARGET_X, TARGET_Y, TARGET_W, TARGET_H)
        lib.XMapRaised(display, window)
        lib.XFlush(display)
        print(f"Pulsar viewer placed at {TARGET_W}x{TARGET_H}+{TARGET_X}+{TARGET_Y}")
        return True
    finally:
        lib.XCloseDisplay(display)


for attempt in range(ATTEMPTS):
    if place_once():
        raise SystemExit(0)
    if attempt + 1 < ATTEMPTS:
        time.sleep(DELAY)
raise SystemExit("Pulsar multi-output viewer window was not found")
