"""Regression tests for the bounded AT-SPI discovery helper.

These tests use small fakes for accessible trees and optionally import GI only
to verify its enum representation. They never connect to an accessibility bus,
so loading the production module remains safe in headless CI.
"""

import importlib.util
import io
import json
import os
import sys
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


MODULE_PATH = Path(__file__).resolve().parents[1] / "scripts" / "computer_atspi.py"
SPEC = importlib.util.spec_from_file_location("computer_atspi_under_test", MODULE_PATH)
computer_atspi = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(computer_atspi)


class FakeEnum:
    def __init__(self, value_name):
        self.value_name = value_name


class FakeStringEnum:
    value_name = None

    def __str__(self):
        return "Atspi.Role.CHECK_BOX"


class FakeStateSet:
    def __init__(self, present):
        self.present = set(present)

    def contains(self, state):
        return state in self.present


class FakeNode:
    def __init__(
        self,
        role,
        name="Control",
        states=(),
        rect=(10, 20, 30, 40),
        children=(),
        actions=(),
        pid=None,
        action_result=True,
        action_error=False,
        action_name_delay=0,
        on_role_read=None,
    ):
        self._role = FakeEnum(role)
        self._name = name
        self.name_reads = 0
        self.value_reads = 0
        self._states = FakeStateSet(states)
        self._children = list(children)
        self._parent = None
        for child in self._children:
            child._parent = self
        self._actions = list(actions)
        self._pid = pid
        self.action_result = action_result
        self.action_error = action_error
        self.action_name_delay = action_name_delay
        self.on_role_read = on_role_read
        self.action_calls = []
        self._rect = SimpleNamespace(
            x=rect[0],
            y=rect[1],
            width=rect[2],
            height=rect[3],
        )

    def get_role(self):
        if self.on_role_read is not None:
            self.on_role_read()
        return self._role

    def get_name(self):
        self.name_reads += 1
        return self._name

    def get_value(self):
        self.value_reads += 1
        return self._name

    def get_state_set(self):
        return self._states

    def get_extents(self, _coord):
        return self._rect

    def get_child_count(self):
        return len(self._children)

    def get_child_at_index(self, index):
        return self._children[index]

    def get_parent(self):
        return self._parent

    def get_process_id(self):
        return self._pid

    def get_action_iface(self):
        return self

    def get_n_actions(self):
        return len(self._actions)

    def get_action_name(self, index):
        if self.action_name_delay:
            time.sleep(self.action_name_delay)
        return self._actions[index]

    def do_action(self, index):
        self.action_calls.append(index)
        if self.action_error:
            raise RuntimeError("private proxy diagnostic")
        if callable(self.action_result):
            return self.action_result(self, index)
        return self.action_result


FakeAtspi = SimpleNamespace(
    StateType=SimpleNamespace(**{name: name for name in computer_atspi.STATE_NAMES}),
    CoordType=SimpleNamespace(WINDOW="window"),
)

WINDOW = {
    "pid": 4242,
    "title": "Example",
    "stable_id": "window-stable-1",
    "x": 100,
    "y": 200,
    "width": 800,
    "height": 600,
}


def enabled_states(**overrides):
    states = {
        "VISIBLE": True,
        "SHOWING": True,
        "SENSITIVE": True,
        "ENABLED": True,
    }
    states.update(overrides)
    return {name for name, present in states.items() if present}


def fake_tree(children, title=WINDOW["title"]):
    window = FakeNode(
        "ATSPI_ROLE_FRAME",
        name=title,
        states=enabled_states(),
        rect=(0, 0, WINDOW["width"], WINDOW["height"]),
        children=children,
    )
    application = FakeNode(
        "ATSPI_ROLE_APPLICATION",
        states=(),
        children=[window],
        pid=WINDOW["pid"],
    )
    desktop = FakeNode(
        "ATSPI_ROLE_DESKTOP_FRAME",
        states=(),
        children=[application],
    )
    atspi = SimpleNamespace(
        StateType=FakeAtspi.StateType,
        CoordType=FakeAtspi.CoordType,
        get_desktop=lambda _index: desktop,
    )
    return atspi, desktop, application, window


def handle(operation, children, request=None):
    atspi, _, _, window = fake_tree(children)
    payload = {"window": dict(WINDOW)}
    payload.update(request or {})
    result = computer_atspi.handle_window_operation(
        operation,
        payload,
        payload["window"],
        atspi,
        deadline=time.monotonic() + 10,
    )
    return result, atspi, window


class EnumKeyTests(unittest.TestCase):
    def test_removes_only_the_exact_atspi_role_prefix(self):
        cases = {
            "ATSPI_ROLE_BUTTON": "BUTTON",
            "ATSPI_ROLE_CHECK_BOX": "CHECK_BOX",
            "ATSPI_ROLE_PASSWORD_TEXT": "PASSWORD_TEXT",
            "ATSPI_ROLE_PAGE_TAB": "PAGE_TAB",
            "ATSPI_ROLE_TOGGLE_BUTTON": "TOGGLE_BUTTON",
        }
        for value_name, expected in cases.items():
            with self.subTest(value_name=value_name):
                self.assertEqual(
                    computer_atspi.enum_key(FakeEnum(value_name)),
                    expected,
                )

    def test_falls_back_to_the_final_dotted_component(self):
        self.assertEqual(
            computer_atspi.enum_key(FakeStringEnum()),
            "CHECK_BOX",
        )
        self.assertEqual(
            computer_atspi.enum_key(FakeEnum("CUSTOM_ROLE_CHECK_BOX")),
            "CUSTOM_ROLE_CHECK_BOX",
        )

    def test_installed_gi_role_names_match_the_parser_contract(self):
        try:
            import gi

            gi.require_version("Atspi", "2.0")
            from gi.repository import Atspi
        except (ImportError, ValueError) as error:
            if os.environ.get("BONE_TEST_REQUIRE_ATSPI_GI") == "1":
                self.fail(f"AT-SPI GI bindings are required: {error}")
            self.skipTest(f"AT-SPI GI bindings are unavailable: {error}")

        for role_name in sorted(computer_atspi.ROLE_NAMES):
            with self.subTest(role_name=role_name):
                self.assertEqual(
                    computer_atspi.enum_key(getattr(Atspi.Role, role_name)),
                    role_name,
                )


