#!/usr/bin/env python3
import ctypes
import ctypes.util
import os
import time


def env_int(name, fallback):
    value = os.environ.get(name, "")
    try:
        return int(value)
    except ValueError:
        return fallback


TARGET_X = env_int("PULSAR_MAIN_X", 0)
TARGET_Y = env_int("PULSAR_MAIN_Y", 0)
TARGET_W = env_int("PULSAR_MAIN_WIDTH", 0)
TARGET_H = env_int("PULSAR_MAIN_HEIGHT", 0)
ATTEMPTS = max(1, env_int("PULSAR_SBS_PLACE_ATTEMPTS", 30))
DELAY = float(os.environ.get("PULSAR_SBS_PLACE_DELAY", "0.1"))

if TARGET_W <= 0 or TARGET_H <= 0:
    raise SystemExit(0)

lib = ctypes.CDLL(ctypes.util.find_library("X11") or "libX11.so.6")
Display = ctypes.c_void_p
Window = ctypes.c_ulong
Atom = ctypes.c_ulong

lib.XOpenDisplay.argtypes = [ctypes.c_char_p]
lib.XOpenDisplay.restype = Display
lib.XDefaultRootWindow.argtypes = [Display]
lib.XDefaultRootWindow.restype = Window
lib.XQueryTree.argtypes = [
    Display,
    Window,
    ctypes.POINTER(Window),
    ctypes.POINTER(Window),
    ctypes.POINTER(ctypes.POINTER(Window)),
    ctypes.POINTER(ctypes.c_uint),
]
lib.XQueryTree.restype = ctypes.c_int
lib.XFetchName.argtypes = [Display, Window, ctypes.POINTER(ctypes.c_char_p)]
lib.XFetchName.restype = ctypes.c_int
lib.XFree.argtypes = [ctypes.c_void_p]
lib.XFree.restype = ctypes.c_int
lib.XInternAtom.argtypes = [Display, ctypes.c_char_p, ctypes.c_int]
lib.XInternAtom.restype = Atom
lib.XDeleteProperty.argtypes = [Display, Window, Atom]
lib.XDeleteProperty.restype = ctypes.c_int
lib.XMoveResizeWindow.argtypes = [
    Display,
    Window,
    ctypes.c_int,
    ctypes.c_int,
    ctypes.c_uint,
    ctypes.c_uint,
]
lib.XMoveResizeWindow.restype = ctypes.c_int
lib.XMapRaised.argtypes = [Display, Window]
lib.XMapRaised.restype = ctypes.c_int
lib.XFlush.argtypes = [Display]
lib.XFlush.restype = ctypes.c_int
lib.XCloseDisplay.argtypes = [Display]
lib.XCloseDisplay.restype = ctypes.c_int


def find_sbs_window(display, root):
    found = []

    def walk(window):
        name = ctypes.c_char_p()
        if lib.XFetchName(display, window, ctypes.byref(name)) and name.value:
            text = name.value.decode(errors="replace")
            lib.XFree(name)
            if "Pulsar SBS" in text:
                found.append(window)

        root_return = Window()
        parent_return = Window()
        children = ctypes.POINTER(Window)()
        child_count = ctypes.c_uint()
        ok = lib.XQueryTree(
            display,
            window,
            ctypes.byref(root_return),
            ctypes.byref(parent_return),
            ctypes.byref(children),
            ctypes.byref(child_count),
        )
        if not ok:
            return
        try:
            for index in range(child_count.value):
                walk(children[index])
        finally:
            if children:
                lib.XFree(children)

    walk(root)
    return found[-1] if found else None


def place_once():
    display_name = os.environ.get("DISPLAY", ":0").encode()
    display = lib.XOpenDisplay(display_name)
    if not display:
        return False
    try:
        root = lib.XDefaultRootWindow(display)
        window = find_sbs_window(display, root)
        if not window:
            return False
        for atom_name in (b"_NET_WM_STATE", b"_NET_WM_FULLSCREEN_MONITORS"):
            atom = lib.XInternAtom(display, atom_name, 1)
            if atom:
                lib.XDeleteProperty(display, window, atom)
        lib.XMoveResizeWindow(display, window, TARGET_X, TARGET_Y, TARGET_W, TARGET_H)
        lib.XMapRaised(display, window)
        lib.XFlush(display)
        print(f"Pulsar SBS window placed at {TARGET_W}x{TARGET_H}+{TARGET_X}+{TARGET_Y}")
        return True
    finally:
        lib.XCloseDisplay(display)


for attempt in range(ATTEMPTS):
    if place_once():
        raise SystemExit(0)
    if attempt + 1 < ATTEMPTS:
        time.sleep(DELAY)

raise SystemExit("Pulsar SBS window was not found for placement.")
