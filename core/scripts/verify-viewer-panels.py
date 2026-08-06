#!/usr/bin/env python3
"""Verify that the Pulsar viewer covers every configured output and is not black.

This script runs only during verification/diagnostics. It is never part of the
per-frame path and therefore adds no runtime latency.
"""
from __future__ import annotations

import ctypes
import ctypes.util
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path


@dataclass
class Geometry:
    width: int
    height: int
    x: int
    y: int


@dataclass
class Panel:
    profile: int
    geometry: Geometry


GEOMETRY_RE = re.compile(r"^(\d+)x(\d+)([+-]\d+)([+-]\d+)$")


def parse_geometry(value: str) -> Geometry:
    match = GEOMETRY_RE.match(value.strip())
    if not match:
        raise ValueError(f"invalid geometry: {value!r}")
    return Geometry(int(match.group(1)), int(match.group(2)),
                    int(match.group(3)), int(match.group(4)))


def parse_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key] = value.strip().strip("'\"")
    return values


def panels_from_env(values: dict[str, str]) -> tuple[Geometry, list[Panel]]:
    canvas = parse_geometry(values["PULSAR_VIEWER_CANVAS_GEOMETRY"])
    panels: list[Panel] = []
    for token in values.get("PULSAR_VIEWER_PANEL_SPECS", "").split(";"):
        if not token or ":" not in token:
            continue
        profile_raw, geometry_raw = token.split(":", 1)
        panels.append(Panel(int(profile_raw), parse_geometry(geometry_raw)))
    return canvas, panels


class XWindowAttributes(ctypes.Structure):
    _fields_ = [
        ("x", ctypes.c_int), ("y", ctypes.c_int),
        ("width", ctypes.c_int), ("height", ctypes.c_int),
        ("border_width", ctypes.c_int), ("depth", ctypes.c_int),
        ("visual", ctypes.c_void_p), ("root", ctypes.c_ulong),
        ("class_", ctypes.c_int), ("bit_gravity", ctypes.c_int),
        ("win_gravity", ctypes.c_int), ("backing_store", ctypes.c_int),
        ("backing_planes", ctypes.c_ulong), ("backing_pixel", ctypes.c_ulong),
        ("save_under", ctypes.c_int), ("colormap", ctypes.c_ulong),
        ("map_installed", ctypes.c_int), ("map_state", ctypes.c_int),
        ("all_event_masks", ctypes.c_long), ("your_event_mask", ctypes.c_long),
        ("do_not_propagate_mask", ctypes.c_long),
        ("override_redirect", ctypes.c_int), ("screen", ctypes.c_void_p),
    ]


class XImage(ctypes.Structure):
    _fields_ = [
        ("width", ctypes.c_int), ("height", ctypes.c_int),
        ("xoffset", ctypes.c_int), ("format", ctypes.c_int),
        ("data", ctypes.c_void_p), ("byte_order", ctypes.c_int),
        ("bitmap_unit", ctypes.c_int), ("bitmap_bit_order", ctypes.c_int),
        ("bitmap_pad", ctypes.c_int), ("depth", ctypes.c_int),
        ("bytes_per_line", ctypes.c_int), ("bits_per_pixel", ctypes.c_int),
        ("red_mask", ctypes.c_ulong), ("green_mask", ctypes.c_ulong),
        ("blue_mask", ctypes.c_ulong), ("obdata", ctypes.c_void_p),
        ("funcs", ctypes.c_byte * 96),
    ]