class TargetDataTests(unittest.TestCase):
    def test_password_target_name_is_always_redacted(self):
        secret_name = "hunter2 password"
        node = FakeNode(
            "ATSPI_ROLE_PASSWORD_TEXT",
            name=secret_name,
            states=enabled_states(EDITABLE=True, FOCUSABLE=True),
        )

        target = computer_atspi.target_data(
            node,
            [2, 4],
            WINDOW,
            FakeAtspi,
        )

        self.assertIsNotNone(target)
        self.assertEqual(node.name_reads, 0)
        self.assertEqual(node.value_reads, 0)
        self.assertEqual(target["role"], "password_text")
        self.assertEqual(target["name"], "[protected]")
        self.assertNotIn(secret_name, repr(target))

    def test_all_supported_roles_keep_their_complete_role_name(self):
        cases = {
            "ATSPI_ROLE_BUTTON": "button",
            "ATSPI_ROLE_CHECK_BOX": "check_box",
            "ATSPI_ROLE_COMBO_BOX": "combo_box",
            "ATSPI_ROLE_ENTRY": "entry",
            "ATSPI_ROLE_PASSWORD_TEXT": "password_text",
            "ATSPI_ROLE_LINK": "link",
            "ATSPI_ROLE_LIST_ITEM": "list_item",
            "ATSPI_ROLE_MENU_ITEM": "menu_item",
            "ATSPI_ROLE_PAGE_TAB": "page_tab",
            "ATSPI_ROLE_RADIO_BUTTON": "radio_button",
            "ATSPI_ROLE_SLIDER": "slider",
            "ATSPI_ROLE_SPIN_BUTTON": "spin_button",
            "ATSPI_ROLE_TEXT": "entry",
            "ATSPI_ROLE_TOGGLE_BUTTON": "toggle_button",
            "ATSPI_ROLE_TREE_ITEM": "tree_item",
        }
        self.assertEqual(
            {role.removeprefix("ATSPI_ROLE_") for role in cases},
            set(computer_atspi.ROLE_NAMES),
        )
        for role, expected in cases.items():
            with self.subTest(role=role):
                target = computer_atspi.target_data(
                    FakeNode(role, states=enabled_states()),
                    [1],
                    WINDOW,
                    FakeAtspi,
                )
                self.assertIsNotNone(target)
                self.assertEqual(target["role"], expected)

    def test_disabled_target_is_dropped_even_if_focusable_and_editable(self):
        node = FakeNode(
            "ATSPI_ROLE_ENTRY",
            states=enabled_states(
                ENABLED=False,
                EDITABLE=True,
                FOCUSABLE=True,
            ),
        )

        target = computer_atspi.target_data(node, [3], WINDOW, FakeAtspi)

        self.assertIsNone(target)

    def test_hidden_insensitive_or_disabled_target_is_dropped(self):
        for state in ("VISIBLE", "SHOWING", "SENSITIVE", "ENABLED"):
            with self.subTest(missing_state=state):
                target = computer_atspi.target_data(
                    FakeNode(
                        "ATSPI_ROLE_BUTTON",
                        states=enabled_states(**{state: False}),
                    ),
                    [5],
                    WINDOW,
                    FakeAtspi,
                )
                self.assertIsNone(target)


class ActionableTests(unittest.TestCase):
    def test_enabled_visible_sensitive_control_is_actionable(self):
        states = {
            "visible": True,
            "showing": True,
            "sensitive": True,
            "enabled": True,
            "focusable": False,
            "editable": False,
        }
        self.assertTrue(computer_atspi.actionable("BUTTON", states))

    def test_disabled_control_is_not_actionable(self):
        for focusable, editable in ((True, False), (False, True), (True, True)):
            with self.subTest(focusable=focusable, editable=editable):
                states = {
                    "visible": True,
                    "showing": True,
                    "sensitive": True,
                    "enabled": False,
                    "focusable": focusable,
                    "editable": editable,
                }
                self.assertFalse(computer_atspi.actionable("ENTRY", states))


