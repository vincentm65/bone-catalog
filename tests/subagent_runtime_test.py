#!/usr/bin/env python3
"""Exercise saved subagents through real headless Bone 3 and mock OpenAI HTTP.

Run: BONE_BIN=/path/to/bone3/target/debug/bone python3 tests/subagent_runtime_test.py
Only the subagent plugin is installed; no external network or model is used.
"""
from __future__ import annotations

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import tempfile
import threading
import time
import traceback

ROOT = Path(__file__).resolve().parents[1]
BINARY = os.environ.get("BONE_BIN") or shutil.which("bone3") or shutil.which("bone")
TIMEOUT = 20
NAMED_SYSTEM = "SAVED REVIEWER INSTRUCTIONS: inspect carefully."
DEFAULT_SYSTEM = "DEFAULT CHILD INSTRUCTIONS: be brief."


def tool_call(call_id, prompt, name=None):
    args = {"task": prompt, "prompt": prompt}
    if name is not None:
        args["name"] = name
    return {"index": 0, "id": call_id, "type": "function", "function": {
        "name": "subagent", "arguments": json.dumps(args),
    }}


class ModelServer:
    def __init__(self):
        self.seen = []
        self.errors = []
        self.holding = threading.Event()
        self.release = threading.Event()
        mock = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                try:
                    request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                    mock.seen.append((self.path, request))
                    delta = mock.reply(self.path, request)
                    body = ("data: " + json.dumps({"choices": [{"index": 0, "delta": delta}]})
                            + "\n\ndata: [DONE]\n\n").encode()
                    self.send_response(200)
                    self.send_header("Content-Type", "text/event-stream")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError):
                    # The deliberately stalled child request is cancelled.
                    pass
                except Exception:
                    mock.errors.append(traceback.format_exc())
                    body = mock.errors[-1].encode()
                    self.send_response(400)  # Do not trigger provider retry/backoff.
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)

        self.http = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.http.daemon_threads = True
        self.thread = threading.Thread(target=self.http.serve_forever, daemon=True)
        self.thread.start()
        self.url = f"http://127.0.0.1:{self.http.server_port}"

    def reply(self, path, request):
        assert request["stream"] is True
        tools = {t["function"]["name"]: t["function"] for t in request.get("tools", [])}
        messages = request["messages"]
        prompt = next(m["content"] for m in messages if m["role"] == "user")
        systems = "\n".join(m["content"] for m in messages if m["role"] == "system")
        results = [m for m in messages if m["role"] == "tool"]
        if path == "/parent/chat/completions":
            assert request["model"] == "parent-model", request
            assert NAMED_SYSTEM not in systems and DEFAULT_SYSTEM not in systems
            assert {"read_file", "write_file", "shell", "subagent"} <= tools.keys()
            delegate = tools["subagent"]
            assert "reviewer: Saved review agent" in delegate["description"]
            assert "name" in delegate["parameters"]["properties"]
            calls = {
                "named case": ("review", "named child", "reviewer", "named child answer"),
                "default case": ("default", "default child", None, "default child answer"),
                "nested case": ("nested", "nested child", "delegator", "nested child answer"),
                "hold case": ("hold", "hold child", None, None),
                "busy case": ("busy", "default child", None, "maximum concurrent sub-agents reached"),
            }
            call_id, child_prompt, name, answer = calls[prompt]
            if not results:
                return {"tool_calls": [tool_call(call_id, child_prompt, name)]}
            assert len(results) == 1 and results[0]["tool_call_id"] == call_id, results
            assert answer is not None and answer in results[0]["content"], results
            return {"content": "parent final: " + prompt}

        if prompt == "named child":
            assert path == "/named/chat/completions", path
            assert request["model"] == "saved-review-model", request
            assert systems.startswith(NAMED_SYSTEM + "\n\n"), systems
            assert DEFAULT_SYSTEM not in systems and "LEGACY" not in systems
            assert set(tools) == {"read_file"}, tools
            if not results:
                # A hostile model calling an unadvertised tool must also be denied.
                return {"tool_calls": [{"index": 0, "id": "forbidden", "type": "function",
                        "function": {"name": "write_file", "arguments": json.dumps({
                            "path": "must-not-exist.txt", "content": "not allowed",
                        })}}]}
            assert len(results) == 1
            assert "tool write_file is not allowed for this sub-agent" in results[0]["content"], results
            return {"content": "named child answer"}

        if prompt == "nested child":
            assert path == "/named/chat/completions", path
            assert request["model"] == "saved-nesting-model", request
            assert systems.startswith("NESTED INSTRUCTIONS\n\n"), systems
            assert set(tools) == {"subagent"}, tools
            if not results:
                return {"tool_calls": [tool_call("too-many", "never started")]}
            assert len(results) == 1
            assert "maximum concurrent sub-agents reached" in results[0]["content"], results
            return {"content": "nested child answer"}

        assert prompt in {"default child", "hold child"}, prompt
        assert path == "/default/chat/completions", path
        assert request["model"] == "default-override-model", request
        assert systems.startswith(DEFAULT_SYSTEM + "\n\n"), systems
        assert NAMED_SYSTEM not in systems
        assert set(tools) == {"read_file"}, tools
        assert not results
        if prompt == "hold child":
            self.holding.set()
            assert self.release.wait(TIMEOUT), "stalled request was not cleaned up"
        return {"content": "default child answer"}

    def close(self):
        self.release.set()
        self.http.shutdown()
        self.http.server_close()
        self.thread.join(timeout=3)