def load_x11() -> ctypes.CDLL:
    name = ctypes.util.find_library("X11")
    if not name:
        raise RuntimeError("libX11 not found")
    lib = ctypes.CDLL(name)
    lib.XOpenDisplay.argtypes = [ctypes.c_char_p]
    lib.XOpenDisplay.restype = ctypes.c_void_p
    lib.XCloseDisplay.argtypes = [ctypes.c_void_p]
    lib.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
    lib.XDefaultRootWindow.restype = ctypes.c_ulong
    lib.XQueryTree.argtypes = [ctypes.c_void_p, ctypes.c_ulong,
                               ctypes.POINTER(ctypes.c_ulong),
                               ctypes.POINTER(ctypes.c_ulong),
                               ctypes.POINTER(ctypes.POINTER(ctypes.c_ulong)),
                               ctypes.POINTER(ctypes.c_uint)]
    lib.XQueryTree.restype = ctypes.c_int
    lib.XFetchName.argtypes = [ctypes.c_void_p, ctypes.c_ulong,
                               ctypes.POINTER(ctypes.c_char_p)]
    lib.XFetchName.restype = ctypes.c_int
    lib.XFree.argtypes = [ctypes.c_void_p]
    lib.XGetWindowAttributes.argtypes = [ctypes.c_void_p, ctypes.c_ulong,
                                         ctypes.POINTER(XWindowAttributes)]
    lib.XGetWindowAttributes.restype = ctypes.c_int
    lib.XTranslateCoordinates.argtypes = [ctypes.c_void_p, ctypes.c_ulong,
                                          ctypes.c_ulong, ctypes.c_int,
                                          ctypes.c_int, ctypes.POINTER(ctypes.c_int),
                                          ctypes.POINTER(ctypes.c_int),
                                          ctypes.POINTER(ctypes.c_ulong)]
    lib.XTranslateCoordinates.restype = ctypes.c_int
    lib.XGetImage.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int,
                              ctypes.c_int, ctypes.c_uint, ctypes.c_uint,
                              ctypes.c_ulong, ctypes.c_int]
    lib.XGetImage.restype = ctypes.POINTER(XImage)
    lib.XGetPixel.argtypes = [ctypes.POINTER(XImage), ctypes.c_int, ctypes.c_int]
    lib.XGetPixel.restype = ctypes.c_ulong
    lib.XDestroyImage.argtypes = [ctypes.POINTER(XImage)]
    lib.XDestroyImage.restype = ctypes.c_int
    return lib


def window_name(lib: ctypes.CDLL, display: int, window: int) -> str:
    name = ctypes.c_char_p()
    if lib.XFetchName(display, window, ctypes.byref(name)) == 0 or not name.value:
        return ""
    try:
        return name.value.decode("utf-8", "replace")
    finally:
        lib.XFree(name)


def find_viewer(lib: ctypes.CDLL, display: int, root: int) -> int | None:
    wanted = {"Pulsar Multi-Output Viewer", "Pulsar SBS"}
    stack = [root]
    visited = 0
    while stack and visited < 10000:
        window = stack.pop()
        visited += 1
        if window_name(lib, display, window) in wanted:
            return window
        root_return = ctypes.c_ulong()
        parent_return = ctypes.c_ulong()
        children = ctypes.POINTER(ctypes.c_ulong)()
        count = ctypes.c_uint()
        if lib.XQueryTree(display, window, ctypes.byref(root_return),
                          ctypes.byref(parent_return), ctypes.byref(children),
                          ctypes.byref(count)) == 0:
            continue
        try:
            if children:
                stack.extend(int(children[i]) for i in range(count.value))
        finally:
            if children:
                lib.XFree(children)
    return None


def mask_component(pixel: int, mask: int) -> int:
    if mask == 0:
        return 0
    shift = (mask & -mask).bit_length() - 1
    value = (pixel & mask) >> shift
    maximum = mask >> shift
    return int(round(value * 255 / maximum)) if maximum else 0


