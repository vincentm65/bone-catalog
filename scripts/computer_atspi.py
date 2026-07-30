#!/usr/bin/python3
"""Bounded, privacy-conscious AT-SPI support for Bone's computer tool.

The helper is intentionally a small JSON-in/JSON-out process.  It never reads
text values, never reads password names, bounds every traversal, and does not
retry input.  Semantic fingerprints are opaque hashes: child paths remain
useful handles for a single observation, but are not trusted for re-resolution.
"""

from collections import Counter
import hashlib
import json
import math
import re
import sys
import time
import unicodedata


MAX_DEPTH = 16
MAX_NODES = 512
MAX_CHILDREN = 128
MAX_RESULTS = 64
MAX_ACTIONS = 32
MAX_NAME_BYTES = 160
MAX_QUERY_BYTES = 160
MAX_ROLE_FILTERS = 16
MAX_REQUEST_BYTES = 256 * 1024
MAX_JSON_INTEGER = (1 << 63) - 1
MAX_PID = (1 << 31) - 1
MAX_ABSOLUTE_COORDINATE = 10_000_000
MAX_WINDOW_SIZE = 1_000_000
MAX_NEAR_RADIUS = 100_000
DEADLINE_SECONDS = 1.5
GEOMETRY_TOLERANCE = 4
FINGERPRINT_PREFIX = "atspi-fp:v1:"
FINGERPRINT_RE = re.compile(r"^atspi-fp:v1:[0-9a-f]{64}$")
UNREAD = object()

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
PUBLIC_ROLES = frozenset(ROLE_NAMES.values())
WINDOW_ROLES = {"DIALOG", "FRAME", "WINDOW"}
STATE_NAMES = (
    "CHECKED", "EDITABLE", "ENABLED", "EXPANDED", "FOCUSABLE", "FOCUSED",
    "PRESSED", "SELECTED", "SENSITIVE", "SHOWING", "VISIBLE",
)
TYPING_ROLES = {"entry", "password_text", "spin_button"}
ACTIVATION_PREFERENCE = (
    "click", "press", "activate", "default", "toggle", "open", "jump", "select",
)
ACTIVATION_ACTIONS = frozenset(ACTIVATION_PREFERENCE)
REJECTION_KEYS = (
    "unsupported_role",
    "unavailable_state",
    "invalid_bounds",
    "outside_window",
    "inaccessible",
    "role_filter",
    "query_filter",
    "near_filter",
    "fingerprint_collision",
)
ROLE_RANK = {
    "button": 50,
    "link": 48,
    "menu_item": 46,
    "toggle_button": 44,
    "check_box": 42,
    "radio_button": 42,
    "entry": 40,
    "password_text": 40,
    "combo_box": 38,
    "page_tab": 36,
    "slider": 34,
    "spin_button": 34,
    "list_item": 28,
    "tree_item": 28,
}


class HelperFailure(Exception):
    """A stable, sanitized failure suitable for the JSON protocol."""

    def __init__(self, reason_code, reason):
        super().__init__(reason)
        self.reason_code = str(reason_code)[:80]
        self.reason = str(reason)[:240]


def reject(reason_code, reason):
    raise HelperFailure(reason_code, reason)


def emit(value):
    sys.stdout.write(json.dumps(value, ensure_ascii=True, separators=(",", ":")))


def failure_value(error):
    return {
        "ok": False,
        "reason_code": error.reason_code,
        "reason": error.reason,
    }


def bounded_text(value):
    value = "" if value is None else str(value)
    value = "".join(
        "?" if ord(char) < 32 or ord(char) == 127 else char
        for char in value
    )
    raw = value.encode("utf-8")
    if len(raw) <= MAX_NAME_BYTES:
        return value
    return raw[:MAX_NAME_BYTES].decode("utf-8", "ignore") + "..."


def utf8_size(value):
    try:
        return len(value.encode("utf-8"))
    except (AttributeError, UnicodeEncodeError):
        return None


def parse_json_integer(value):
    # Python integers do not overflow, but values later cross GI/D-Bus integer
    # boundaries.  Reject oversized JSON numbers at the parser boundary so an
    # unused or nested field cannot smuggle one farther into the helper.
    digits = value[1:] if value.startswith("-") else value
    if len(digits) > 19:
        raise ValueError("JSON integer exceeds safe limits")
    parsed = int(value)
    if abs(parsed) > MAX_JSON_INTEGER:
        raise ValueError("JSON integer exceeds safe limits")
    return parsed


def reject_json_non_integer(_value):
    # The request protocol has no floating-point fields.  This also rejects the
    # non-standard NaN and Infinity constants accepted by json.loads by default.
    raise ValueError("non-integer JSON number is not supported")


def normalized_text(value):
    value = unicodedata.normalize("NFKC", bounded_text(value))
    return " ".join(value.casefold().split())