class FilterValidationTests(unittest.TestCase):
    def test_accepts_all_bounded_discovery_filters(self):
        filters = computer_atspi.parse_filters(
            {
                "query": "  APPLY  ",
                "roles": ["button", "link"],
                "near": {"x": 120, "y": 220, "radius": 50},
                "max_results": 3,
            },
            WINDOW,
        )

        self.assertEqual(filters["query"], "apply")
        self.assertEqual(filters["roles"], frozenset({"button", "link"}))
        self.assertEqual(
            filters["near"],
            {"x": 120, "y": 220, "radius": 50},
        )
        self.assertEqual(filters["max_results"], 3)

    def test_rejects_unbounded_or_ambiguous_filters(self):
        invalid = (
            {"query": ""},
            {"query": "x" * (computer_atspi.MAX_QUERY_BYTES + 1)},
            {"roles": []},
            {"roles": ["button", "button"]},
            {"roles": ["not_a_role"]},
            {"near": {"x": 1}},
            {"near": {"x": 1, "y": 2, "private": "value"}},
            {"near": {"x": True, "y": 2}},
            {"near": {"x": 1, "y": 2, "radius": 0}},
            {"max_results": 0},
            {"max_results": computer_atspi.MAX_RESULTS + 1},
            {"max_results": True},
        )
        for request in invalid:
            with self.subTest(request=request):
                with self.assertRaises(computer_atspi.HelperFailure) as raised:
                    computer_atspi.parse_filters(request, WINDOW)
                self.assertEqual(raised.exception.reason_code, "invalid_filter")

    def test_rejects_geometry_outside_safe_numeric_limits(self):
        for key, value in (
            ("x", computer_atspi.MAX_ABSOLUTE_COORDINATE + 1),
            ("y", -(computer_atspi.MAX_ABSOLUTE_COORDINATE + 1)),
            ("width", computer_atspi.MAX_WINDOW_SIZE + 1),
            ("height", computer_atspi.MAX_WINDOW_SIZE + 1),
        ):
            with self.subTest(key=key):
                window = dict(WINDOW)
                window[key] = value
                with self.assertRaises(computer_atspi.HelperFailure) as raised:
                    computer_atspi.validate_window(window)
                self.assertEqual(raised.exception.reason_code, "invalid_window")

        for window in (
            {**WINDOW, "pid": computer_atspi.MAX_PID + 1},
            {
                **WINDOW,
                "x": computer_atspi.MAX_ABSOLUTE_COORDINATE,
                "width": 1,
            },
            {
                **WINDOW,
                "y": computer_atspi.MAX_ABSOLUTE_COORDINATE,
                "height": 1,
            },
        ):
            with self.subTest(window=window):
                with self.assertRaises(computer_atspi.HelperFailure) as raised:
                    computer_atspi.validate_window(window)
                self.assertEqual(raised.exception.reason_code, "invalid_window")

    def test_rejects_unbounded_remembered_target_geometry(self):
        fingerprint = computer_atspi.FINGERPRINT_PREFIX + ("a" * 64)
        for expected in (
            {
                "fingerprint": fingerprint,
                "role": "button",
                "bounds": {
                    "x": WINDOW["x"],
                    "y": WINDOW["y"],
                    "width": computer_atspi.MAX_WINDOW_SIZE + 1,
                    "height": 10,
                },
            },
            {
                "fingerprint": fingerprint,
                "role": "button",
                "center": {
                    "x": WINDOW["x"] + WINDOW["width"],
                    "y": WINDOW["y"],
                },
            },
        ):
            with self.subTest(expected=expected):
                with self.assertRaises(computer_atspi.HelperFailure) as raised:
                    computer_atspi.expected_identity(
                        {"expected": expected},
                        WINDOW,
                    )
                self.assertEqual(
                    raised.exception.reason_code,
                    "invalid_expected_geometry",
                )


class RequestLoadingTests(unittest.TestCase):
    def load_raw(self, raw, operation="discover"):
        stdin = SimpleNamespace(buffer=io.BytesIO(raw))
        with (
            mock.patch.object(sys, "argv", ["computer_atspi.py", operation]),
            mock.patch.object(sys, "stdin", stdin),
        ):
            return computer_atspi.load_request()

    def test_rejects_stdin_larger_than_the_protocol_limit(self):
        raw = b" " * (computer_atspi.MAX_REQUEST_BYTES + 1)

        with self.assertRaises(computer_atspi.HelperFailure) as raised:
            self.load_raw(raw)

        self.assertEqual(raised.exception.reason_code, "invalid_request")

    def test_rejects_json_integers_outside_signed_64_bit_range(self):
        payload = {"window": {**WINDOW, "pid": computer_atspi.MAX_JSON_INTEGER + 1}}

        with self.assertRaises(computer_atspi.HelperFailure) as raised:
            self.load_raw(json.dumps(payload).encode("utf-8"))

        self.assertEqual(raised.exception.reason_code, "invalid_request")

    def test_rejects_floats_and_non_finite_numbers_at_the_parser_boundary(self):
        for value in (1.0, float("nan"), float("inf")):
            with self.subTest(value=value):
                payload = {
                    "window": dict(WINDOW),
                    "max_results": value,
                }
                with self.assertRaises(computer_atspi.HelperFailure) as raised:
                    self.load_raw(json.dumps(payload).encode("utf-8"))
                self.assertEqual(raised.exception.reason_code, "invalid_request")


