-- The clipboard. The system's own first, through the desktop's tools: wl-copy
-- and wl-paste on Wayland, xclip or xsel on X, pbcopy and pbpaste on a Mac.
-- Where there is none to reach — a tmux window that lost its display, a
-- machine reached over ssh — tmux's own buffer, then the terminal itself
-- (OSC 52). And whatever happens outside, the last text copied is kept here,
-- so copy and paste inside the editor work everywhere.
--
-- A plugin job runs the tools, so nothing waits on them. wl-copy and xclip
-- stay behind to own the clipboard: their output goes nowhere, or the job
-- would wait on them and its timeout would take the clipboard away with them.

local M = {}

--- The last text copied from here: what paste falls back on.
M.held = nil

-- A shell on this machine's own desktop that lost WAYLAND_DISPLAY (a tmux
-- server started before the session, a window opened after the variable was
-- dropped) still has the compositor's socket beside it: find it. Not over
-- ssh, where the desktop it would reach is not the one you sit at.
local FIND = 'if [ -z "$WAYLAND_DISPLAY" ] && [ -z "$DISPLAY" ] && [ -z "$SSH_CONNECTION" ] && [ -z "$SSH_TTY" ]; then '
  .. 'for s in "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"/wayland-*; do '
  .. 'n=${s##*/wayland-}; case "$n" in ""|*[!0-9]*) continue;; esac; '
  .. 'if [ -S "$s" ]; then WAYLAND_DISPLAY="wayland-$n"; export WAYLAND_DISPLAY; break; fi; '
  .. 'done; fi; '

-- The tools that stay behind start in a session of their own (setsid), out
-- of the job's process group, which bone may stop when the job ends. The
-- word printed says where the text went.
local COPY = FIND .. 'd=""; command -v setsid >/dev/null 2>&1 && d="setsid -f"; '
  .. 'if [ -n "$WAYLAND_DISPLAY" ] && command -v wl-copy >/dev/null 2>&1; then $d wl-copy >/dev/null 2>&1 && echo system; '
  .. 'elif [ -n "$DISPLAY" ] && command -v xclip >/dev/null 2>&1; then $d xclip -selection clipboard -in >/dev/null 2>&1 && echo system; '
  .. 'elif [ -n "$DISPLAY" ] && command -v xsel >/dev/null 2>&1; then $d xsel --clipboard --input >/dev/null 2>&1 && echo system; '
  .. 'elif command -v pbcopy >/dev/null 2>&1; then pbcopy && echo system; '
  .. 'elif [ -n "$TMUX" ] && command -v tmux >/dev/null 2>&1; then '
  .. 't=$(mktemp) && cat > "$t" && { tmux load-buffer -w "$t" 2>/dev/null || tmux load-buffer "$t"; }; r=$?; rm -f "$t"; '
  .. '[ $r -eq 0 ] && echo tmux || exit 3; '
  .. 'elif [ -w /dev/tty ] && command -v base64 >/dev/null 2>&1; then '
  .. 'printf "\\033]52;c;%s\\a" "$(base64 | tr -d "\\n")" > /dev/tty && echo terminal; '
  .. 'else echo "no clipboard tool (wl-copy, xclip, xsel)" >&2; exit 3; fi'

local PASTE = FIND
  .. 'if [ -n "$WAYLAND_DISPLAY" ] && command -v wl-paste >/dev/null 2>&1; then exec wl-paste --no-newline --type text; '
  .. 'elif [ -n "$DISPLAY" ] && command -v xclip >/dev/null 2>&1; then exec xclip -selection clipboard -out; '
  .. 'elif [ -n "$DISPLAY" ] && command -v xsel >/dev/null 2>&1; then exec xsel --clipboard --output; '
  .. 'elif command -v pbpaste >/dev/null 2>&1; then exec pbpaste; '
  .. 'elif [ -n "$TMUX" ] && command -v tmux >/dev/null 2>&1; then exec tmux save-buffer -; '
  .. 'else echo "no clipboard tool (wl-paste, xclip, xsel)" >&2; exit 3; fi'

--- Put `value` on the clipboard; `done(ok, why, where)` after: `where` is
--- "system", "tmux" or "terminal" when it left this program, and when it did
--- not (`ok` false) the text is still held here for a paste.
function M.copy(value, done)
  value = tostring(value or "")
  M.held = value
  bone.job.start(COPY, { name = "files: copy", stdin = value, timeout = 4000, buffer = true,
    on_exit = function(r)
      local where = r and r.code == 0 and (r.stdout or ""):match("%a+") or nil
      if done then done(where ~= nil, r and r.stderr, where) end
    end })
end

--- What text the clipboard holds: `done(text)`, or `done(nil, why)`. With no
--- clipboard to ask (or an empty one), what was last copied here.
function M.paste(done)
  bone.job.start(PASTE, { name = "files: paste", timeout = 4000, buffer = true,
    on_exit = function(r)
      if r and r.code == 0 and (r.stdout or "") ~= "" then return done(r.stdout) end
      if M.held and M.held ~= "" then return done(M.held) end
      if r and r.code == 0 then return done("") end
      done(nil, r and r.stderr)
    end })
end

return M
