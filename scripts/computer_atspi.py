#!/usr/bin/python3
"""Bounded AT-SPI discovery for Bone's Hyprland computer tool."""

import json
import sys
import time

MAX_DEPTH = 16
MAX_NODES = 512
MAX_CHILDREN = 128
MAX_RESULTS = 64
MAX_NAME_BYTES = 160
DEADLINE_SECONDS = 1.5
GEOMETRY_TOLERANCE = 4

ROLE_NAMES = {
    "BUTTON": "button",
    "CHECK_BOX": "check_box",
    "COMBO_BOX": "combo_box",
    "ENTRY": "entry",
    "PASSWORD_TEXT": "password_text",
    "LINK": "link",
    "LIST_ITEM": "list_item",
    "MENU_ITEM": "menu_item",
    "PAGE_TAB": "page_tab",
    "RADIO_BUTTON": "radio_button",
    "SLIDER": "slider",
    "SPIN_BUTTON": "spin_button",
    "TEXT": "entry",
    "TOGGLE_BUTTON": "toggle_button",
    "TREE_ITEM": "tree_item",
}
WINDOW_ROLES = {"DIALOG", "FRAME", "WINDOW"}
STATE_NAMES = (
    "CHECKED", "EDITABLE", "ENABLED", "EXPANDED", "FOCUSABLE", "FOCUSED",
    "PRESSED", "SELECTED", "SENSITIVE", "SHOWING", "VISIBLE",
)


def emit(value):
    sys.stdout.write(json.dumps(value, ensure_ascii=True, separators=(",", ":")))


def fail(reason):
    emit({"ok": False, "reason": str(reason)[:240]})
    raise SystemExit(0)


def bounded_text(value):
    value = "" if value is None else str(value)
    value = "".join("?" if ord(char) < 32 or ord(char) == 127 else char for char in value)
    raw = value.encode("utf-8")
    if len(raw) <= MAX_NAME_BYTES:
        return value
    return raw[:MAX_NAME_BYTES].decode("utf-8", "ignore") + "..."


def enum_key(value):
    name = getattr(value, "value_name", None) or str(value)
    prefix = "ATSPI_ROLE_"
    return name[len(prefix):] if name.startswith(prefix) else name.rsplit(".", 1)[-1]


def states_for(node, Atspi):
    state_set = node.get_state_set()
    return {
        name.lower(): bool(state_set.contains(getattr(Atspi.StateType, name)))
        for name in STATE_NAMES
    }


def rect_for(node, coord):
    rect = node.get_extents(coord)
    return [int(rect.x), int(rect.y), int(rect.width), int(rect.height)]


def valid_rect(rect):
    return all(isinstance(value, int) for value in rect) and rect[2] > 0 and rect[3] > 0


def within(value, expected, tolerance=GEOMETRY_TOLERANCE):
    return abs(value - expected) <= tolerance


def load_request():
    if len(sys.argv) != 2 or sys.argv[1] not in ("discover", "resolve"):
        fail("invalid operation")
    try:
        request = json.load(sys.stdin)
    except Exception:
        fail("invalid request")
    if not isinstance(request, dict):
        fail("invalid request")
    window = request.get("window")
    if not isinstance(window, dict):
        fail("invalid focused window")
    required = ("pid", "title", "x", "y", "width", "height", "stable_id")
    if any(key not in window for key in required):
        fail("incomplete focused window")
    if not isinstance(window["pid"], int) or window["pid"] <= 0:
        fail("invalid focused-window pid")
    if not all(isinstance(window[key], int) for key in ("x", "y", "width", "height")):
        fail("invalid focused-window bounds")
    if window["width"] <= 0 or window["height"] <= 0:
        fail("invalid focused-window bounds")
    return sys.argv[1], request, window


def import_atspi():
    try:
        import gi
        gi.require_version("Atspi", "2.0")
        from gi.repository import Atspi
        return Atspi
    except Exception:
        fail("AT-SPI Python bindings are unavailable")


def find_application(Atspi, pid, deadline):
    desktop = Atspi.get_desktop(0)
    if desktop is None:
        return None
    count = min(max(0, int(desktop.get_child_count())), MAX_CHILDREN)
    for index in range(count):
        if time.monotonic() > deadline:
            fail("AT-SPI traversal timed out")
        try:
            candidate = desktop.get_child_at_index(index)
            if candidate is not None and int(candidate.get_process_id()) == pid:
                return candidate
        except Exception:
            continue
    return None


def choose_window(app, window, Atspi, deadline):
    candidates = []
    count = min(max(0, int(app.get_child_count())), MAX_CHILDREN)
    for index in range(count):
        if time.monotonic() > deadline:
            fail("AT-SPI traversal timed out")
        try:
            node = app.get_child_at_index(index)
            role_key = enum_key(node.get_role())
            states = states_for(node, Atspi)
            if role_key not in WINDOW_ROLES or not states["visible"] or not states["showing"]:
                continue
            rect = rect_for(node, Atspi.CoordType.WINDOW)
            if not valid_rect(rect):
                continue
            calibrated = (
                within(rect[0], 0) and within(rect[1], 0)
                and within(rect[2], window["width"]) and within(rect[3], window["height"])
            )
            if not calibrated:
                continue
            name = bounded_text(node.get_name())
            score = (2 if name == window["title"] else 0) + (1 if rect[2:] == [window["width"], window["height"]] else 0)
            candidates.append((score, index, node, name, rect))
        except Exception:
            continue
    if not candidates:
        return None
    candidates.sort(key=lambda item: (item[0], -item[1]), reverse=True)
    best = candidates[0]
    if len(candidates) > 1 and candidates[1][0] == best[0]:
        return None
    return best[2], [best[1]], best[3], best[4]


