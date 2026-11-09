#!/usr/bin/env python3
"""Open a bone window on another machine's core, over ssh.

    ssh_window.py --bone /path/to/bone [--cwd DIR] [--ssh-opts "-p 2222"] HOST

Unix host: an ssh tunnel from a local socket to bone's socket there (the core a
TUI there uses; one is started for as long as the window is open if none runs),
then `bone --gui --connect <local socket>`.

Windows host: bone there listens on a named pipe, which ssh cannot forward, so
each connection to a local socket runs `ssh HOST bone --headless` and relays
it: a core of its own on that machine (same config and sessions, no live sync
with a bone already running there).

On a Windows desktop the window connects to a local named pipe instead, and
each connection runs ssh: on a Unix host a short script that joins (or starts)
the core at its socket through python3 there, else `bone --headless`.

The window gets BONE_SSH_HOST and BONE_SSH_CWD, which the plugin's gui.lua uses
to start new chats in a directory that exists over there. The tunnel ends when
the window closes. Runs detached from the window that started it.
"""

import argparse
import json
import os
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

UNIX_PROBE = r"""
PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
if [ -n "$XDG_RUNTIME_DIR" ]; then s="$XDG_RUNTIME_DIR/bone3/bone.sock"
else s="${TMPDIR:-/tmp}"; s="${s%/}/bone3-${USER:-user}/bone.sock"; fi
b=$(command -v bone3 || command -v bone)
printf 'unix\n%s\n%s\n%s\n' "$s" "$HOME" "$b"
"""

# Serve the core at $s for as long as ssh's stdin stays open, unless another
# bone already does; say READY once the socket is there.
UNIX_KEEP = r"""
"$b" --headless --listen "$s" 2>/dev/null &
pid=$!
i=0
while [ $i -lt 150 ]; do
  kill -0 $pid 2>/dev/null || { pid=; break; }
  [ -S "$s" ] && break
  sleep 0.1; i=$((i+1))
done
[ -S "$s" ] || { echo "no bone is serving $s" >&2; exit 1; }
echo READY
cat >/dev/null
[ -n "$pid" ] && kill $pid 2>/dev/null
exit 0
"""

WINDOWS_PATH = '$env:Path = "$env:USERPROFILE\\.local\\bin;$env:USERPROFILE\\.cargo\\bin;$env:APPDATA\\npm;$env:Path"; '
WINDOWS_FIND = "$c = Get-Command bone3.exe, bone.exe, bone.cmd -ErrorAction SilentlyContinue | Select-Object -First 1; "
WINDOWS_PROBE = (WINDOWS_PATH + WINDOWS_FIND
                 + "Write-Output windows; Write-Output $env:USERPROFILE; Write-Output $c.Source")

# An admin's key login gets only the system PATH: add the usual bin folders
# and npm's (bone-agent). bone.cmd, not npm's bone.ps1, which PowerShell's
# script policy may refuse.
WINDOWS_CORE = (
    WINDOWS_PATH + WINDOWS_FIND
    + "if (-not $c) { [Console]::Error.WriteLine('no bone on this machine'); exit 1 }; "
    "& $c.Source --headless"
)


# For a Windows desktop and a Unix host: join the core at $s (starting one
# for this connection if none serves it), relaying stdin/stdout with python3.
UNIX_JOIN = r"""
alive() { python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).connect(sys.argv[1])' "$s" 2>/dev/null; }
command -v python3 >/dev/null || exec "$b" --headless
pid=
if ! alive; then
  "$b" --headless --listen "$s" 2>/dev/null &
  pid=$!
  i=0; while [ $i -lt 150 ] && ! alive; do sleep 0.1; i=$((i+1)); done
fi
python3 -c '
import os, socket, sys, threading
c = socket.socket(socket.AF_UNIX); c.connect(sys.argv[1])
def up():
    while (d := os.read(0, 65536)):
        c.sendall(d)
    c.shutdown(socket.SHUT_WR)
threading.Thread(target=up, daemon=True).start()
while (d := c.recv(65536)):
    os.write(1, d)
' "$s"
[ -n "$pid" ] && kill $pid 2>/dev/null
exit 0
"""

WINDOWS = os.name == "nt"
# On Windows, no console window for ssh or for bone's own.
NO_WINDOW = {"creationflags": 0x08000000} if WINDOWS else {}


def log(msg):
    print(f"ssh_window: {msg}", file=sys.stderr, flush=True)


