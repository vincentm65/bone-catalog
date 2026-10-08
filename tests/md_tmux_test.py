#!/usr/bin/env python3
"""Standalone md plugin smoke test against an installed Bone TUI (no model calls).
Run: BONE_BIN=/path/to/bone3 python3 tests/md_tmux_test.py
Requires tmux; uses only an isolated config/session and removes it on exit.
"""
from pathlib import Path
import hashlib
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
name = "bone-md-test-" + str(os.getpid())


def tmux(*args):
    return subprocess.check_output(["tmux", *args], text=True)


def screen():
    return tmux("capture-pane", "-p", "-N", "-t", name + ":0.0")


def wait(text, absent=False):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        snapshot = screen()
        if (text not in snapshot) if absent else (text in snapshot):
            return snapshot
        time.sleep(0.1)
    raise AssertionError("waiting for " + repr(text) + "\n" + screen())


def command(text):
    tmux("send-keys", "-t", name, "-l", text)
    tmux("send-keys", "-t", name, "Enter")


with tempfile.TemporaryDirectory(prefix="bone-md-tmux-") as raw:
    base = Path(raw)
    config, project = base / "config", base / "project"
    project.mkdir()
    shutil.copytree(ROOT / "plugins/md", config / "plugins/md")
    (config / "core.lua").write_text(
        'bone.config.providers.test = { base_url = "http://127.0.0.1:1/v1", model = "local" }\n'
        'bone.config.provider = "test"\n'
    )
    (config / "settings.json").write_text(json.dumps({"setup": {"skipped": True}}))
    (project / "README.md").write_text("# Reader smoke heading\n\nBeautiful **Markdown** preview.\n")
    (project / "docs").mkdir()
    (project / "docs/space name.MD").write_text("# Nested document\n\nNested preview verified.\n")
    (project / ".hidden.md").write_text("Hidden Markdown.\n")
    (project / ".git").mkdir()
    (project / ".git/excluded.md").write_text("Not listed.\n")
    (project / "cycle").symlink_to(project, target_is_directory=True)
    launch = shlex.join(["env", "BONE_CONFIG_DIR=" + str(config), binary])
    try:
        tmux("new-session", "-d", "-s", name, "-x", "110", "-y", "32", "-c", str(project), launch)
        wait("Message bone")
        command("/md")
        wait("Files · 3")
        assert "excluded.md" not in screen()
        tmux("send-keys", "-t", name, "-l", "README")
        wait("Files · 1")
        snapshot = wait("Reader smoke heading")
        assert "Beautiful Markdown preview." in snapshot, snapshot
        assert "**Markdown**" not in snapshot, snapshot
        tmux("send-keys", "-t", name, "Enter")
        tmux("resize-window", "-t", name, "-x", "65", "-y", "22")
        wait("Reader smoke heading")
        tmux("send-keys", "-t", name, "Tab")
        wait("Files · 1")
        tmux("send-keys", "-t", name, "Escape")
        wait("Markdown ·", absent=True)
        command("/md docs/space name.MD")
        wait("Nested preview verified.")
        tmux("send-keys", "-t", name, "C-r")
        wait("Nested preview verified.")
        tmux("send-keys", "-t", name, "Escape")
        wait("Markdown ·", absent=True)
        command("/plugins unload md")
        wait("unloaded")
        command("/plugins load md")
        wait("md: tui loaded")
        command("/md README.md")
        wait("Reader smoke heading")
        # Installed copy is identical to the verified catalog package.
        for source in (ROOT / "plugins/md").rglob("*"):
            if source.is_file():
                installed = config / "plugins/md" / source.relative_to(ROOT / "plugins/md")
                assert hashlib.sha256(installed.read_bytes()).digest() == hashlib.sha256(source.read_bytes()).digest()
        print("md TUI smoke passed: scan/filter/render/resize/direct path/refresh/unload/reload")
    finally:
        subprocess.run(["tmux", "kill-session", "-t", name], capture_output=True)