class DiscoveryTests(unittest.TestCase):
    def controls(self):
        return [
            FakeNode(
                "ATSPI_ROLE_BUTTON",
                name="Cancel",
                states=enabled_states(FOCUSABLE=True),
                rect=(20, 20, 80, 30),
            ),
            FakeNode(
                "ATSPI_ROLE_BUTTON",
                name="Apply changes",
                states=enabled_states(FOCUSABLE=True),
                rect=(300, 300, 100, 40),
                actions=["click"],
            ),
            FakeNode(
                "ATSPI_ROLE_ENTRY",
                name="Search",
                states=enabled_states(FOCUSABLE=True, EDITABLE=True),
                rect=(200, 100, 180, 30),
            ),
            FakeNode(
                "ATSPI_ROLE_BUTTON",
                name="Disabled private control",
                states=enabled_states(ENABLED=False),
                rect=(10, 70, 100, 30),
            ),
            FakeNode(
                "ATSPI_ROLE_LABEL",
                name="Structural private label",
                states=enabled_states(),
                rect=(10, 110, 100, 30),
            ),
            FakeNode(
                "ATSPI_ROLE_LINK",
                name="Outside",
                states=enabled_states(),
                rect=(790, 590, 50, 20),
                actions=["jump"],
            ),
        ]

    def test_query_and_role_filters_rank_exact_semantics_first(self):
        result, _, _ = handle(
            "discover",
            self.controls(),
            {
                "query": "apply",
                "roles": ["button"],
                "max_results": 5,
            },
        )

        self.assertTrue(result["ok"])
        self.assertTrue(result["available"])
        self.assertEqual([target["name"] for target in result["targets"]], ["Apply changes"])
        target = result["targets"][0]
        self.assertEqual(target["rank"], 1)
        self.assertEqual(target["actions"], ["click"])
        self.assertTrue(target["direct_activation"])
        self.assertRegex(target["fingerprint"], computer_atspi.FINGERPRINT_RE)
        self.assertGreater(result["rejections"]["query_filter"], 0)
        self.assertGreater(result["rejections"]["role_filter"], 0)

    def test_near_radius_filters_and_nearness_changes_ranking(self):
        result, _, _ = handle(
            "discover",
            self.controls(),
            {
                "roles": ["button"],
                "near": {"x": 150, "y": 235, "radius": 100},
            },
        )

        self.assertEqual([target["name"] for target in result["targets"]], ["Cancel"])
        self.assertGreater(result["rejections"]["near_filter"], 0)

    def test_max_results_is_applied_after_ranking_and_reports_truncation(self):
        result, _, _ = handle(
            "discover",
            self.controls(),
            {"max_results": 2},
        )

        self.assertEqual(len(result["targets"]), 2)
        self.assertEqual(result["targets"][0]["name"], "Apply changes")
        self.assertEqual([target["rank"] for target in result["targets"]], [1, 2])
        self.assertGreater(result["matched"], 2)
        self.assertTrue(result["truncated"])

    def test_rejection_counters_have_only_stable_privacy_safe_categories(self):
        result, _, _ = handle("discover", self.controls())

        self.assertEqual(
            set(result["rejections"]),
            set(computer_atspi.REJECTION_KEYS),
        )
        self.assertGreater(result["rejections"]["unsupported_role"], 0)
        self.assertGreater(result["rejections"]["unavailable_state"], 0)
        self.assertGreater(result["rejections"]["outside_window"], 0)
        self.assertNotIn("Structural private label", repr(result["rejections"]))
        self.assertNotIn("Disabled private control", repr(result["rejections"]))


class FingerprintResolutionTests(unittest.TestCase):
    def discover_one(self, node, siblings=()):
        children = list(siblings) + [node]
        result, atspi, window = handle("discover", children)
        target = next(
            target for target in result["targets"]
            if target["name"] == node._name
        )
        return target, atspi, window

    def test_fingerprint_is_opaque_and_does_not_contain_the_name(self):
        private_name = "Quarterly payroll approval"
        node = FakeNode(
            "ATSPI_ROLE_BUTTON",
            name=private_name,
            states=enabled_states(),
            actions=["click"],
        )
        target, _, _ = self.discover_one(node)

        self.assertRegex(target["fingerprint"], computer_atspi.FINGERPRINT_RE)
        self.assertNotIn(private_name, target["fingerprint"])
        self.assertNotIn("payroll", target["fingerprint"])

    def test_resolves_by_fingerprint_after_child_path_changes(self):
        other = FakeNode(
            "ATSPI_ROLE_BUTTON",
            name="Other",
            states=enabled_states(),
            rect=(100, 100, 50, 20),
        )
        wanted = FakeNode(
            "ATSPI_ROLE_BUTTON",
            name="Apply",
            states=enabled_states(),
            rect=(200, 200, 50, 20),
            actions=["click", "press"],
        )
        target, atspi, window = self.discover_one(wanted, [other])
        old_id = target["id"]
        self.assertEqual(old_id, "atspi:0.1")

        window._children[:] = [wanted, other]
        wanted._states.present.add("FOCUSED")
        wanted._actions[:] = ["press", "click"]
        result = computer_atspi.handle_window_operation(
            "resolve",
            {
                "window": dict(WINDOW),
                "target_id": old_id,
                "expected": target,
            },
            dict(WINDOW),
            atspi,
            deadline=time.monotonic() + 10,
        )

        self.assertTrue(result["ok"])
        self.assertEqual(result["target"]["id"], "atspi:0.0")
        self.assertEqual(result["target"]["fingerprint"], target["fingerprint"])
        self.assertTrue(result["target"]["states"]["focused"])

    def test_changed_name_makes_the_fingerprint_stale(self):
        wanted = FakeNode(
            "ATSPI_ROLE_BUTTON",
            name="Apply",
            states=enabled_states(),
            actions=["click"],
        )
        target, atspi, _ = self.discover_one(wanted)
        wanted._name = "Delete"

        with self.assertRaises(computer_atspi.HelperFailure) as raised:
            computer_atspi.handle_window_operation(
                "resolve",
                {
                    "window": dict(WINDOW),
                    "target_id": target["id"],
                    "expected": target,
                },
                dict(WINDOW),
                atspi,
                deadline=time.monotonic() + 10,
            )

        self.assertEqual(raised.exception.reason_code, "target_stale")

    def test_identical_fingerprint_at_distinct_positions_is_rejected_as_ambiguous(self):
        first = FakeNode(
            "ATSPI_ROLE_BUTTON",
            name="Apply",
            states=enabled_states(),
            rect=(100, 100, 50, 20),
            actions=["click"],
        )
        second = FakeNode(
            "ATSPI_ROLE_BUTTON",
            name="Apply",
            states=enabled_states(),
            rect=(300, 300, 50, 20),
            actions=["click"],
        )
        discovered, atspi, _ = handle("discover", [first, second])
        target = discovered["targets"][0]
        self.assertEqual(
            discovered["rejections"]["fingerprint_collision"],
            2,
        )

        with self.assertRaises(computer_atspi.HelperFailure) as raised:
            computer_atspi.handle_window_operation(
                "resolve",
                {
                    "window": dict(WINDOW),
                    "target_id": target["id"],
                    "expected": target,
                },
                dict(WINDOW),
                atspi,
                deadline=time.monotonic() + 10,
            )

        self.assertEqual(raised.exception.reason_code, "target_ambiguous")


