#!/usr/bin/env python3
"""Isolated live TUI test; requires tmux. Run with BONE_BIN=/path/to/bone."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import os
import shlex
import shutil
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
binary = os.environ.get("BONE_BIN") or shutil.which("bone")
if not binary:
    raise SystemExit("set BONE_BIN to a Bone executable")
name = "bone-shell-test-" + str(os.getpid())
requests = []


class Model(BaseHTTPRequestHandler):
    def do_POST(self):
        requests.append(self.path)
        self.send_error(500, "No model calls allowed")

    def log_message(self, *args):
        pass


def tmux(*args):
    return subprocess.check_output(["tmux", *args], text=True)


def screen():
    return tmux("capture-pane", "-p", "-N", "-t", name + ":0.0")


def wait(text):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        snapshot = screen()
        if text in snapshot:
            return snapshot
        time.sleep(0.1)
    raise AssertionError("waiting for " + repr(text) + "\n" + screen())


def command(text):
    tmux("send-keys", "-t", name, "-l", text)
    tmux("send-keys", "-t", name, "Enter")


server = ThreadingHTTPServer(("127.0.0.1", 0), Model)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix="bone-shell-tmux-") as raw:
        base = Path(raw)
        config, project = base / "config", base / "project space"
        project.mkdir()
        shutil.copytree(ROOT / "plugins/shell", config / "plugins/shell")
        (config / "core.lua").write_text(
            f'bone.config.providers.test = {{ base_url = "http://127.0.0.1:{server.server_port}/v1", model = "local" }}\n'
            'bone.config.provider = "test"\n'
        )
        (config / "settings.json").write_text(json.dumps({"setup": {"skipped": True}, "update": {"check": False}}))
        launch = shlex.join(["env", "BONE_CONFIG_DIR=" + str(config), binary])
        try:
            tmux("new-session", "-d", "-s", name, "-x", "120", "-y", "40", "-c", str(project), launch)
            wait("Message bone")
            command("!pwd")
            wait(str(project))
            wait("[exit 0]")
            command("!printf 'SHELL_OUT\\n'; printf 'SHELL_ERR\\n' >&2; exit 7")
            snapshot = wait("[exit 7]")
            assert "SHELL_OUT" in snapshot and "SHELL_ERR" in snapshot, snapshot
            command("!printf 'STREAM_READY\\n'; sleep 30")
            wait("STREAM_READY")
            command("/shell-cancel")
            wait("[cancelled]")
            command("!bone_shell_nonexistent_program")
            wait("[exit 127]")
            command("!")
            wait("Usage: !command")
            command("!sleep 30")
            wait("!sleep 30")
            command("/plugins unload shell")
            wait("cancelled (plugin unloaded)")
            command("/plugins load shell")
            wait("shell: tui loaded")
            command("!printf RELOADED_OK")
            wait("RELOADED_OK")
            command("/help shell")
            wait("Run a shell command directly")
            time.sleep(0.3)
            assert not requests, requests
            assert not list((config / "sessions").rglob("*.json")), "shell created a saved session"
            print("shell live TUI passed: cwd/stdout/stderr/status/stream/cancel/unload/reload/help; zero model calls")
        finally:
            subprocess.run(["tmux", "kill-session", "-t", name], capture_output=True)
finally:
    server.shutdown()
    server.server_close()