def digest_value(value):
    encoded = json.dumps(
        value,
        ensure_ascii=True,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


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
    return (
        isinstance(rect, list)
        and len(rect) == 4
        and all(isinstance(value, int) and not isinstance(value, bool) for value in rect)
        and abs(rect[0]) <= MAX_ABSOLUTE_COORDINATE
        and abs(rect[1]) <= MAX_ABSOLUTE_COORDINATE
        and rect[2] > 0
        and rect[3] > 0
        and rect[2] <= MAX_WINDOW_SIZE
        and rect[3] <= MAX_WINDOW_SIZE
        and rect[0] + rect[2] <= MAX_ABSOLUTE_COORDINATE
        and rect[1] + rect[3] <= MAX_ABSOLUTE_COORDINATE
    )


def within(value, expected, tolerance=GEOMETRY_TOLERANCE):
    return abs(value - expected) <= tolerance


def deadline_check(deadline):
    if time.monotonic() > deadline:
        reject("traversal_timeout", "AT-SPI traversal timed out")


def bounded_count(value):
    try:
        return max(0, int(value))
    except (TypeError, ValueError, OverflowError):
        return 0


def sanitized_rejections(counter):
    return {key: int(counter.get(key, 0)) for key in REJECTION_KEYS}


def protected_name(node, role_key):
    """Return a display name without ever querying a password node's name."""

    if role_key == "PASSWORD_TEXT":
        return "[protected]"
    return bounded_text(node.get_name())


def normalized_action_name(value):
    return normalized_text(value)


def action_entries_for(node):
    """Return bounded action metadata and the exact index used for invocation."""

    try:
        interface = node.get_action_iface()
    except Exception:
        interface = None
    if interface is None:
        return []
    try:
        count = min(bounded_count(interface.get_n_actions()), MAX_ACTIONS)
    except Exception:
        return []
    entries = []
    seen = set()
    for index in range(count):
        try:
            name = normalized_action_name(interface.get_action_name(index))
        except Exception:
            continue
        # Action names are app-provided strings.  Emitting arbitrary names could
        # leak content (including from a buggy password widget), so expose and
        # invoke only this fixed activation vocabulary.
        if name not in ACTIVATION_ACTIONS or name in seen:
            continue
        seen.add(name)
        entries.append({
            "name": name,
            "index": index,
            "interface": interface,
        })
    return entries


def hierarchy_identity(node, role_key, name=UNREAD):
    """Build an opaque hierarchy component; password names are never read."""

    if name is UNREAD:
        try:
            name = protected_name(node, role_key)
        except Exception:
            name = ""
    return digest_value({
        "role": role_key,
        "name": digest_value(normalized_text(name)),
    })


def window_identity(window):
    # Neither the stable id nor pid is exposed by the fingerprint.
    return digest_value({
        "pid": window.get("pid"),
        "stable_id": window.get("stable_id", ""),
    })


def semantic_fingerprint(role, name, actions, ancestors, window):
    """Return an opaque identity stable across child-index and geometry changes."""

    descriptor = {
        "version": 1,
        "window": window_identity(window),
        "role": role,
        "name": digest_value(normalized_text(name)),
        "actions": sorted(actions),
        # Nearby hierarchy helps separate equally named controls without exposing
        # ancestor names.  Limiting it avoids making the identity overly brittle.
        "ancestors": list(ancestors[-4:]),
    }
    return FINGERPRINT_PREFIX + digest_value(descriptor)


def actionable(role_key, states):
    return (
        role_key in ROLE_NAMES
        and states["visible"]
        and states["showing"]
        and states["sensitive"]
        and states["enabled"]
    )


def make_candidate(
    node,
    path,
    window,
    Atspi,
    ancestors=(),
    ancestor_nodes=(),
    rejection_counter=None,
    role_key=None,
    name=UNREAD,
):
    """Create public target data plus private invocation metadata."""

    rejected = rejection_counter if rejection_counter is not None else Counter()
    if role_key is None:
        try:
            role_key = enum_key(node.get_role())
        except Exception:
            rejected["inaccessible"] += 1
            return None
    if role_key not in ROLE_NAMES:
        rejected["unsupported_role"] += 1
        return None
    try:
        states = states_for(node, Atspi)
    except Exception:
        rejected["inaccessible"] += 1
        return None
    if not actionable(role_key, states):
        rejected["unavailable_state"] += 1
        return None
    try:
        relative = rect_for(node, Atspi.CoordType.WINDOW)
    except Exception:
        rejected["inaccessible"] += 1
        return None
    if not valid_rect(relative):
        rejected["invalid_bounds"] += 1
        return None
    left, top, width, height = relative
    if (
        left < 0
        or top < 0
        or left + width > window["width"]
        or top + height > window["height"]
    ):
        rejected["outside_window"] += 1
        return None
    if name is UNREAD:
        try:
            name = protected_name(node, role_key)
        except Exception:
            rejected["inaccessible"] += 1
            return None
    if name is None:
        rejected["inaccessible"] += 1
        return None
    action_entries = action_entries_for(node)
    actions = [entry["name"] for entry in action_entries]
    role = ROLE_NAMES[role_key]
    bounds = {
        "x": window["x"] + left,
        "y": window["y"] + top,
        "width": width,
        "height": height,
    }
    public = {
        "id": "atspi:" + ".".join(str(index) for index in path),
        "fingerprint": semantic_fingerprint(
            role,
            name,
            actions,
            ancestors,
            window,
        ),
        "role": role,
        "name": name,
        "actions": actions,
        "direct_activation": any(name in ACTIVATION_ACTIONS for name in actions),
        "states": states,
        "bounds": bounds,
        "center": {
            "x": bounds["x"] + width // 2,
            "y": bounds["y"] + height // 2,
        },
    }
    return {
        "target": public,
        "node": node,
        "path": tuple(path),
        "role_key": role_key,
        "action_entries": action_entries,
        "ancestors": tuple(ancestors),
        "ancestor_nodes": tuple(ancestor_nodes),
    }


def target_data(node, path, window, Atspi):
    """Compatibility wrapper used by focused tests and older callers."""

    candidate = make_candidate(node, path, window, Atspi)
    return candidate["target"] if candidate is not None else None


def parse_path(target_id):
    if not isinstance(target_id, str) or not target_id.startswith("atspi:"):
        reject("invalid_target_id", "invalid semantic target id")
    suffix = target_id[6:]
    if not suffix or len(suffix) > 160:
        reject("invalid_target_id", "invalid semantic target id")
    parts = suffix.split(".")
    if (
        len(parts) > MAX_DEPTH + 2
        or any(
            not part.isascii()
            or not part.isdigit()
            or len(part) > 3
            for part in parts
        )
    ):
        reject("invalid_target_id", "invalid semantic target id")
    path = [int(part) for part in parts]
    if any(index < 0 or index >= MAX_CHILDREN for index in path):
        reject("invalid_target_id", "invalid semantic target id")
    return path


def parse_fingerprint(value):
    if not isinstance(value, str) or FINGERPRINT_RE.fullmatch(value) is None:
        reject("invalid_fingerprint", "invalid semantic target fingerprint")
    return value


def validate_window(window, required=True):
    if window is None and not required:
        return None
    if not isinstance(window, dict):
        reject("invalid_window", "invalid focused window")
    required_keys = ("pid", "title", "x", "y", "width", "height", "stable_id")
    if any(key not in window for key in required_keys):
        reject("invalid_window", "incomplete focused window")
    if (
        not isinstance(window["pid"], int)
        or isinstance(window["pid"], bool)
        or window["pid"] <= 0
        or window["pid"] > MAX_PID
    ):
        reject("invalid_window", "invalid focused-window pid")
    if not all(
        isinstance(window[key], int) and not isinstance(window[key], bool)
        for key in ("x", "y", "width", "height")
    ):
        reject("invalid_window", "invalid focused-window bounds")
    if window["width"] <= 0 or window["height"] <= 0:
        reject("invalid_window", "invalid focused-window bounds")
    if (
        abs(window["x"]) > MAX_ABSOLUTE_COORDINATE
        or abs(window["y"]) > MAX_ABSOLUTE_COORDINATE
        or window["width"] > MAX_WINDOW_SIZE
        or window["height"] > MAX_WINDOW_SIZE
        or window["x"] + window["width"] > MAX_ABSOLUTE_COORDINATE
        or window["y"] + window["height"] > MAX_ABSOLUTE_COORDINATE
    ):
        reject("invalid_window", "focused-window bounds exceed safe limits")
    title_size = utf8_size(window["title"])
    if title_size is None or title_size > 4096:
        reject("invalid_window", "invalid focused-window title")
    stable_id_size = utf8_size(window["stable_id"])
    if (
        not isinstance(window["stable_id"], str)
        or not window["stable_id"]
        or stable_id_size is None
        or stable_id_size > 256
    ):
        reject("invalid_window", "invalid focused-window stable id")
    return window


def parse_filters(request, window):
    query = request.get("query")
    if query is not None:
        query_size = utf8_size(query)
        if (
            not isinstance(query, str)
            or not query.strip()
            or query_size is None
            or query_size > MAX_QUERY_BYTES
        ):
            reject("invalid_filter", "query must be a non-empty bounded string")
        query = normalized_text(query)

    roles = request.get("roles")
    if roles is not None:
        if (
            not isinstance(roles, list)
            or not roles
            or len(roles) > MAX_ROLE_FILTERS
            or any(not isinstance(role, str) or role not in PUBLIC_ROLES for role in roles)
            or len(set(roles)) != len(roles)
        ):
            reject("invalid_filter", "roles must contain unique supported semantic roles")
        roles = frozenset(roles)

    near = request.get("near")
    if near is not None:
        if not isinstance(near, dict) or set(near) - {"x", "y", "radius"}:
            reject("invalid_filter", "near must contain x, y, and optional radius")
        if any(
            not isinstance(near.get(key), int) or isinstance(near.get(key), bool)
            for key in ("x", "y")
        ):
            reject("invalid_filter", "near coordinates must be integers")
        if (
            near["x"] < window["x"]
            or near["x"] >= window["x"] + window["width"]
            or near["y"] < window["y"]
            or near["y"] >= window["y"] + window["height"]
        ):
            reject("invalid_filter", "near coordinates must be inside the focused window")
        radius = near.get("radius")
        if radius is not None and (
            not isinstance(radius, int)
            or isinstance(radius, bool)
            or radius <= 0
            or radius > MAX_NEAR_RADIUS
        ):
            reject("invalid_filter", "near radius must be a positive bounded integer")
        near = {"x": near["x"], "y": near["y"], "radius": radius}

    max_results = request.get("max_results", MAX_RESULTS)
    if (
        not isinstance(max_results, int)
        or isinstance(max_results, bool)
        or max_results < 1
        or max_results > MAX_RESULTS
    ):
        reject("invalid_filter", "max_results must be between 1 and 64")
    return {
        "query": query,
        "roles": roles,
        "near": near,
        "max_results": max_results,
    }


def load_request():
    operations = {"discover", "resolve", "activate", "focused"}
    if len(sys.argv) != 2 or sys.argv[1] not in operations:
        reject("invalid_operation", "invalid operation")
    try:
        stream = getattr(sys.stdin, "buffer", sys.stdin)
        raw = stream.read(MAX_REQUEST_BYTES + 1)
        if isinstance(raw, str):
            raw = raw.encode("utf-8")
        if len(raw) > MAX_REQUEST_BYTES:
            reject("invalid_request", "request exceeds the safe size limit")
        request = json.loads(
            raw,
            parse_int=parse_json_integer,
            parse_float=reject_json_non_integer,
            parse_constant=reject_json_non_integer,
        )
    except HelperFailure:
        raise
    except Exception:
        reject("invalid_request", "invalid request")
    if not isinstance(request, dict):
        reject("invalid_request", "invalid request")
    operation = sys.argv[1]
    window = validate_window(request.get("window"))
    allowed = {
        "discover": {"window", "query", "roles", "near", "max_results"},
        "resolve": {"window", "target_id", "fingerprint", "expected"},
        "activate": {"window", "target_id", "fingerprint", "expected", "action"},
        "focused": {"window"},
    }
    if set(request) - allowed[operation]:
        reject("invalid_request", "request contains unsupported fields")
    if operation == "discover":
        parse_filters(request, window)
    elif operation in {"resolve", "activate"}:
        expected_identity(request, window)
        if operation == "activate":
            validate_activation_request(request.get("action"))
    return operation, request, window


def import_atspi():
    try:
        import gi
        gi.require_version("Atspi", "2.0")
        from gi.repository import Atspi
        return Atspi
    except Exception:
        reject(
            "atspi_bindings_unavailable",
            "AT-SPI Python bindings are unavailable",
        )


def get_desktop(Atspi):
    try:
        return Atspi.get_desktop(0)
    except Exception:
        return None


def find_application(Atspi, pid, deadline, desktop=None):
    desktop = desktop if desktop is not None else get_desktop(Atspi)
    if desktop is None:
        return None
    try:
        reported_count = bounded_count(desktop.get_child_count())
    except Exception:
        return None
    if reported_count > MAX_CHILDREN:
        reject(
            "semantic_search_incomplete",
            "AT-SPI application search was truncated",
        )
    count = min(reported_count, MAX_CHILDREN)
    matches = []
    for index in range(count):
        deadline_check(deadline)
        try:
            candidate = desktop.get_child_at_index(index)
            if candidate is not None and int(candidate.get_process_id()) == pid:
                matches.append(candidate)
        except Exception:
            continue
    if len(matches) > 1:
        reject(
            "focused_application_ambiguous",
            "multiple AT-SPI applications match the focused process",
        )
    return matches[0] if matches else None


def choose_window(app, window, Atspi, deadline):
    candidates = []
    try:
        reported_count = bounded_count(app.get_child_count())
    except Exception:
        return None
    if reported_count > MAX_CHILDREN:
        reject(
            "semantic_search_incomplete",
            "AT-SPI window search was truncated",
        )
    count = min(reported_count, MAX_CHILDREN)
    for index in range(count):
        deadline_check(deadline)
        try:
            node = app.get_child_at_index(index)
            role_key = enum_key(node.get_role())
            states = states_for(node, Atspi)
            if (
                role_key not in WINDOW_ROLES
                or not states["visible"]
                or not states["showing"]
            ):
                continue
            rect = rect_for(node, Atspi.CoordType.WINDOW)
            if not valid_rect(rect):
                continue
            calibrated = (
                within(rect[0], 0)
                and within(rect[1], 0)
                and within(rect[2], window["width"])
                and within(rect[3], window["height"])
            )
            if not calibrated:
                continue
            name = bounded_text(node.get_name())
            score = (
                (2 if name == window["title"] else 0)
                + (1 if rect[2:] == [window["width"], window["height"]] else 0)
            )
            candidates.append((score, index, node, name, rect))
        except Exception:
            continue
    if not candidates:
        return None
    candidates.sort(key=lambda item: (item[0], -item[1]), reverse=True)
    best = candidates[0]
    if len(candidates) > 1 and candidates[1][0] == best[0]:
        reject(
            "focused_window_ambiguous",
            "multiple AT-SPI windows match the focused window",
        )
    return best[2], [best[1]], best[3], best[4]


def scan_candidates(root, root_path, window, Atspi, deadline):
    """Traverse once and return every bounded actionable candidate."""

    candidates = []
    rejected = Counter()
    visited = 0
    truncated = False
    stack = [(root, list(root_path), 0, (), ())]
    while stack:
        deadline_check(deadline)
        node, path, depth, ancestors, ancestor_nodes = stack.pop()
        if visited >= MAX_NODES:
            truncated = True
            break
        visited += 1

        try:
            role_key = enum_key(node.get_role())
        except Exception:
            rejected["inaccessible"] += 1
            role_key = None
        if role_key is None:
            own_identity = digest_value({"role": "INACCESSIBLE"})
            candidate = None
        else:
            try:
                name = protected_name(node, role_key)
            except Exception:
                name = None
            own_identity = hierarchy_identity(
                node,
                role_key,
                "" if name is None else name,
            )
            candidate = make_candidate(
                node,
                path,
                window,
                Atspi,
                ancestors,
                ancestor_nodes,
                rejected,
                role_key=role_key,
                name=name,
            )
        if candidate is not None:
            candidate["root"] = root
            candidates.append(candidate)

        try:
            count = bounded_count(node.get_child_count())
        except Exception:
            rejected["inaccessible"] += 1
            continue
        if depth >= MAX_DEPTH:
            if count > 0:
                truncated = True
            continue
        if count > MAX_CHILDREN:
            truncated = True
        next_ancestors = ancestors + (own_identity,)
        next_ancestor_nodes = ancestor_nodes + (node,)
        for index in reversed(range(min(count, MAX_CHILDREN))):
            try:
                child = node.get_child_at_index(index)
            except Exception:
                rejected["inaccessible"] += 1
                continue
            if child is not None:
                stack.append((
                    child,
                    path + [index],
                    depth + 1,
                    next_ancestors,
                    next_ancestor_nodes,
                ))
    return candidates, visited, truncated, rejected


def distance_to(candidate, near):
    center = candidate["target"]["center"]
    return math.hypot(center["x"] - near["x"], center["y"] - near["y"])


def query_score(target, query):
    if query is None:
        return 0
    name = normalized_text(target["name"])
    role = normalized_text(target["role"].replace("_", " "))
    actions = target["actions"]
    if name == query:
        return 1000
    if name.startswith(query):
        return 800
    if query in name:
        return 650
    if role == query or target["role"] == query:
        return 500
    if any(query == action for action in actions):
        return 450
    if query in role:
        return 350
    return -1


def candidate_rank(candidate, filters):
    target = candidate["target"]
    score = ROLE_RANK.get(target["role"], 0)
    if target["name"] and target["name"] != "[protected]":
        score += 30
    if target["direct_activation"]:
        score += 25
    if target["states"]["focused"]:
        score += 20
    if target["states"]["selected"]:
        score += 10
    if target["states"]["editable"]:
        score += 8
    score += max(0, query_score(target, filters["query"]))
    near = filters["near"]
    distance = distance_to(candidate, near) if near is not None else 0.0
    if near is not None:
        score += max(0, 300 - int(distance))
    return score, distance


def filtered_ranked_candidates(candidates, filters, rejected):
    kept = []
    for candidate in candidates:
        target = candidate["target"]
        if filters["roles"] is not None and target["role"] not in filters["roles"]:
            rejected["role_filter"] += 1
            continue
        if query_score(target, filters["query"]) < 0:
            rejected["query_filter"] += 1
            continue
        score, distance = candidate_rank(candidate, filters)
        near = filters["near"]
        if near is not None and near["radius"] is not None and distance > near["radius"]:
            rejected["near_filter"] += 1
            continue
        kept.append((score, distance, candidate))

    fingerprint_counts = Counter(
        candidate["target"]["fingerprint"] for _, _, candidate in kept
    )
    rejected["fingerprint_collision"] += sum(
        count for count in fingerprint_counts.values() if count > 1
    )
    kept.sort(key=lambda item: (-item[0], item[1], item[2]["path"]))
    return kept


def discover(root, root_path, window, Atspi, deadline, filters=None):
    """Compatibility discovery API; returns public targets and traversal data."""

    filters = filters or {
        "query": None,
        "roles": None,
        "near": None,
        "max_results": MAX_RESULTS,
    }
    candidates, visited, traversal_truncated, rejected = scan_candidates(
        root,
        root_path,
        window,
        Atspi,
        deadline,
    )
    ranked = filtered_ranked_candidates(candidates, filters, rejected)
    selected = ranked[:filters["max_results"]]
    targets = []
    for rank, (_, _, candidate) in enumerate(selected, start=1):
        target = dict(candidate["target"])
        target["rank"] = rank
        targets.append(target)
    truncated = traversal_truncated or len(ranked) > len(selected)
    return targets, visited, truncated, rejected, len(ranked)


def validate_expected_geometry(expected, window):
    bounds = expected.get("bounds")
    if bounds is not None:
        if (
            not isinstance(bounds, dict)
            or set(bounds) != {"x", "y", "width", "height"}
            or any(
                not isinstance(bounds.get(key), int)
                or isinstance(bounds.get(key), bool)
                for key in ("x", "y", "width", "height")
            )
            or bounds["width"] <= 0
            or bounds["height"] <= 0
            or bounds["width"] > MAX_WINDOW_SIZE
            or bounds["height"] > MAX_WINDOW_SIZE
            or bounds["x"] < window["x"]
            or bounds["y"] < window["y"]
            or bounds["x"] + bounds["width"] > window["x"] + window["width"]
            or bounds["y"] + bounds["height"] > window["y"] + window["height"]
        ):
            reject(
                "invalid_expected_geometry",
                "semantic target bounds exceed safe limits",
            )

    center = expected.get("center")
    if center is not None:
        if (
            not isinstance(center, dict)
            or set(center) != {"x", "y"}
            or any(
                not isinstance(center.get(key), int)
                or isinstance(center.get(key), bool)
                for key in ("x", "y")
            )
            or center["x"] < window["x"]
            or center["x"] >= window["x"] + window["width"]
            or center["y"] < window["y"]
            or center["y"] >= window["y"] + window["height"]
        ):
            reject(
                "invalid_expected_geometry",
                "semantic target center exceeds safe limits",
            )
        if bounds is not None and (
            center["x"] != bounds["x"] + bounds["width"] // 2
            or center["y"] != bounds["y"] + bounds["height"] // 2
        ):
            reject(
                "invalid_expected_geometry",
                "semantic target geometry is inconsistent",
            )


def expected_identity(request, window=None):
    expected = request.get("expected")
    if not isinstance(expected, dict):
        reject("missing_identity", "missing semantic target identity")
    expected_role = expected.get("role")
    if expected_role is not None and (
        not isinstance(expected_role, str)
        or expected_role not in PUBLIC_ROLES
    ):
        reject("invalid_identity", "invalid semantic target role")
    if window is not None:
        validate_expected_geometry(expected, window)
    request_fingerprint = request.get("fingerprint")
    expected_fingerprint = expected.get("fingerprint")
    if (
        request_fingerprint is not None
        and expected_fingerprint is not None
        and request_fingerprint != expected_fingerprint
    ):
        reject("identity_mismatch", "semantic target identity is inconsistent")
    fingerprint = (
        request_fingerprint
        if request_fingerprint is not None
        else expected_fingerprint
    )
    parse_fingerprint(fingerprint)
    request_target_id = request.get("target_id")
    expected_target_id = expected.get("id")
    if (
        request_target_id is not None
        and expected_target_id is not None
        and request_target_id != expected_target_id
    ):
        reject("identity_mismatch", "semantic target id is inconsistent")
    target_id = (
        request_target_id
        if request_target_id is not None
        else expected_target_id
    )
    if target_id is not None:
        parse_path(target_id)
    return expected, fingerprint


def select_fingerprint_match(matches, expected):
    if len(matches) == 1:
        return matches[0]
    # Geometry is intentionally not used to break an identity collision.  Two
    # identical controls can reorder while retaining their old positions; using
    # the prior bounds would then authorize the wrong logical control.
    reject(
        "target_ambiguous",
        "semantic target fingerprint is ambiguous; discover targets again",
    )


def resolve_candidate(root, root_path, request, window, Atspi, deadline):
    expected, fingerprint = expected_identity(request, window)
    candidates, visited, truncated, rejected = scan_candidates(
        root,
        root_path,
        window,
        Atspi,
        deadline,
    )
    if truncated:
        reject(
            "semantic_search_incomplete",
            "AT-SPI search was truncated; action was not sent",
        )
    matches = [
        candidate
        for candidate in candidates
        if candidate["target"]["fingerprint"] == fingerprint
    ]
    if not matches:
        reject(
            "target_stale",
            "semantic target changed or is no longer actionable; discover targets again",
        )
    candidate = select_fingerprint_match(matches, expected)
    expected_role = expected.get("role")
    if expected_role is not None and candidate["target"]["role"] != expected_role:
        reject(
            "target_changed",
            "semantic target identity changed; discover targets again",
        )
    return candidate, visited, rejected


def resolve(root, root_path, request, window, Atspi, deadline):
    candidate, _, _ = resolve_candidate(
        root,
        root_path,
        request,
        window,
        Atspi,
        deadline,
    )
    return candidate["target"]


def validate_activation_request(requested_action):
    if requested_action is not None:
        action_size = utf8_size(requested_action)
        if (
            not isinstance(requested_action, str)
            or not requested_action
            or action_size is None
            or action_size > MAX_NAME_BYTES
        ):
            reject("invalid_action", "invalid AT-SPI action")
        requested_action = normalized_action_name(requested_action)
        if requested_action not in ACTIVATION_ACTIONS:
            reject("action_unavailable", "requested AT-SPI activation is unavailable")
    return requested_action


def choose_activation(candidate, requested_action):
    requested_action = validate_activation_request(requested_action)
    if requested_action is not None:
        for entry in candidate["action_entries"]:
            if entry["name"] == requested_action:
                return entry
        reject("action_unavailable", "requested AT-SPI activation is unavailable")
    by_name = {
        entry["name"]: entry
        for entry in candidate["action_entries"]
        if entry["name"] in ACTIVATION_ACTIONS
    }
    for name in ACTIVATION_PREFERENCE:
        if name in by_name:
            return by_name[name]
    reject(
        "action_unavailable",
        "semantic target has no verified direct AT-SPI activation",
    )


def same_accessible(left, right):
    if left is right:
        return True
    try:
        if bool(left == right):
            return True
    except Exception:
        pass
    # PyGObject can materialize a new proxy for the same remote accessible.
    # Its object path plus process id is a stable in-process equality fallback.
    try:
        left_path = getattr(left, "path", None)
        right_path = getattr(right, "path", None)
        if (
            isinstance(left_path, str)
            and left_path
            and left_path == right_path
            and int(left.get_process_id()) == int(right.get_process_id())
        ):
            return True
    except Exception:
        pass
    return False


def ancestor_sample_matches(left, right):
    """Compare opaque identities and the actual accessible proxies."""

    left_nodes, left_identities = left
    right_nodes, right_identities = right
    return (
        left_identities == right_identities
        and len(left_nodes) == len(right_nodes)
        and all(
            same_accessible(left_node, right_node)
            for left_node, right_node in zip(left_nodes, right_nodes)
        )
    )


def candidate_ancestor_sample(candidate):
    nodes = tuple(candidate.get("ancestor_nodes", ()))
    identities = tuple(candidate.get("ancestors", ()))
    if not nodes or len(nodes) != len(identities):
        reject(
            "target_changed",
            "semantic target hierarchy cannot be verified; action was not sent",
        )
    return nodes, identities


def live_ancestor_sample(candidate, deadline):
    """Read and internally validate the current parent chain."""

    root = candidate.get("root")
    if root is None:
        reject(
            "target_changed",
            "semantic target hierarchy cannot be verified; action was not sent",
        )
    nodes = []
    identities = []
    current = candidate["node"]
    for _ in range(MAX_DEPTH + 1):
        deadline_check(deadline)
        try:
            current = current.get_parent()
        except Exception:
            current = None
        if current is None:
            reject(
                "target_changed",
                "semantic target hierarchy changed; action was not sent",
            )
        try:
            role_key = enum_key(current.get_role())
            identity = hierarchy_identity(current, role_key)
        except Exception:
            reject(
                "target_changed",
                "semantic target hierarchy changed; action was not sent",
            )
        nodes.append(current)
        identities.append(identity)
        if same_accessible(current, root):
            nodes.reverse()
            identities.reverse()
            # Reading role/name metadata above can itself race a reparent.  Walk
            # back down the sampled chain and verify every parent edge before
            # treating the sample as coherent.
            descendant = candidate["node"]
            for expected_parent in reversed(nodes):
                deadline_check(deadline)
                try:
                    actual_parent = descendant.get_parent()
                except Exception:
                    actual_parent = None
                if (
                    actual_parent is None
                    or not same_accessible(actual_parent, expected_parent)
                ):
                    reject(
                        "target_changed",
                        "semantic target hierarchy changed; action was not sent",
                    )
                descendant = expected_parent
            return tuple(nodes), tuple(identities)
    reject(
        "target_changed",
        "semantic target hierarchy changed; action was not sent",
    )


def refresh_activation_candidate(candidate, window, Atspi, deadline):
    expected_ancestors = candidate_ancestor_sample(candidate)
    ancestors_before = live_ancestor_sample(candidate, deadline)
    if not ancestor_sample_matches(ancestors_before, expected_ancestors):
        reject(
            "target_changed",
            "semantic target hierarchy changed before activation; action was not sent",
        )
    refreshed = make_candidate(
        candidate["node"],
        candidate["path"],
        window,
        Atspi,
        ancestors_before[1],
        ancestors_before[0],
    )
    if refreshed is None:
        reject(
            "target_stale",
            "semantic target is no longer safely actionable; action was not sent",
        )
    if (
        refreshed["target"]["fingerprint"]
        != candidate["target"]["fingerprint"]
    ):
        reject(
            "target_changed",
            "semantic target changed before activation; action was not sent",
        )
    refreshed["root"] = candidate["root"]
    ancestors_after = live_ancestor_sample(refreshed, deadline)
    if not ancestor_sample_matches(ancestors_after, ancestors_before):
        reject(
            "target_changed",
            "semantic target hierarchy changed before activation; action was not sent",
        )
    refreshed["ancestor_nodes"] = ancestors_after[0]
    refreshed["ancestors"] = ancestors_after[1]
    return refreshed


def activate_candidate(
    candidate,
    window,
    Atspi,
    deadline,
    requested_action=None,
):
    deadline_check(deadline)
    candidate = refresh_activation_candidate(candidate, window, Atspi, deadline)
    entry = choose_activation(candidate, requested_action)
    final_ancestors = live_ancestor_sample(candidate, deadline)
    if not ancestor_sample_matches(
        final_ancestors,
        candidate_ancestor_sample(candidate),
    ):
        reject(
            "target_changed",
            "semantic target hierarchy changed before activation; action was not sent",
        )
    deadline_check(deadline)
    try:
        delivered = entry["interface"].do_action(entry["index"])
    except Exception:
        # The remote process may have received the method call before the
        # exception.  Retrying would risk duplicate input.
        reject(
            "activation_delivery_ambiguous",
            "AT-SPI activation outcome is ambiguous; action was not retried",
        )
    if delivered is not True:
        reject(
            "activation_rejected",
            "AT-SPI rejected the activation; action was not retried",
        )
    # Return immediately after the remote method acknowledges delivery.  A
    # second fallible AT-SPI read here could hang until the outer process timeout
    # and hide the successful, irreversible action from the caller.
    return entry["name"], None, candidate["target"]


def focused_result(root, root_path, window, Atspi, deadline):
    candidates, visited, truncated, rejected = scan_candidates(
        root,
        root_path,
        window,
        Atspi,
        deadline,
    )
    if truncated:
        return {
            "ok": True,
            "available": False,
            "typing_safe": False,
            "reason_code": "semantic_search_incomplete",
            "reason": "AT-SPI focus search was truncated",
            "visited": visited,
            "rejections": sanitized_rejections(rejected),
        }
    focused = [
        candidate
        for candidate in candidates
        if candidate["target"]["states"]["focused"]
    ]
    safe = [
        candidate
        for candidate in focused
        if candidate["target"]["role"] in TYPING_ROLES
        and candidate["target"]["states"]["editable"]
    ]
    if len(focused) == 1 and len(safe) == 1:
        return {
            "ok": True,
            "available": True,
            "typing_safe": True,
            "target": safe[0]["target"],
            "visited": visited,
            "rejections": sanitized_rejections(rejected),
        }
    if len(focused) > 1:
        reason_code = "focused_control_ambiguous"
        reason = "multiple AT-SPI controls report focus"
    elif focused:
        reason_code = "focused_control_not_editable"
        reason = "the focused AT-SPI control is not safely editable"
    else:
        reason_code = "focused_control_unavailable"
        reason = "no focused editable AT-SPI control was found"
    return {
        "ok": True,
        "available": bool(focused),
        "typing_safe": False,
        "reason_code": reason_code,
        "reason": reason,
        "visited": visited,
        "rejections": sanitized_rejections(rejected),
    }


def unavailable_window_result(reason_code, reason):
    return {
        "ok": True,
        "available": False,
        "reason_code": reason_code,
        "reason": reason,
        "targets": [],
    }


def handle_window_operation(operation, request, window, Atspi, deadline=None):
    deadline = time.monotonic() + DEADLINE_SECONDS if deadline is None else deadline
    if not isinstance(request, dict):
        reject("invalid_request", "invalid request")
    window = validate_window(window)
    filters = parse_filters(request, window) if operation == "discover" else None
    if operation in {"resolve", "activate"}:
        expected_identity(request, window)
    requested_action = (
        validate_activation_request(request.get("action"))
        if operation == "activate"
        else None
    )
    app = find_application(Atspi, window["pid"], deadline)
    if app is None:
        if operation == "discover":
            return unavailable_window_result(
                "focused_application_unavailable",
                "focused application is not exposed through AT-SPI",
            )
        reject(
            "focused_application_unavailable",
            "focused application is not exposed through AT-SPI",
        )
    selected = choose_window(app, window, Atspi, deadline)
    if selected is None:
        if operation == "discover":
            return unavailable_window_result(
                "window_calibration_failed",
                "focused AT-SPI window bounds could not be calibrated",
            )
        reject(
            "window_calibration_failed",
            "focused AT-SPI window bounds could not be calibrated",
        )
    root, root_path, window_name, _ = selected

    if operation == "discover":
        targets, visited, truncated, rejected, matched = discover(
            root,
            root_path,
            window,
            Atspi,
            deadline,
            filters,
        )
        return {
            "ok": True,
            "available": True,
            "window": {
                "name": window_name,
                "pid": window["pid"],
                "stable_id": window["stable_id"],
            },
            "targets": targets,
            "visited": visited,
            "matched": matched,
            "truncated": truncated,
            "rejections": sanitized_rejections(rejected),
            "limits": {
                "depth": MAX_DEPTH,
                "nodes": MAX_NODES,
                "results": MAX_RESULTS,
            },
        }
    if operation == "focused":
        return focused_result(root, root_path, window, Atspi, deadline)

    candidate, visited, rejected = resolve_candidate(
        root,
        root_path,
        request,
        window,
        Atspi,
        deadline,
    )
    if operation == "resolve":
        return {
            "ok": True,
            "target": candidate["target"],
            "visited": visited,
            "rejections": sanitized_rejections(rejected),
        }
    if operation == "activate":
        action, state_changed, activated_target = activate_candidate(
            candidate,
            window,
            Atspi,
            deadline,
            requested_action,
        )
        return {
            "ok": True,
            "activated": True,
            "delivery": "delivered",
            "action": action,
            "state_changed": state_changed,
            "target": activated_target,
            "visited": visited,
            "rejections": sanitized_rejections(rejected),
        }
    reject("invalid_operation", "invalid operation")


def main():
    try:
        operation, request, window = load_request()
        Atspi = import_atspi()
        emit(handle_window_operation(operation, request, window, Atspi))
    except HelperFailure as error:
        emit(failure_value(error))
    except Exception:
        # Never place exception text in the protocol: proxy errors can contain
        # accessible names, bus addresses, or other local details.
        emit({
            "ok": False,
            "reason_code": "internal_error",
            "reason": "AT-SPI helper failed safely",
        })


if __name__ == "__main__":
    main()