class ActivationTests(unittest.TestCase):
    def activation_fixture(self, **overrides):
        options = {
            "role": "ATSPI_ROLE_BUTTON",
            "name": "Apply",
            "states": enabled_states(),
            "actions": ["show menu", "click", "press"],
            "action_result": True,
        }
        options.update(overrides)
        node = FakeNode(**options)
        discovered, atspi, _ = handle("discover", [node])
        target = discovered["targets"][0]
        request = {
            "window": dict(WINDOW),
            "target_id": target["id"],
            "expected": target,
        }
        return node, target, atspi, request

    def test_direct_activation_re_resolves_and_invokes_preferred_action_once(self):
        node, target, atspi, request = self.activation_fixture()

        result = computer_atspi.handle_window_operation(
            "activate",
            request,
            dict(WINDOW),
            atspi,
            deadline=time.monotonic() + 10,
        )

        self.assertTrue(result["activated"])
        self.assertEqual(result["delivery"], "delivered")
        self.assertEqual(result["action"], "click")
        self.assertEqual(result["target"]["fingerprint"], target["fingerprint"])
        self.assertEqual(node.action_calls, [1])

    def test_explicit_advertised_activation_is_honored(self):
        node, _, atspi, request = self.activation_fixture()
        request["action"] = "press"

        result = computer_atspi.handle_window_operation(
            "activate",
            request,
            dict(WINDOW),
            atspi,
            deadline=time.monotonic() + 10,
        )

        self.assertEqual(result["action"], "press")
        self.assertEqual(node.action_calls, [2])

    def test_rejected_activation_is_never_retried(self):
        node, _, atspi, request = self.activation_fixture(action_result=False)

        with self.assertRaises(computer_atspi.HelperFailure) as raised:
            computer_atspi.handle_window_operation(
                "activate",
                request,
                dict(WINDOW),
                atspi,
                deadline=time.monotonic() + 10,
            )

        self.assertEqual(raised.exception.reason_code, "activation_rejected")
        self.assertEqual(node.action_calls, [1])

    def test_exception_after_dispatch_is_ambiguous_and_never_retried(self):
        node, _, atspi, request = self.activation_fixture(action_error=True)

        with self.assertRaises(computer_atspi.HelperFailure) as raised:
            computer_atspi.handle_window_operation(
                "activate",
                request,
                dict(WINDOW),
                atspi,
                deadline=time.monotonic() + 10,
            )

        self.assertEqual(
            raised.exception.reason_code,
            "activation_delivery_ambiguous",
        )
        self.assertNotIn("private proxy diagnostic", raised.exception.reason)
        self.assertEqual(node.action_calls, [1])

    def test_non_activation_action_is_rejected_before_dispatch(self):
        node, _, atspi, request = self.activation_fixture(actions=["show menu"])

        with self.assertRaises(computer_atspi.HelperFailure) as raised:
            computer_atspi.handle_window_operation(
                "activate",
                request,
                dict(WINDOW),
                atspi,
                deadline=time.monotonic() + 10,
            )

        self.assertEqual(raised.exception.reason_code, "action_unavailable")
        self.assertEqual(node.action_calls, [])

    def test_action_index_is_refreshed_after_the_full_tree_scan(self):
        node, _, atspi, request = self.activation_fixture(
            actions=["click", "press"],
        )
        changed = []

        def reorder_actions_once():
            if not changed:
                node._actions[:] = ["press", "click"]
                changed.append(True)

        mutator = FakeNode(
            "ATSPI_ROLE_LABEL",
            states=enabled_states(),
            on_role_read=reorder_actions_once,
        )
        window = atspi.get_desktop(0)._children[0]._children[0]
        window._children.append(mutator)

        result = computer_atspi.handle_window_operation(
            "activate",
            request,
            dict(WINDOW),
            atspi,
            deadline=time.monotonic() + 10,
        )

        self.assertEqual(result["action"], "click")
        self.assertEqual(node.action_calls, [1])

    def test_disabled_after_scan_is_rejected_before_dispatch(self):
        node, _, atspi, request = self.activation_fixture()
        changed = []

        def disable_once():
            if not changed:
                node._states.present.discard("ENABLED")
                changed.append(True)

        mutator = FakeNode(
            "ATSPI_ROLE_LABEL",
            states=enabled_states(),
            on_role_read=disable_once,
        )
        window = atspi.get_desktop(0)._children[0]._children[0]
        window._children.append(mutator)

        with self.assertRaises(computer_atspi.HelperFailure) as raised:
            computer_atspi.handle_window_operation(
                "activate",
                request,
                dict(WINDOW),
                atspi,
                deadline=time.monotonic() + 10,
            )

        self.assertEqual(raised.exception.reason_code, "target_stale")
        self.assertEqual(node.action_calls, [])

    def test_changed_ancestor_identity_is_rejected_before_dispatch(self):
        node = FakeNode(
            "ATSPI_ROLE_BUTTON",
            name="Delete",
            states=enabled_states(),
            actions=["click"],
        )
        panel = FakeNode(
            "ATSPI_ROLE_PANEL",
            name="Account A",
            states=enabled_states(),
            rect=(0, 0, 400, 400),
            children=[node],
        )
        discovered, atspi, window = handle("discover", [panel])
        target = next(
            candidate for candidate in discovered["targets"]
            if candidate["name"] == "Delete"
        )
        changed = []

        def change_ancestor_once():
            if not changed:
                panel._name = "Account B"
                changed.append(True)

        mutator = FakeNode(
            "ATSPI_ROLE_LABEL",
            states=enabled_states(),
            on_role_read=change_ancestor_once,
        )
        mutator._parent = window
        window._children.append(mutator)

        with self.assertRaises(computer_atspi.HelperFailure) as raised:
            computer_atspi.handle_window_operation(
                "activate",
                {
                    "window": dict(WINDOW),
                    "target_id": target["id"],
                    "expected": target,
                },
                dict(WINDOW),
                atspi,
                deadline=time.monotonic() + 10,
            )

        self.assertEqual(raised.exception.reason_code, "target_changed")
        self.assertEqual(node.action_calls, [])

    def test_reparented_during_final_target_refresh_is_rejected(self):
        node = FakeNode(
            "ATSPI_ROLE_BUTTON",
            name="Delete",
            states=enabled_states(),
            actions=["click"],
        )
        account_a = FakeNode(
            "ATSPI_ROLE_PANEL",
            name="Account A",
            states=enabled_states(),
            rect=(0, 0, 300, 300),
            children=[node],
        )
        account_b = FakeNode(
            "ATSPI_ROLE_PANEL",
            name="Account B",
            states=enabled_states(),
            rect=(300, 0, 300, 300),
        )
        discovered, atspi, _ = handle("discover", [account_a, account_b])
        target = next(
            candidate for candidate in discovered["targets"]
            if candidate["name"] == "Delete"
        )
        role_reads = []

        def reparent_on_second_activation_read():
            role_reads.append(True)
            if len(role_reads) == 2:
                account_a._children.remove(node)
                account_b._children.append(node)
                node._parent = account_b

        node.on_role_read = reparent_on_second_activation_read

        with self.assertRaises(computer_atspi.HelperFailure) as raised:
            computer_atspi.handle_window_operation(
                "activate",
                {
                    "window": dict(WINDOW),
                    "target_id": target["id"],
                    "expected": target,
                },
                dict(WINDOW),
                atspi,
                deadline=time.monotonic() + 10,
            )

        self.assertEqual(raised.exception.reason_code, "target_changed")
        self.assertEqual(node.action_calls, [])

    def test_reparent_to_identical_ancestor_during_refresh_is_rejected(self):
        node = FakeNode(
            "ATSPI_ROLE_BUTTON",
            name="Delete",
            states=enabled_states(),
            actions=["click"],
        )
        account_a = FakeNode(
            "ATSPI_ROLE_PANEL",
            name="Account",
            states=enabled_states(),
            rect=(0, 0, 300, 300),
            children=[node],
        )
        account_b = FakeNode(
            "ATSPI_ROLE_PANEL",
            name="Account",
            states=enabled_states(),
            rect=(300, 0, 300, 300),
        )
        discovered, atspi, _ = handle("discover", [account_a, account_b])
        target = next(
            candidate for candidate in discovered["targets"]
            if candidate["name"] == "Delete"
        )
        role_reads = []

        def reparent_on_refresh():
            role_reads.append(True)
            if len(role_reads) == 2:
                account_a._children.remove(node)
                account_b._children.append(node)
                node._parent = account_b

        node.on_role_read = reparent_on_refresh

        with self.assertRaises(computer_atspi.HelperFailure) as raised:
            computer_atspi.handle_window_operation(
                "activate",
                {
                    "window": dict(WINDOW),
                    "target_id": target["id"],
                    "expected": target,
                },
                dict(WINDOW),
                atspi,
                deadline=time.monotonic() + 10,
            )

        self.assertEqual(raised.exception.reason_code, "target_changed")
        self.assertEqual(node.action_calls, [])

    def test_reparent_during_ancestor_sample_is_rejected(self):
        node = FakeNode(
            "ATSPI_ROLE_BUTTON",
            name="Delete",
            states=enabled_states(),
            actions=["click"],
        )
        account_a = FakeNode(
            "ATSPI_ROLE_PANEL",
            name="Account",
            states=enabled_states(),
            rect=(0, 0, 300, 300),
            children=[node],
        )
        account_b = FakeNode(
            "ATSPI_ROLE_PANEL",
            name="Account",
            states=enabled_states(),
            rect=(300, 0, 300, 300),
        )
        discovered, atspi, _ = handle("discover", [account_a, account_b])
        target = next(
            candidate for candidate in discovered["targets"]
            if candidate["name"] == "Delete"
        )
        role_reads = []

        def reparent_while_sampling():
            role_reads.append(True)
            if len(role_reads) == 2:
                account_a._children.remove(node)
                account_b._children.append(node)
                node._parent = account_b

        account_a.on_role_read = reparent_while_sampling

        with self.assertRaises(computer_atspi.HelperFailure) as raised:
            computer_atspi.handle_window_operation(
                "activate",
                {
                    "window": dict(WINDOW),
                    "target_id": target["id"],
                    "expected": target,
                },
                dict(WINDOW),
                atspi,
                deadline=time.monotonic() + 10,
            )

        self.assertEqual(raised.exception.reason_code, "target_changed")
        self.assertEqual(node.action_calls, [])

    def test_expired_request_is_rejected_immediately_before_dispatch(self):
        node, _, atspi, request = self.activation_fixture(
            actions=["click"],
        )
        node.action_name_delay = 0.02

        with self.assertRaises(computer_atspi.HelperFailure) as raised:
            computer_atspi.handle_window_operation(
                "activate",
                request,
                dict(WINDOW),
                atspi,
                deadline=time.monotonic() + 0.005,
            )

        self.assertEqual(raised.exception.reason_code, "traversal_timeout")
        self.assertEqual(node.action_calls, [])


