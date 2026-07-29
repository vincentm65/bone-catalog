"""Regression tests for the bounded AT-SPI discovery helper.

These tests use small fakes for accessible trees and optionally import GI only
to verify its enum representation. They never connect to an accessibility bus,
so loading the production module remains safe in headless CI.
"""

import importlib.util
import os
import unittest
from pathlib import Path
from types import SimpleNamespace


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
    def __init__(self, role, name="Control", states=(), rect=(10, 20, 30, 40)):
        self._role = FakeEnum(role)
        self._name = name
        self.name_reads = 0
        self.value_reads = 0
        self._states = FakeStateSet(states)
        self._rect = SimpleNamespace(
            x=rect[0],
            y=rect[1],
            width=rect[2],
            height=rect[3],
        )

    def get_role(self):
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


FakeAtspi = SimpleNamespace(
    StateType=SimpleNamespace(**{name: name for name in computer_atspi.STATE_NAMES}),
    CoordType=SimpleNamespace(WINDOW="window"),
)

WINDOW = {
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


if __name__ == "__main__":
    unittest.main()
