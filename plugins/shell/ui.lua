-- Local shell commands, never tool calls or model messages.
local limit = 64 * 1024
local running = {}
local active = true

local function display(text)
  return text:gsub("\27%][^\7]*\7", ""):gsub("\27%[[0-?]*[ -/]*[@-~]", "")
    :gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("[%z\1-\8\11-\31\127]", "")
end

local function update(entry, status)
  local text = "!" .. entry.command .. "\n[" .. status .. "]"
  if entry.output ~= "" then text = text .. "\n" .. entry.output end
  if entry.truncated then text = text .. "\n[output truncated at 64 KiB]" end
  bone.chat.update(entry.item, { text = display(text) })
end

local function start(command)
  local session = bone.chat.session() or {}
  local entry = { command = command, chat = session.chat, output = "" }
  entry.item = bone.chat.add("shell", { text = display("!" .. command .. "\n[running]") })
  local function output(chunk)
    if not active or entry.truncated then return end
    local room = limit - #entry.output
    if #chunk > room then
      -- Do not cut a UTF-8 character in half.
      local cut = room
      while cut > 0 and chunk:byte(cut + 1) >= 128 and chunk:byte(cut + 1) < 192 do
        cut = cut - 1
      end
      chunk = chunk:sub(1, cut)
      entry.truncated = true
    end
    entry.output = entry.output .. chunk
    update(entry, "running")
  end
  local ok, job = pcall(bone.job.start, command, {
    name = "shell", cwd = session.cwd, buffer = false,
    on_stdout = output, on_stderr = output,
    on_exit = function(result)
      if not active then return end
      running[entry.item] = nil
      local status = result.state
      if result.state == "exited" then
        status = result.signal and ("signal " .. result.signal) or ("exit " .. tostring(result.code))
      end
      if result.error then status = status .. ": " .. result.error end
      update(entry, status)
    end,
  })
  if not ok then
    update(entry, "failed: " .. tostring(job))
    return
  end
  entry.job = job
  running[entry.item] = entry
end

bone.on("submit", function(ev)
  local text = ev.text or ""
  if text:sub(1, 1) ~= "!" then return end
  -- An explicit escape lets a message beginning with ! reach the model.
  if text:sub(1, 2) == "!!" then return text:sub(2) end
  if ev.images and #ev.images > 0 then
    bone.notify("Shell commands cannot include images; attachments were not sent.", "error")
    return false
  end
  local command = text:sub(2)
  if command:match("^%s*$") then
    bone.notify("Usage: !command (for example !pwd)", "error")
    return false
  end
  -- Always cancel the submit, even if starting the local command fails.
  local ok, err = pcall(start, command)
  if not ok then bone.notify("Shell command failed: " .. tostring(err), "error") end
  return false
end)

bone.cmd.create("shell-cancel", function()
  local chat = (bone.chat.session() or {}).chat
  for _, entry in pairs(running) do
    if entry.chat == chat then entry.job:cancel() end
  end
end, { desc = "cancel running !commands in this chat" })

bone.plugin.on_shutdown(function()
  active = false
  for _, entry in pairs(running) do
    update(entry, "cancelled (plugin unloaded)")
  end
  -- Bone owns these jobs and cancels them without invoking old callbacks.
  running = {}
end)