class FocusInspectionTests(unittest.TestCase):
    def test_focused_editable_entry_is_safe_for_typing(self):
        entry = FakeNode(
            "ATSPI_ROLE_ENTRY",
            name="Search",
            states=enabled_states(
                FOCUSED=True,
                FOCUSABLE=True,
                EDITABLE=True,
            ),
            actions=["SECRET value in action name", "activate"],
        )

        result, _, _ = handle("focused", [entry])

        self.assertTrue(result["available"])
        self.assertTrue(result["typing_safe"])
        self.assertEqual(result["target"]["role"], "entry")
        self.assertEqual(result["target"]["actions"], ["activate"])
        self.assertTrue(result["target"]["states"]["focused"])
        self.assertTrue(result["target"]["states"]["editable"])
        self.assertNotIn("SECRET value in action name", repr(result))

    def test_focused_button_is_reported_but_not_safe_for_typing(self):
        button = FakeNode(
            "ATSPI_ROLE_BUTTON",
            name="Submit",
            states=enabled_states(FOCUSED=True, FOCUSABLE=True),
            actions=["click"],
        )

        result, _, _ = handle("focused", [button])

        self.assertTrue(result["available"])
        self.assertFalse(result["typing_safe"])
        self.assertEqual(result["reason_code"], "focused_control_not_editable")
        self.assertNotIn("target", result)

    def test_multiple_editable_focus_claims_are_rejected(self):
        entries = [
            FakeNode(
                "ATSPI_ROLE_ENTRY",
                name=f"Entry {index}",
                states=enabled_states(FOCUSED=True, EDITABLE=True),
            )
            for index in range(2)
        ]

        result, _, _ = handle("focused", entries)

        self.assertFalse(result["typing_safe"])
        self.assertEqual(result["reason_code"], "focused_control_ambiguous")

    def test_editable_focus_plus_any_other_focus_claim_is_ambiguous(self):
        entry = FakeNode(
            "ATSPI_ROLE_ENTRY",
            name="Search",
            states=enabled_states(FOCUSED=True, EDITABLE=True),
        )
        button = FakeNode(
            "ATSPI_ROLE_BUTTON",
            name="Submit",
            states=enabled_states(FOCUSED=True),
            actions=["click"],
        )

        result, _, _ = handle("focused", [entry, button])

        self.assertFalse(result["typing_safe"])
        self.assertEqual(result["reason_code"], "focused_control_ambiguous")


