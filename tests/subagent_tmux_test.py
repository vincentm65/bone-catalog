#!/usr/bin/env python3
"""Smoke the named-subagent editor in the real Bone 3 TUI (no model calls).

Run: BONE_BIN=/path/to/bone3 python3 tests/subagent_tmux_test.py
Requires tmux; uses a private tmux server and temporary config/project, cleaned
on exit. Only the catalog's subagent plugin is installed in that config.
"""
from pathlib import Path
import json
import os
import shlex
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
binary = os.environ.get("BONE_BIN") or shutil.which("bone3") or shutil.which("bone")
if not binary:
    raise SystemExit("set BONE_BIN to a Bone 3 executable")
if not shutil.which("tmux"):
    raise SystemExit("tmux is required for this real-terminal smoke test")
binary = str(Path(binary).resolve())
target = "smoke:0.0"


def tmux(*args):
    return subprocess.check_output(["tmux", "-S", socket_path, *args], text=True)


def screen():
    return tmux("capture-pane", "-p", "-N", "-t", target)


def wait(text, absent=False):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        snapshot = screen()
        if (text not in snapshot) if absent else (text in snapshot):
            assert "Lua error" not in snapshot, snapshot
            return snapshot
        time.sleep(0.1)
    raise AssertionError("waiting for " + repr(text) + "\n" + screen())


def keys(*values):
    tmux("send-keys", "-t", target, *values)


def text(value):
    tmux("send-keys", "-t", target, "-l", value)


def command(value):
    text(value)
    keys("Enter")


def field(label, value):
    keys("Down", "Enter")
    wait("› " + label + ": ▏")
    text(value)
    wait(label + ": " + value)
    keys("Enter")
    wait("Enter accept", absent=True)


with tempfile.TemporaryDirectory(prefix="bone-subagent-tmux-") as raw:
    base = Path(raw)
    socket_path = str(base / "tmux.sock")
    config, project = base / "config", base / "project"
    project.mkdir()
    shutil.copytree(ROOT / "plugins/subagent", config / "plugins/subagent")
    (config / "core.lua").write_text(
        'bone.config.providers.test = { base_url = "http://127.0.0.1:1/v1", model = "local" }\n'
        'bone.config.provider = "test"\n'
    )
    settings_path = config / "settings.json"
    settings_path.write_text(json.dumps({"setup": {"skipped": True}}))
    launch = shlex.join([
        "env", "-u", "BONE_BASE_URL", "-u", "BONE_MODEL", "-u", "BONE_API_KEY",
        "-u", "BONE_SYSTEM_PROMPT", "-u", "BONE_REASONING_EFFORT",
        "BONE_CONFIG_DIR=" + str(config), "BONE_DATA_DIR=" + str(config / "sessions"), binary,
    ])
    try:
        tmux("-f", "/dev/null", "new-session", "-d", "-s", "smoke", "-x", "110", "-y", "32",
             "-c", str(project), launch)
        wait("Message bone")
        command("/subagents add smoke")
        wait("Subagents · new agent")
        wait("Name: smoke▏")
        keys("Enter")
        wait("Enter accept", absent=True)
        field("Description", "Smoke reviewer")
        # Type the reversible newline escapes offered by the prompt editor.
        field("System prompt", r"Review carefully.\nReport only actionable findings.")
        field("Provider", "test")
        field("Model", "smoke-model")
        field("Allowed tools", "shell, read_file")
        keys("C-s")
        wait("Subagents · smoke")
        expected = {
            "description": "Smoke reviewer",
            "system": "Review carefully.\nReport only actionable findings.",
            "provider": "test",
            "model": "smoke-model",
            "tools": ["shell", "read_file"],
        }
        saved = json.loads(settings_path.read_text())
        assert saved["subagent"]["agents"] == {"smoke": expected}, saved
        assert saved["setup"]["skipped"] is True, saved
        keys("Escape")
        wait("Subagents · named agents")
        keys("Escape")
        wait("Subagents ·", absent=True)
        command("/subagents smoke")
        wait("Subagents · smoke")
        wait(r"Review carefully.\nReport only actionable findings.")
        wait("Model: smoke-model")
        keys("q")
        wait("Subagents ·", absent=True)
        # /config exposes the plugin's manifest settings as a Subagents tab.
        command("/config")
        wait("Settings")
        wait("Subagents")
        # Built-in pages (e.g. Compaction) may precede this catalog plugin.
        for _ in range(12):
            if "Maximum nesting depth" in screen():
                break
            keys("Tab")
            time.sleep(0.1)
        wait("Maximum nesting depth")
        wait("Maximum concurrent subagents")
        wait("Default provider")
        wait("Default model")
        wait("Default instructions")
        keys("Escape")
        wait("Maximum nesting depth", absent=True)
        # Unload/reload and reopen: saved prompts/provider/model survive.
        command("/plugins reload subagent")
        wait("subagent: tui and core reloaded")
        command("/subagents smoke")
        wait("Subagents · smoke")
        wait("Provider: test")
        wait("Model: smoke-model")
        assert json.loads(settings_path.read_text())["subagent"]["agents"] == {"smoke": expected}
        print("PASS: real TUI /subagents add, description/system/provider/model/tools, "
              "save + settings.json, reopen/reload persistence, /config Subagents settings")
    finally:
        subprocess.run(["tmux", "-S", socket_path, "kill-server"], capture_output=True)