def ssh_base(opts):
    return ["ssh", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15", *opts]


def sh(script):
    """A remote command that runs `script` with sh, whatever the login shell."""
    return "sh -c " + shlex.quote(script)


def ask(cmd, first, count, timeout=30):
    """Run `cmd`; (code, lines, stderr). Done as soon as its output starts with
    `first` and has `count` lines: Windows' ssh.exe can stay open after the
    remote command has finished, so its exit is not waited for then."""
    proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=True, **NO_WINDOW)
    lines, err = [], []
    threading.Thread(target=lambda: err.append(proc.stderr.read()), daemon=True).start()

    def read():
        for line in proc.stdout:
            line = line.strip()
            if line or lines:
                lines.append(line)
            if lines[:1] == [first] and len(lines) >= count:
                return

    t = threading.Thread(target=read, daemon=True)
    t.start()
    t.join(timeout)
    if lines[:1] == [first] and len(lines) >= count:
        proc.kill()
        return 0, lines, ""
    if t.is_alive():
        proc.kill()
        raise subprocess.TimeoutExpired(cmd, timeout)
    code = proc.wait(5)
    time.sleep(0.1)
    return code, lines, "".join(err)


def probe(host, opts):
    """("unix", socket, home, bone) or ("windows", None, home, bone)."""
    code, lines, err = ask(ssh_base(opts) + ["-n", host, sh(UNIX_PROBE)], "unix", 4)
    if code == 0 and lines[:1] == ["unix"]:
        _, sock, home, bone = (lines + ["", "", "", ""])[:4]
        if not bone:
            sys.exit(f"no bone3 or bone on {host}'s PATH, ~/.local/bin or ~/.cargo/bin")
        return "unix", sock, home, bone
    if code == 255:  # ssh itself failed: no route, no key
        sys.exit(err.strip() or f"cannot ssh to {host}")
    wcode, wlines, werr = ask(ssh_base(opts) + ["-n", host, WINDOWS_PROBE], "windows", 3)
    if wcode == 0 and wlines[:1] == ["windows"]:
        if len(wlines) < 3 or not wlines[2]:
            sys.exit(f"no bone3 or bone on {host} (PATH, .local\\bin, .cargo\\bin or npm)")
        return "windows", None, wlines[1], wlines[2]
    sys.exit((err or werr).strip() or f"cannot tell what {host} runs")


def wait_ready(proc, timeout):
    """Wait for READY on the tunnel's stdout."""
    got = []

    def read():
        for line in proc.stdout:
            if line.strip() == b"READY":
                got.append(True)
                return

    t = threading.Thread(target=read, daemon=True)
    t.start()
    t.join(timeout)
    return bool(got)


def unix_tunnel(host, opts, local, sock, bone):
    script = f"s={shlex.quote(sock)}; b={shlex.quote(bone)}\n" + UNIX_KEEP
    cmd = ssh_base(opts) + [
        "-o", "ExitOnForwardFailure=yes",
        "-o", "StreamLocalBindUnlink=yes",
        "-L", f"{local}:{sock}",
        host, sh(script),
    ]
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    if not wait_ready(proc, 45):
        proc.kill()
        sys.exit(f"the tunnel to {host} did not come up")
    for _ in range(50):
        if os.path.exists(local):
            break
        time.sleep(0.1)
    return proc


def pump(src, dst, close):
    try:
        while True:
            data = src(65536)
            if not data:
                break
            dst(data)
    except OSError:
        pass
    finally:
        close()


def start_remote(host, opts, remote_cmd):
    return subprocess.Popen(
        ssh_base(opts) + [host, remote_cmd],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, **NO_WINDOW,
    )


def socket_relay(host, opts, local, remote_cmd):
    """Serve the Unix socket `local`: each connection runs `remote_cmd` over ssh."""
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(local)
    server.listen(4)
    procs = []

    def serve(conn):
        proc = start_remote(host, opts, remote_cmd)
        procs.append(proc)

        def to_remote(data):
            proc.stdin.write(data)
            proc.stdin.flush()

        def end():
            for f in (lambda: conn.shutdown(socket.SHUT_RDWR), proc.stdin.close):
                try:
                    f()
                except OSError:
                    pass

        threading.Thread(target=pump, args=(conn.recv, to_remote, end), daemon=True).start()
        threading.Thread(target=pump, args=(proc.stdout.read1, conn.sendall, end), daemon=True).start()

    def accept():
        while True:
            try:
                conn, _ = server.accept()
            except OSError:
                return
            serve(conn)

    threading.Thread(target=accept, daemon=True).start()

    def stop():
        server.close()
        for p in procs:
            p.kill()

    return stop