class PasswordPrivacyTests(unittest.TestCase):
    def test_password_name_and_value_are_never_read_across_all_operations(self):
        secret = "SECRET value exposed as name"
        password = FakeNode(
            "ATSPI_ROLE_PASSWORD_TEXT",
            name=secret,
            states=enabled_states(
                FOCUSED=True,
                FOCUSABLE=True,
                EDITABLE=True,
            ),
            actions=["SECRET password action", "activate"],
        )
        discovered, atspi, window = handle("discover", [password])
        target = discovered["targets"][0]
        self.assertEqual(target["name"], "[protected]")
        self.assertEqual(target["actions"], ["activate"])
        self.assertNotIn("SECRET password action", repr(discovered))

        common_request = {
            "window": dict(WINDOW),
            "target_id": target["id"],
            "expected": target,
        }
        resolved = computer_atspi.handle_window_operation(
            "resolve",
            common_request,
            dict(WINDOW),
            atspi,
            deadline=time.monotonic() + 10,
        )
        focused = computer_atspi.handle_window_operation(
            "focused",
            {"window": dict(WINDOW)},
            dict(WINDOW),
            atspi,
            deadline=time.monotonic() + 10,
        )
        activated = computer_atspi.handle_window_operation(
            "activate",
            common_request,
            dict(WINDOW),
            atspi,
            deadline=time.monotonic() + 10,
        )

        self.assertEqual(resolved["target"]["name"], "[protected]")
        self.assertEqual(focused["target"]["name"], "[protected]")
        self.assertEqual(activated["target"]["name"], "[protected]")
        self.assertEqual(password.name_reads, 0)
        self.assertEqual(password.value_reads, 0)
        self.assertNotIn(secret, repr(discovered))
        self.assertNotIn(secret, repr(resolved))
        self.assertNotIn(secret, repr(focused))
        self.assertNotIn(secret, repr(activated))
        self.assertIs(window._children[0], password)


