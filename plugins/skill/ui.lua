-- skills, TUI and GUI side:
--   /skill               pick a skill (typing filters); enter writes "Use the
--                        NAME skill: " into the prompt for you to finish
--   /skill name [task]   the same without the picker (an unknown name opens it)
--   /skills              the picker too
-- and a skill call in the chat is drawn with the skill's name, in a summary
-- line too ("Loaded the money skill, read 2 files").
local names = {}
local where = "~/.bone/skills" -- where new skills go: the first folder
local fetched = 0

local ROW = 80 -- the most a row takes: one line in the GUI's dialog too
local GUI = bone.side == "gui"

local function tilde(path)
  local h = os.getenv("HOME")
  if h and h ~= "" and path:sub(1, #h + 1) == h .. "/" then
    return "~" .. path:sub(#h + 1)
  end
  return path
end

local function fetch(then_)
  fetched = os.time()
  bone.rpc.call("skills.list", {}, function(r, err)
    if err then
      return bone.notify("skills: " .. tostring(err), "error")
    end
    local list = r.skills or {}
    names = {}
    for _, s in ipairs(list) do
      names[#names + 1] = { value = s.name, desc = s.description }
    end
    if (r.dirs or {})[1] then
      where = tilde(r.dirs[1])
    end
    if then_ then
      then_(list)
    end
  end)
end

local function known(name)
  for _, n in ipairs(names) do
    if n.value == name then
      return true
    end
  end
  return false
end

local function use(name, task)
  bone.prompt.set("Use the " .. name .. " skill" .. ((task or "") ~= "" and (": " .. task) or "."))
end

-- `s` in at most `n` columns, cut at a word.
local function clip(s, n)
  if bone.text.width(s) <= n then
    return s
  end
  local cut = bone.text.truncate(s, n):gsub("…$", "")
  local word = cut:gsub("%S*$", ""):gsub("[%s%p]+$", ""):gsub("%s+—$", ""):gsub("%s+–$", "")
  return (word ~= "" and word or cut) .. "…"
end

-- One line per skill: its name, then as much of its description as fits.
-- Names line up in the terminal; the GUI's proportional font gets a dot.
local function rows(list)
  local col = 0
  for _, s in ipairs(list) do
    col = math.max(col, bone.text.width(s.name))
  end
  local out = {}
  for _, s in ipairs(list) do
    local desc = (s.description or ""):gsub("%s+", " ")
    local head = s.name
    if desc ~= "" then
      head = GUI and (head .. "  ·  ") or (head .. string.rep(" ", col - bone.text.width(head) + 2))
    end
    out[#out + 1] = { name = s.name, text = head .. clip(desc, math.max(ROW - bone.text.width(head), 10)) }
  end
  return out
end

local function pick(list, task)
  local items = rows(list)
  local width = 0
  for _, r in ipairs(items) do
    width = math.max(width, bone.text.width(r.text))
  end
  bone.ui.select(items, {
    prompt = "Skills",
    format = function(r) return r.text end,
    footer = "↑↓ move · enter use · esc close",
    width = math.max(width, 50) + 4,
    height = #items + 5,
    on_choice = function(r)
      if r then
        bone.prompt.set("Use the " .. r.name .. " skill: " .. (task or ""))
      end
    end,
  })
end

bone.cmd.create("skill", function(c)
  local name, task = (c.args or ""):match("^(%S+)%s*(.*)$")
  if name and known(name) then
    return use(name, task)
  end
  fetch(function(list)
    if #list == 0 then
      return bone.notify("no skills yet: ask bone to write one in " .. where .. "/NAME/SKILL.md")
    end
    if name and known(name) then
      return use(name, task)
    end
    if name then
      bone.notify("no skill named " .. name)
    end
    pick(list, task)
  end)
end, {
  desc = "pick a skill for the model to use (skills plugin)",
  aliases = { "skills" },
  complete = function()
    -- Skills come and go while bone runs: look again for the next key.
    if os.time() - fetched >= 2 then
      fetch()
    end
    return names
  end,
})

-- A skill call in the chat: "skill  money". Its text is the instructions,
-- not a result, so it shows only when the call is opened; a failure always.
local function lines_of(text, max)
  local out = {}
  for line in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
    if #out == max then
      out[#out + 1] = "⋮"
      break
    end
    out[#out + 1] = line
  end
  while #out > 0 and out[#out] == "" do
    out[#out] = nil
  end
  return out
end

local function skill_view(item, ctx)
  local a = type(item.arguments) == "table" and item.arguments or {}
  local name = type(a.name) == "string" and a.name ~= "" and a.name or "?"
  if ctx.summary then
    -- Its words in a summary line ("Loaded the money skill, read 2 files");
    -- several skills are one phrase ("Loaded 3 skills") on a bone that
    -- reads `many`, and a phrase each on one that does not.
    if item.is_error then
      return { summary = "looked for a " .. name .. " skill", many = "looked for %d skills" }
    end
    return { summary = "loaded the " .. name .. " skill", many = "loaded %d skills" }
  end
  local title = { { GUI and "Skill" or "skill", "ToolName" }, { "  " .. name, GUI and "ToolPath" or "ToolArgs" } }
  local open = item.done and ctx.tool_expanded and not item.is_error
  if GUI then
    -- The card draws `lines` and nothing of its own.
    local shown = item.done and (item.is_error or open)
    return { title = title, lines = shown and lines_of(item.output, 200) or nil }
  end
  -- The terminal's frame draws a failed call's output itself.
  local body = open and type(bone.ui.tool_content) == "function" and bone.ui.tool_content(item, ctx).body or nil
  return { title = title, body = body }
end

bone.ui.tool_views.skill = skill_view
bone.plugin.on_shutdown(function()
  if bone.ui.tool_views.skill == skill_view then
    bone.ui.tool_views.skill = nil
  end
end)

fetch()
bone.on("core/reloaded", function()
  fetch()
end)
