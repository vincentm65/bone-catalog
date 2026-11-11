#!/usr/bin/env python3
"""Files plugin regression test against an installed Bone TUI (no model calls).
Run: BONE_BIN=/path/to/bone3 python3 tests/files_tmux_test.py
Requires tmux and git. It runs in a tmux server of its own (-L), with an
isolated config and no display, so neither your tmux buffers nor your
clipboard are touched; everything is removed on exit.

What it holds in place (each was a bug before 3.7.0):
- a new chat opens the folder bone was started in, not the home folder
- a project under a dot-folder still lists what changed
- Git's marker reaches a file with a space in its name
- `d` shows a file's changes since the last commit
- esc never closes a file with unsaved work
- copy and paste work with no clipboard tool (tmux's buffer, the plugin's own)
- alt+1…9 and ctrl+pagedown go through the open files
- with room for both, the tree stands left of the open file
- a folder made by another program shows by itself (live refresh)
- marked files are copied into a folder, and ctrl+z takes the copy back
- a CSV file opens as a table: a column's sum, sorting, a cell edited and saved
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
server = "bone-files-test-" + str(os.getpid())
name = "files"


def tmux(*args):
    return subprocess.check_output(["tmux", "-L", server, *args], text=True)


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


def keys(*names):
    for key in names:
        tmux("send-keys", "-t", name, key)
        time.sleep(0.12)


def typed(text):
    tmux("send-keys", "-t", name, "-l", text)
    time.sleep(0.12)


def command(text):
    typed(text)
    tmux("send-keys", "-t", name, "Enter")


def git(project, *args):
    subprocess.check_call(
        ["git", "-c", "user.email=t@example.invalid", "-c", "user.name=t", *args],
        cwd=project, stdout=subprocess.DEVNULL)


with tempfile.TemporaryDirectory(prefix="bone-files-tmux-") as raw:
    base = Path(raw)
    # The project sits under a dot-folder: its own files are not hidden for that.
    config, project = base / "config", base / ".dot" / "project"
    project.mkdir(parents=True)
    (base / "run").mkdir()
    shutil.copytree(ROOT / "plugins/files", config / "plugins/files")
    (config / "core.lua").write_text(
        'bone.config.providers.test = { base_url = "http://127.0.0.1:1/v1", model = "local" }\n'
        'bone.config.provider = "test"\n'
    )
    (config / "settings.json").write_text(json.dumps({
        "setup": {"skipped": True}, "update": {"check": False},
    }))
    (project / "math.lua").write_text("local M = {}\n\nfunction M.sub(a, b)\n  return a - b\nend\n\nreturn M\n")
    git(project, "init", "-q", ".")
    git(project, "add", "-A")
    git(project, "commit", "-qm", "init")
    (project / "math.lua").write_text("local M = {}\n\nfunction M.sub(a, b)\n  return a - b - 0\nend\n\nreturn M\n")
    (project / "name with space.txt").write_text("x\n")
    (project / "notes.md").write_text("# Notes\n\nSecond file.\n")
    launch = shlex.join([
        "env", "-u", "WAYLAND_DISPLAY", "-u", "DISPLAY", "-u", "SSH_CONNECTION", "-u", "SSH_TTY",
        "XDG_RUNTIME_DIR=" + str(base / "run"), "BONE_CONFIG_DIR=" + str(config), binary,
    ])
    try:
        tmux("new-session", "-d", "-s", name, "-x", "120", "-y", "36", "-c", str(project), launch)
        wait("Message bone")

        # A new chat: the project, its markers, and what changed in it.
        command("/files")
        snapshot = wait("name with space.txt")
        assert "math.lua" in snapshot, snapshot
        row = next(line for line in snapshot.splitlines() if "name with space.txt" in line)
        assert " U " in row, "no Git marker on a name with a space:\n" + snapshot
        wait("Changed 3")

        # d: the changes since the last commit, removals first.
        keys("d")
        snapshot = wait("Since the last commit")
        assert "1 added, 1 removed" in snapshot, snapshot
        body = snapshot[snapshot.index("Since the last commit"):]
        assert body.index("-   return a - b") < body.index("+   return a - b - 0"), snapshot

        # Unsaved work survives esc, esc, esc.
        keys("e")
        typed("ZZ")
        wait("ZZlocal M = {}")
        keys("Escape")
        wait("open")
        keys("Escape")
        snapshot = wait("keys: prompt")
        assert "math.lua ●" in snapshot, "the unsaved file was closed:\n" + snapshot
        command("/editor " + str(project / "math.lua"))
        wait("ZZlocal M = {}")

        # Copy and paste with no clipboard tool to reach.
        keys("C-Home", "S-End", "C-c")
        wait("Copied to tmux")
        keys("End", "C-v")
        wait("ZZlocal M = {}ZZlocal M = {}")
        assert tmux("show-buffer").strip() == "ZZlocal M = {}"

        # The open files, by keys tmux sends.
        keys("Escape", "Escape")
        wait("keys: prompt")
        command("/editor " + str(project / "notes.md"))
        wait("2 notes.md")
        wait("# Notes")
        keys("M-1")
        wait("# Notes", absent=True)
        wait("ZZlocal M = {}ZZlocal M = {}")
        keys("C-NPage")
        wait("# Notes")

        # With room for both, the tree is on the left and the file on the right.
        tmux("resize-window", "-t", name, "-x", "200", "-y", "36")
        deadline = time.monotonic() + 15
        while True:
            row = next((line for line in screen().splitlines() if "Changed 3" in line and "notes.md" in line), None)
            if row or time.monotonic() > deadline:
                break
            time.sleep(0.1)
        assert row and row.index("Changed 3") < row.index("notes.md"), "the tree is not left of the file:\n" + screen()
        tmux("resize-window", "-t", name, "-x", "120", "-y", "36")
        wait("# Notes")

        # Rename starts before the extension, and says what enter does.
        keys("Escape")
        wait("Files  Search  Changed")
        keys("R")
        snapshot = wait("renames it")
        assert "Rename notes.md" in snapshot, snapshot
        keys("Escape")
        wait("renames it", absent=True)

        # Live refresh: a folder another program makes shows without a key.
        (project / "dest").mkdir()
        wait("▸ dest")

        # Mark two files, copy them, paste into the folder, take it back.
        keys("Home", "Down", "Space", "Space")
        wait("2 marked")
        keys("C-c")
        wait("ctrl+v paste 2 items here")
        keys("Home", "C-v")
        wait("Copied 2 items to dest")
        assert sorted(p.name for p in (project / "dest").iterdir()) == ["math.lua", "name with space.txt"]
        keys("C-z")
        wait("Took back: Copied 2 items to dest")
        assert list((project / "dest").iterdir()) == [], "the copies were not taken back"

        # The menus the keys open.
        keys("S")
        wait("Last changed")
        keys("Escape")
        keys("g")
        wait("Computer")
        keys("Escape")
        wait("Computer", absent=True)

        # A CSV file is a table: a sum, a sort, a cell changed and saved.
        (project / "t.csv").write_text("name,qty\npear,10\napple,3\n")
        # esc closes a file with nothing unsaved, then hands the keys over.
        for _ in range(4):
            if "keys: prompt" in screen():
                break
            keys("Escape")
            time.sleep(0.3)
        wait("keys: prompt")
        command("/editor " + str(project / "t.csv"))
        wait("row 1 · name")
        keys("Right")
        wait("sum 13")
        keys("s")
        snapshot = wait("qty ▲")
        assert snapshot.index("apple") < snapshot.index("pear"), snapshot
        keys("c")
        typed("7")
        keys("Enter", "C-s")
        wait("Saved")
        assert (project / "t.csv").read_text() == "name,qty\napple,7\npear,10\n", (project / "t.csv").read_text()
    finally:
        subprocess.run(["tmux", "-L", server, "kill-server"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

print("files: start folder, dot-folder project, Git markers, changes since the commit, "
      "unsaved work kept, clipboard fallbacks, tab keys, the tree on the left, rename, live refresh, "
      "copy and paste with undo, the sort and places menus and the CSV table passed")