def pipe_relay(host, opts, pipe, remote_cmd):
    """Windows: serve the named pipe `pipe` the same way."""
    from multiprocessing.connection import Listener

    listener = Listener(pipe, family="AF_PIPE")
    procs = []

    def serve(conn):
        proc = start_remote(host, opts, remote_cmd)
        procs.append(proc)

        def recv(_n):
            try:
                return conn.recv_bytes()
            except (EOFError, OSError):
                return b""

        def to_remote(data):
            proc.stdin.write(data)
            proc.stdin.flush()

        def end():
            for f in (conn.close, proc.stdin.close):
                try:
                    f()
                except OSError:
                    pass

        threading.Thread(target=pump, args=(recv, to_remote, end), daemon=True).start()
        threading.Thread(target=pump, args=(proc.stdout.read1, conn.send_bytes, end), daemon=True).start()

    def accept():
        while True:
            try:
                conn = listener.accept()
            except OSError:
                return
            serve(conn)

    threading.Thread(target=accept, daemon=True).start()

    def stop():
        try:
            listener.close()
        except OSError:
            pass
        for p in procs:
            p.kill()

    return stop


def run(a=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("host")
    ap.add_argument("--bone", help="this machine's bone (with the GUI)")
    ap.add_argument("--cwd", help="where new chats start over there")
    ap.add_argument("--name", help="what the window calls the host (default: HOST)")
    ap.add_argument("--user", help="the login name there")
    ap.add_argument("--port", help="ssh's port there")
    ap.add_argument("--identity", help="the private key file to log in with")
    ap.add_argument("--ssh-opts", default="", help="more ssh options")
    ap.add_argument("--status", help="write how starting went here: JSON {ok} or {ok, error}")
    ap.add_argument("--probe", action="store_true",
                    help="only check the host: print what it runs, as JSON")
    a = ap.parse_args()
    global STATUS
    STATUS = a.status
    opts = []
    if a.user:
        opts += ["-l", a.user]
    if a.port:
        opts += ["-p", a.port]
    if a.identity:
        opts += ["-i", os.path.expanduser(a.identity), "-o", "IdentitiesOnly=yes"]
    opts += shlex.split(a.ssh_opts)

    try:
        kind, sock, home, bone = probe(a.host, opts)
    except subprocess.TimeoutExpired:
        if a.probe:
            print(json.dumps({"ok": False, "error": f"{a.host} did not answer"}))
            return
        sys.exit(f"{a.host} did not answer")
    except SystemExit as e:
        if a.probe:
            print(json.dumps({"ok": False, "error": str(e.code)}))
            return
        raise
    if a.probe:
        print(json.dumps({"ok": True, "kind": kind, "home": home, "bone": bone}))
        return
    if not a.bone:
        sys.exit("--bone is needed to open a window")
    if kind == "windows":
        remote_cmd = WINDOWS_CORE
    else:
        remote_cmd = sh(f"s={shlex.quote(sock)}; b={shlex.quote(bone)}\n" + UNIX_JOIN)
    tmp = tempfile.mkdtemp(prefix="bone-ssh-")
    try:
        if WINDOWS:
            local = "\\\\.\\pipe\\" + os.path.basename(tmp)
            stop = pipe_relay(a.host, opts, local, remote_cmd)
        elif kind == "unix":
            local = os.path.join(tmp, "bone.sock")
            tunnel = unix_tunnel(a.host, opts, local, sock, bone)

            def stop():
                # Closing its stdin ends the remote side, then ssh.
                try:
                    tunnel.stdin.close()
                    tunnel.wait(5)
                except (OSError, subprocess.TimeoutExpired):
                    tunnel.kill()
        else:
            local = os.path.join(tmp, "bone.sock")
            stop = socket_relay(a.host, opts, local, remote_cmd)
        env = dict(os.environ, BONE_SSH_HOST=a.name or a.host)
        cwd = a.cwd or home
        if cwd:
            env["BONE_SSH_CWD"] = cwd
        log(f"{a.host} ({kind}) on {local}")
        status(True)
        try:
            subprocess.run([a.bone, "--gui", "--connect", local], env=env,
                           cwd=os.path.expanduser("~"), **NO_WINDOW)
        finally:
            stop()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


STATUS = None


def status(ok, error=None):
    """Tell the window that asked how starting went (--status)."""
    if not STATUS:
        return
    try:
        with open(STATUS + ".tmp", "w", encoding="utf-8") as f:
            json.dump({"ok": ok, "error": error} if error else {"ok": ok}, f)
        os.replace(STATUS + ".tmp", STATUS)
    except OSError:
        pass


def main():
    try:
        run()
    except SystemExit as e:
        if e.code not in (None, 0):
            status(False, str(e.code))
        raise
    except Exception as e:  # say why, not just that it died
        status(False, f"{type(e).__name__}: {e}")
        raise


if __name__ == "__main__":
    main()