def actionable(role_key, states):
    return (
        role_key in ROLE_NAMES
        and states["visible"] and states["showing"] and states["sensitive"]
        and states["enabled"]
    )


def target_data(node, path, window, Atspi):
    role_key = enum_key(node.get_role())
    states = states_for(node, Atspi)
    if not actionable(role_key, states):
        return None
    relative = rect_for(node, Atspi.CoordType.WINDOW)
    if not valid_rect(relative):
        return None
    left, top, width, height = relative
    if left < 0 or top < 0 or left + width > window["width"] or top + height > window["height"]:
        return None
    name = "[protected]" if role_key == "PASSWORD_TEXT" else bounded_text(node.get_name())
    bounds = {
        "x": window["x"] + left,
        "y": window["y"] + top,
        "width": width,
        "height": height,
    }
    return {
        "id": "atspi:" + ".".join(str(index) for index in path),
        "role": ROLE_NAMES[role_key],
        "name": name,
        "states": states,
        "bounds": bounds,
        "center": {
            "x": bounds["x"] + width // 2,
            "y": bounds["y"] + height // 2,
        },
    }


def discover(root, root_path, window, Atspi, deadline):
    results = []
    visited = 0
    truncated = False
    stack = [(root, root_path, 0)]
    while stack:
        if time.monotonic() > deadline:
            fail("AT-SPI traversal timed out")
        node, path, depth = stack.pop()
        visited += 1
        if visited > MAX_NODES:
            truncated = True
            break
        try:
            target = target_data(node, path, window, Atspi)
            if target is not None:
                if len(results) >= MAX_RESULTS:
                    truncated = True
                    break
                results.append(target)
            if depth >= MAX_DEPTH:
                if node.get_child_count() > 0:
                    truncated = True
                continue
            count = int(node.get_child_count())
            if count > MAX_CHILDREN:
                truncated = True
            for index in reversed(range(min(max(0, count), MAX_CHILDREN))):
                child = node.get_child_at_index(index)
                if child is not None:
                    stack.append((child, path + [index], depth + 1))
        except Exception:
            continue
    return results, visited, truncated


def parse_path(target_id):
    if not isinstance(target_id, str) or not target_id.startswith("atspi:"):
        fail("invalid semantic target id")
    suffix = target_id[6:]
    if not suffix or len(suffix) > 160:
        fail("invalid semantic target id")
    parts = suffix.split(".")
    if len(parts) > MAX_DEPTH + 2 or any(not part.isdigit() for part in parts):
        fail("invalid semantic target id")
    path = [int(part) for part in parts]
    if any(index < 0 or index >= MAX_CHILDREN for index in path):
        fail("invalid semantic target id")
    return path


def resolve(app, root_path, request, window, Atspi, deadline):
    expected = request.get("expected")
    if not isinstance(expected, dict):
        fail("missing semantic target identity")
    path = parse_path(request.get("target_id"))
    if path[:len(root_path)] != root_path:
        fail("semantic target is outside the focused window")
    node = app
    for index in path:
        if time.monotonic() > deadline:
            fail("AT-SPI traversal timed out")
        try:
            if index >= node.get_child_count():
                fail("semantic target is stale")
            node = node.get_child_at_index(index)
            if node is None:
                fail("semantic target is stale")
        except SystemExit:
            raise
        except Exception:
            fail("semantic target is stale")
    current = target_data(node, path, window, Atspi)
    if current is None:
        fail("semantic target is no longer visible and actionable")
    for key in ("id", "role", "name", "states", "bounds"):
        if current.get(key) != expected.get(key):
            fail("semantic target changed; discover targets again")
    return current


def main():
    operation, request, window = load_request()
    Atspi = import_atspi()
    deadline = time.monotonic() + DEADLINE_SECONDS
    app = find_application(Atspi, window["pid"], deadline)
    if app is None:
        if operation == "discover":
            emit({"ok": True, "available": False, "reason": "focused application is not exposed through AT-SPI", "targets": []})
            return
        fail("focused application is not exposed through AT-SPI")
    selected = choose_window(app, window, Atspi, deadline)
    if selected is None:
        if operation == "discover":
            emit({"ok": True, "available": False, "reason": "focused AT-SPI window bounds could not be calibrated", "targets": []})
            return
        fail("focused AT-SPI window bounds could not be calibrated")
    root, root_path, window_name, _ = selected
    if operation == "discover":
        targets, visited, truncated = discover(root, root_path, window, Atspi, deadline)
        emit({
            "ok": True,
            "available": True,
            "window": {"name": window_name, "pid": window["pid"], "stable_id": window["stable_id"]},
            "targets": targets,
            "visited": visited,
            "truncated": truncated,
            "limits": {"depth": MAX_DEPTH, "nodes": MAX_NODES, "results": MAX_RESULTS},
        })
        return
    target = resolve(app, root_path, request, window, Atspi, deadline)
    emit({"ok": True, "target": target})


if __name__ == "__main__":
    main()
