-- The system clipboard, through the desktop's own tools: wl-copy and wl-paste
-- on Wayland, xclip or xsel on X, pbcopy and pbpaste on a Mac. A plugin job
-- runs them, so nothing waits on them. wl-copy and xclip stay behind to own
-- the clipboard: their output goes nowhere, or the job would wait on them
-- and its timeout would take the clipboard away with them.

local M = {}

-- The tools that stay behind start in a session of their own (setsid), out
-- of the job's process group, which bone may stop when the job ends.
local COPY = 'd=""; command -v setsid >/dev/null 2>&1 && d="setsid -f"; '
  .. 'if [ -n "$WAYLAND_DISPLAY" ] && command -v wl-copy >/dev/null 2>&1; then $d wl-copy >/dev/null 2>&1; '
  .. 'elif command -v xclip >/dev/null 2>&1; then $d xclip -selection clipboard -in >/dev/null 2>&1; '
  .. 'elif command -v xsel >/dev/null 2>&1; then $d xsel --clipboard --input >/dev/null 2>&1; '
  .. 'elif command -v pbcopy >/dev/null 2>&1; then exec pbcopy; '
  .. 'else echo "no clipboard tool (wl-copy, xclip, xsel)" >&2; exit 3; fi'

local PASTE = 'if [ -n "$WAYLAND_DISPLAY" ] && command -v wl-paste >/dev/null 2>&1; then exec wl-paste --no-newline --type text; '
  .. 'elif command -v xclip >/dev/null 2>&1; then exec xclip -selection clipboard -out; '
  .. 'elif command -v xsel >/dev/null 2>&1; then exec xsel --clipboard --output; '
  .. 'elif command -v pbpaste >/dev/null 2>&1; then exec pbpaste; '
  .. 'else echo "no clipboard tool (wl-paste, xclip, xsel)" >&2; exit 3; fi'

--- Put `value` on the clipboard; `done(ok, why)` after.
function M.copy(value, done)
  bone.job.start(COPY, { name = "files: copy", stdin = tostring(value or ""), timeout = 4000, buffer = true,
    on_exit = function(r)
      if done then done(r and r.code == 0, r and r.stderr) end
    end })
end

--- What text the clipboard holds: `done(text)`, or `done(nil, why)`.
function M.paste(done)
  bone.job.start(PASTE, { name = "files: paste", timeout = 4000, buffer = true,
    on_exit = function(r)
      if r and r.code == 0 then done(r.stdout or "") else done(nil, r and r.stderr) end
    end })
end

return M