class Bone:
    def __init__(self, config, cwd):
        # Prevent inherited model selection/network settings contaminating the test.
        env = {k: v for k, v in os.environ.items() if not k.startswith("BONE_")}
        env["BONE_CONFIG_DIR"] = str(config)
        self.process = subprocess.Popen(
            [BINARY, "--headless"], cwd=cwd, env=env, stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        self.incoming = queue.Queue()
        self.events = []
        self.responses = {}
        self.stderr = []
        self.serial = 0

        def read():
            try:
                for line in self.process.stdout:
                    self.incoming.put(json.loads(line))
            except Exception as error:
                self.incoming.put(error)
            finally:
                self.incoming.put(None)

        def read_stderr():
            for line in self.process.stderr:
                self.stderr.append(line)

        self.readers = [threading.Thread(target=read, daemon=True),
                        threading.Thread(target=read_stderr, daemon=True)]
        for thread in self.readers:
            thread.start()

    def receive(self, deadline):
        try:
            message = self.incoming.get(timeout=max(0.001, deadline - time.monotonic()))
        except queue.Empty:
            raise AssertionError("RPC timed out\n" + "".join(self.stderr)) from None
        assert message is not None, "Bone exited\n" + "".join(self.stderr)
        assert isinstance(message, dict), message
        if "id" in message:
            self.responses[message["id"]] = message
        else:
            self.events.append(message)

    def call(self, method, params=None):
        self.serial += 1
        serial = self.serial
        self.process.stdin.write(json.dumps({
            "jsonrpc": "2.0", "id": serial, "method": method, "params": params or {},
        }) + "\n")
        self.process.stdin.flush()
        deadline = time.monotonic() + TIMEOUT
        while serial not in self.responses:
            self.receive(deadline)
        message = self.responses.pop(serial)
        assert "error" not in message, message
        return message["result"]

    def wait_event(self, method, predicate):
        deadline = time.monotonic() + TIMEOUT
        while True:
            for event in self.events:
                if event.get("method") == method and predicate(event["params"]):
                    return event["params"]
            self.receive(deadline)

    def start(self, session, text):
        return self.call("turn/start", {"session_id": session, "text": text})["turn_id"]

    def finish(self, session, turn, status="completed"):
        event = self.wait_event("turn/finished", lambda p:
                                p["session_id"] == session and p["turn_id"] == turn)
        assert event["outcome"]["status"] == status, event

    def close(self):
        # Never wait for an RPC response during failure cleanup or read stderr to EOF.
        if self.process.poll() is None:
            try:
                self.process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 999999,
                                                     "method": "shutdown", "params": {}}) + "\n")
                self.process.stdin.flush()
                self.process.wait(timeout=3)
            except (BrokenPipeError, OSError, subprocess.TimeoutExpired):
                self.process.kill()
                self.process.wait(timeout=3)
        for thread in self.readers:
            thread.join(timeout=2)
        for pipe in (self.process.stdin, self.process.stdout, self.process.stderr):
            pipe.close()