def sample_panel(lib: ctypes.CDLL, display: int, window: int,
                 panel: Geometry) -> tuple[float, float, int]:
    # Sample several small regions, avoiding black letterboxing and panel edges.
    points = [(0.25, 0.25), (0.5, 0.5), (0.75, 0.25),
              (0.25, 0.75), (0.75, 0.75)]
    values: list[float] = []
    for x_ratio, y_ratio in points:
        center_x = panel.x + int(panel.width * x_ratio)
        center_y = panel.y + int(panel.height * y_ratio)
        sample_w = max(1, min(12, panel.width // 20))
        sample_h = max(1, min(12, panel.height // 20))
        x = max(panel.x, min(center_x - sample_w // 2,
                             panel.x + panel.width - sample_w))
        y = max(panel.y, min(center_y - sample_h // 2,
                             panel.y + panel.height - sample_h))
        image = lib.XGetImage(display, window, x, y, sample_w, sample_h,
                              ctypes.c_ulong(-1).value, 2)  # ZPixmap
        if not image:
            continue
        try:
            red_mask = int(image.contents.red_mask)
            green_mask = int(image.contents.green_mask)
            blue_mask = int(image.contents.blue_mask)
            for py in range(sample_h):
                for px in range(sample_w):
                    pixel = int(lib.XGetPixel(image, px, py))
                    red = mask_component(pixel, red_mask)
                    green = mask_component(pixel, green_mask)
                    blue = mask_component(pixel, blue_mask)
                    values.append(0.2126 * red + 0.7152 * green + 0.0722 * blue)
        finally:
            lib.XDestroyImage(image)
    if not values:
        return 0.0, 0.0, 0
    mean = sum(values) / len(values)
    variance = sum((value - mean) ** 2 for value in values) / len(values)
    return mean, variance ** 0.5, len(values)


def main() -> int:
    data_dir = Path(os.environ.get("PULSAR_DATA_DIR",
                                   "/home/matin/Pulsar-Cpp-Core/core/data"))
    layout_path = data_dir / "viewer-layout.env"
    displays_path = data_dir / "displays.env"
    if not layout_path.exists():
        print(f"VIEWER_LAYOUT=FAIL missing={layout_path}")
        return 2

    values = parse_env(layout_path)
    if displays_path.exists():
        for key, value in parse_env(displays_path).items():
            values.setdefault(key, value)
    try:
        canvas, panels = panels_from_env(values)
    except (KeyError, ValueError) as exc:
        print(f"VIEWER_LAYOUT=FAIL error={exc}")
        return 2

    print(f"VIEWER_CANVAS={canvas.width}x{canvas.height}+{canvas.x}+{canvas.y}")
    print(f"VIEWER_PANEL_COUNT={len(panels)}")

    lib = load_x11()
    display_name = os.environ.get("DISPLAY", ":0").encode()
    display = lib.XOpenDisplay(display_name)
    if not display:
        print(f"VIEWER_WINDOW=FAIL cannot-open-display={display_name.decode()}")
        return 3
    try:
        root = int(lib.XDefaultRootWindow(display))
        viewer = find_viewer(lib, display, root)
        if viewer is None:
            print("VIEWER_WINDOW=FAIL not-found")
            return 4

        attributes = XWindowAttributes()
        if lib.XGetWindowAttributes(display, viewer, ctypes.byref(attributes)) == 0:
            print("VIEWER_WINDOW=FAIL no-attributes")
            return 5
        absolute_x = ctypes.c_int()
        absolute_y = ctypes.c_int()
        child = ctypes.c_ulong()
        lib.XTranslateCoordinates(display, viewer, root, 0, 0,
                                  ctypes.byref(absolute_x),
                                  ctypes.byref(absolute_y), ctypes.byref(child))
        print(f"VIEWER_WINDOW_GEOMETRY={attributes.width}x{attributes.height}+"
              f"{absolute_x.value}+{absolute_y.value}")
        geometry_ok = (abs(attributes.width - canvas.width) <= 4 and
                       abs(attributes.height - canvas.height) <= 4 and
                       abs(absolute_x.value - canvas.x) <= 4 and
                       abs(absolute_y.value - canvas.y) <= 4)
        print(f"VIEWER_WINDOW={'PASS' if geometry_ok else 'FAIL'}")

        failures = 0 if geometry_ok else 1
        connected = {
            0: values.get("PULSAR_ROLE_DISPLAY_CONNECTED", "0") == "1",
            1: values.get("PULSAR_ROLE_AR1_CONNECTED", "0") == "1",
            2: values.get("PULSAR_ROLE_AR2_CONNECTED", "0") == "1",
        }
        present_profiles = {panel.profile for panel in panels}
        for profile in range(3):
            if connected.get(profile, False) and profile not in present_profiles:
                print(f"PANEL_{profile}=FAIL reason=connected-but-missing")
                failures += 1

        for panel in panels:
            mean, deviation, count = sample_panel(lib, display, viewer, panel.geometry)
            visible = count > 0 and (mean >= 4.0 or deviation >= 3.0)
            status = "PASS" if visible else "FAIL"
            print(f"PANEL_{panel.profile}={status} mean={mean:.2f} "
                  f"stddev={deviation:.2f} samples={count} "
                  f"geometry={panel.geometry.width}x{panel.geometry.height}+"
                  f"{panel.geometry.x}+{panel.geometry.y}")
            if not visible:
                failures += 1

        print(f"GLASSES_PANEL_STATUS={'PASS' if failures == 0 else 'FAIL'}")
        return 0 if failures == 0 else 6
    finally:
        lib.XCloseDisplay(display)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # Diagnostic script must report, never disappear.
        print(f"VIEWER_PANEL_PROBE=FAIL error={type(exc).__name__}:{exc}")
        raise SystemExit(9)