class ApplicationWindowSelectionTests(unittest.TestCase):
    def atspi_with_applications(self, applications):
        desktop = FakeNode(
            "ATSPI_ROLE_DESKTOP_FRAME",
            states=(),
            children=applications,
        )
        return SimpleNamespace(
            StateType=FakeAtspi.StateType,
            CoordType=FakeAtspi.CoordType,
            get_desktop=lambda _index: desktop,
        )

    def application(self, windows):
        return FakeNode(
            "ATSPI_ROLE_APPLICATION",
            states=(),
            children=windows,
            pid=WINDOW["pid"],
        )

    def calibrated_window(self):
        return FakeNode(
            "ATSPI_ROLE_FRAME",
            name=WINDOW["title"],
            states=enabled_states(),
            rect=(0, 0, WINDOW["width"], WINDOW["height"]),
        )

    def test_duplicate_application_roots_for_one_pid_are_ambiguous(self):
        atspi = self.atspi_with_applications([
            self.application([self.calibrated_window()]),
            self.application([self.calibrated_window()]),
        ])

        with self.assertRaises(computer_atspi.HelperFailure) as raised:
            computer_atspi.handle_window_operation(
                "discover",
                {"window": dict(WINDOW)},
                dict(WINDOW),
                atspi,
                deadline=time.monotonic() + 10,
            )

        self.assertEqual(
            raised.exception.reason_code,
            "focused_application_ambiguous",
        )

    def test_truncated_application_enumeration_fails_closed(self):
        applications = [
            FakeNode(
                "ATSPI_ROLE_APPLICATION",
                states=(),
                pid=index + 1,
            )
            for index in range(computer_atspi.MAX_CHILDREN + 1)
        ]
        atspi = self.atspi_with_applications(applications)

        with self.assertRaises(computer_atspi.HelperFailure) as raised:
            computer_atspi.handle_window_operation(
                "discover",
                {"window": dict(WINDOW)},
                dict(WINDOW),
                atspi,
                deadline=time.monotonic() + 10,
            )

        self.assertEqual(
            raised.exception.reason_code,
            "semantic_search_incomplete",
        )

    def test_truncated_window_enumeration_fails_closed(self):
        windows = [
            self.calibrated_window()
            for _ in range(computer_atspi.MAX_CHILDREN + 1)
        ]
        atspi = self.atspi_with_applications([self.application(windows)])

        with self.assertRaises(computer_atspi.HelperFailure) as raised:
            computer_atspi.handle_window_operation(
                "discover",
                {"window": dict(WINDOW)},
                dict(WINDOW),
                atspi,
                deadline=time.monotonic() + 10,
            )

        self.assertEqual(
            raised.exception.reason_code,
            "semantic_search_incomplete",
        )


class DoctorTests(unittest.TestCase):
    def test_doctor_reports_bindings_bus_desktop_and_window_without_names(self):
        atspi, _, _, _ = fake_tree([])
        result = computer_atspi.doctor_report(
            atspi,
            {
                "gi_version": "3.0",
                "atspi_api": "2.0",
                "atspi_version": "2.54",
            },
            dict(WINDOW),
            environment={"DBUS_SESSION_BUS_ADDRESS": "private-address"},
            deadline=time.monotonic() + 10,
        )

        self.assertTrue(result["ok"])
        self.assertTrue(result["available"])
        self.assertTrue(result["checks"]["desktop"]["ok"])
        self.assertTrue(result["checks"]["focused_application"]["ok"])
        self.assertTrue(result["checks"]["window_calibration"]["ok"])
        self.assertNotIn(WINDOW["title"], repr(result))
        self.assertNotIn("private-address", repr(result))

    def test_doctor_stops_safely_before_desktop_when_session_bus_is_missing(self):
        desktop_calls = []
        atspi = SimpleNamespace(
            get_desktop=lambda index: desktop_calls.append(index),
        )

        result = computer_atspi.doctor_report(
            atspi,
            {
                "gi_version": "3.0",
                "atspi_api": "2.0",
                "atspi_version": "2.54",
            },
            environment={},
        )

        self.assertTrue(result["ok"])
        self.assertFalse(result["available"])
        self.assertEqual(result["reason_code"], "session_bus_unavailable")
        self.assertEqual(desktop_calls, [])

    def test_doctor_reports_missing_bindings_as_a_diagnostic_not_a_crash(self):
        result = computer_atspi.doctor_report(
            None,
            {
                "gi_version": None,
                "atspi_api": "2.0",
                "atspi_version": None,
            },
            environment={},
        )

        self.assertTrue(result["ok"])
        self.assertFalse(result["available"])
        self.assertEqual(result["reason_code"], "atspi_bindings_unavailable")


if __name__ == "__main__":
    unittest.main()