def main():
    if not BINARY:
        raise SystemExit("set BONE_BIN to a Bone 3 executable")
    mock = ModelServer()
    try:
        with tempfile.TemporaryDirectory(prefix="bone-subagent-test-") as raw:
            config = Path(raw) / "config"
            plugin = config / "plugins/subagent"
            plugin.mkdir(parents=True)
            for name in ("core.lua", "tui.lua", "manifest.json"):
                shutil.copy2(ROOT / "plugins/subagent" / name, plugin / name)
            cwd = Path(raw) / "work"
            cwd.mkdir()
            (config / "core.lua").write_text(f'''
bone.config.providers.parent = {{ base_url = "{mock.url}/parent", model = "parent-model" }}
bone.config.providers.named = {{ base_url = "{mock.url}/named", model = "configured-named-model" }}
bone.config.providers.fallback = {{ base_url = "{mock.url}/default", model = "configured-default-model" }}
bone.config.provider = "parent"
bone.config.subagents = {{ reviewer = {{ system = "LEGACY", provider = "parent", model = "legacy-model" }} }}
''')
            saved = {"subagent": {
                "max_depth": 2, "max_concurrent": 1,
                "provider": "fallback", "model": "default-override-model",
                "system": DEFAULT_SYSTEM, "tools": "read_file",
                "agents": {
                    "reviewer": {"description": "Saved review agent", "system": NAMED_SYSTEM,
                                 "provider": "named", "model": "saved-review-model", "tools": ["read_file"]},
                    "delegator": {"system": "NESTED INSTRUCTIONS", "provider": "named",
                                  "model": "saved-nesting-model", "tools": ["subagent"]},
                },
            }}
            (config / "settings.json").write_text(json.dumps(saved))
            bone = Bone(config, cwd)
            try:
                bone.call("initialize", {"protocol_version": 0, "client_name": "subagent-runtime-test"})
                assert bone.call("settings/get")["subagent"] == saved["subagent"]
                roster = bone.call("lua/call", {"name": "subagent/list", "args": {}})
                assert next(a for a in roster if a["name"] == "reviewer")["model"] == "saved-review-model"
                parent = bone.call("session/create")["session_id"]

                def run_case(session, label):
                    turn = bone.start(session, label)
                    bone.finish(session, turn)
                    messages = bone.call("session/messages", {"session_id": session})["messages"]
                    assert messages[-1]["content"] == "parent final: " + label, messages
                    assert not mock.errors, "\n".join(mock.errors)

                run_case(parent, "named case")
                assert not (cwd / "must-not-exist.txt").exists()
                named = next(s for s in bone.call("session/list") if s.get("owner", {}).get("name") == "reviewer")
                assert named["owner"]["session_id"] == parent and named["owner"]["call_id"] == "review"
                denied = bone.wait_event("tool/finished", lambda p:
                                        p["session_id"] == named["session_id"] and p["call_id"] == "forbidden")
                assert denied["is_error"] is True, denied

                # New root sessions avoid relying on model-side conversation counters.
                run_case(bone.call("session/create")["session_id"], "default case")
                run_case(bone.call("session/create")["session_id"], "nested case")
                nested = bone.wait_event("tool/finished", lambda p: p["call_id"] == "too-many")
                assert nested["is_error"] is True, nested
                assert not any(s.get("title") == "never started" for s in bone.call("session/list"))

                # A live child occupies the global slot even for an unrelated root.
                held_parent = bone.call("session/create")["session_id"]
                held_turn = bone.start(held_parent, "hold case")
                assert mock.holding.wait(TIMEOUT), "child never reached mock server"
                held_child = next(s for s in bone.call("session/list")
                                  if s.get("owner", {}).get("session_id") == held_parent)
                child_start = bone.wait_event("turn/started", lambda p: p["session_id"] == held_child["session_id"])
                run_case(bone.call("session/create")["session_id"], "busy case")
                busy = bone.wait_event("tool/finished", lambda p: p["call_id"] == "busy")
                assert busy["is_error"] is True, busy
                bone.call("turn/cancel", {"session_id": held_parent})
                bone.finish(held_parent, held_turn, "cancelled")
                bone.finish(held_child["session_id"], child_start["turn_id"], "cancelled")
                mock.release.set()
                assert bone.call("session/active") == []
                # Child turn_end cleanup must free the slot for subsequent delegation.
                run_case(bone.call("session/create")["session_id"], "default case")
                assert not mock.errors, "\n".join(mock.errors)
            finally:
                mock.release.set()
                bone.close()
    finally:
        mock.close()
    print("subagent: saved agents, provider/model isolation, tool restrictions, global cap and cancellation passed")


if __name__ == "__main__":
    main()
