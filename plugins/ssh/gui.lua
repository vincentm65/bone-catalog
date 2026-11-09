-- /ssh: open a desktop bone window on another machine's bone, over ssh.
-- With no arguments it opens the SSH window (saved profiles, tests, a form);
-- /ssh <profile> or /ssh [user@]host[:dir] connects at once. The window you
-- typed it in stays as it was and can be closed; the new one lasts until it
-- is closed itself (ssh_window.py does the ssh side). The TUI does not need
-- this: run it over ssh instead.

-- ── In a window ssh_window.py opened ─────────────────────────────────────
-- New chats start in this machine's directory, which is not a directory over
-- there, so each new chat gets its session there first.
local remote = os.getenv("BONE_SSH_HOST")
if remote and remote ~= "" then
  local cwd = os.getenv("BONE_SSH_CWD")
  if cwd == "" then cwd = nil end
  -- `opening`: the session made last, until its chat is shown loaded
  -- (opening it shows the chat first with no session yet).
  local creating, opening = false, nil
  local function ensure(ev)
    if ev and ev.session_id then
      if ev.session_id == opening then opening = nil end
      return
    end
    if creating or opening or bone.api.session() then return end
    creating = true
    bone.request("session/create", { cwd = cwd }, function(info, err)
      creating = false
      if info then
        opening = info.session_id
        bone.api.open_session(info.session_id)
        -- One that never loads must not block new chats for good.
        bone.defer(5000, function()
          if opening == info.session_id then opening = nil end
        end)
      else
        bone.notify("cannot start a chat on " .. remote .. ": " .. tostring(err), "error")
      end
    end)
  end
  bone.on("ready", function() ensure() end)
  bone.on("chat/shown", ensure)
  pcall(bone.gui.window, { title = remote .. " — bone" })
end

-- ── /ssh ─────────────────────────────────────────────────────────────────
local core = require("ssh.core")

local function connect_now(arg)
  local p = core.find(arg)
  if not p then
    -- [user@]host[:dir]; a Windows dir keeps its drive's colon.
    local target, dir = arg:match("^([^:%s]+):(.+)$")
    target = target or arg
    if target:find("%s") then
      return bone.notify("usage: /ssh, /ssh <profile> or /ssh [user@]host[:dir]", "error")
    end
    local user, host = target:match("^(.-)@(.+)$")
    p = { name = target, host = host or target, user = user or "", dir = dir or "" }
  end
  if core.find(p.name) then core.touch(p, { last_used = os.time() }) end
  core.launch(p, function(err)
    if err then
      bone.notify("ssh " .. p.name .. ": " .. err, "error")
    else
      bone.notify("Opening a window on " .. p.name .. "…")
    end
  end)
end

bone.cmd.create("ssh", function(c)
  local arg = core.trim(c.args)
  if arg == "" then return require("ssh.dialog").open() end
  if arg == "new" then return require("ssh.dialog").open({ new = {} }) end
  local edit = arg:match("^edit%s+(.+)$")
  if edit then
    local p = core.find(core.trim(edit))
    if not p then return bone.notify("no profile called " .. edit, "error") end
    return require("ssh.dialog").open({ edit = p })
  end
  connect_now(arg)
end, {
  desc = "open a window on bone on another machine: /ssh (profiles), /ssh <profile>, /ssh host[:dir]",
  complete = function(ctx)
    local args = ctx.args or ""
    if args:find("^edit%s") then
      local out = {}
      for _, p in ipairs(core.profiles()) do out[#out + 1] = { value = "edit " .. p.name, desc = core.target(p) } end
      return out
    end
    if args:find("%s") then return {} end
    local out, seen = {}, {}
    for _, p in ipairs(core.profiles()) do
      seen[p.name] = true
      out[#out + 1] = { value = p.name, desc = "saved · " .. core.target(p) }
    end
    for _, h in ipairs(core.config_hosts()) do
      if not seen[h.name] then out[#out + 1] = { value = h.name, desc = "~/.ssh/config" } end
    end
    out[#out + 1] = { value = "new", desc = "add a connection" }
    return out
  end,
})
