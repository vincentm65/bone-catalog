-- /claude-usage: the Claude plan's usage windows, as the latest Claude Code
-- request reported them (every request does; none is made to ask).
local windows = { five_hour = "5-hour", seven_day = "Weekly", seven_day_opus = "Weekly Opus",
  seven_day_sonnet = "Weekly Sonnet" }
local order = { five_hour = 1, seven_day = 2, seven_day_opus = 3, seven_day_sonnet = 4 }

local function show_usage()
  bone.rpc.call("claude-code.limits", {}, function(u, err)
    if err or not u then return bone.notify(err and tostring(err) or "claude-code: usage request cancelled", err and "error") end
    local page = { kind = "column", { kind = "text", text = "Plan: " .. tostring(u.plan or "unknown"), tone = "accent", strong = true } }
    local info = type(u.info) == "table" and u.info or nil
    local spans = info and type(info.unifiedWindows) == "table" and info.unifiedWindows or {}
    local names = {}
    for name in pairs(spans) do names[#names + 1] = name end
    table.sort(names, function(a, b)
      local x, y = order[a] or 9, order[b] or 9
      return x < y or (x == y and a < b)
    end)
    for _, name in ipairs(names) do
      local w = spans[name]
      if type(w) == "table" then
        local row = { kind = "row", { kind = "text", text = windows[name] or name, strong = true } }
        local used = tonumber(w.utilization)
        if w.status == "rejected" then
          row[#row + 1] = { kind = "text", text = "limit reached", tone = "error" }
        elseif used then
          local left = 100 - math.max(0, math.min(100, used * 100))
          local tone = left <= 10 and "error" or (left <= 30 and "warning" or "accent")
          row[#row + 1] = { kind = "meter", value = left / 100, label = string.format("%.0f%% left", left), tone = tone }
        end
        local reset = tonumber(w.resetsAt)
        if reset then row[#row + 1] = { kind = "text", text = "resets " .. os.date("%a %H:%M", reset), tone = "dim" } end
        page[#page + 1] = row
      end
    end
    if info and info.isUsingOverage then
      page[#page + 1] = { kind = "text", text = "Using extra usage beyond the plan.", tone = "warning" }
    end
    if #names == 0 then
      page[#page + 1] = { kind = "text", text = "No usage reported yet; it arrives with the next Claude Code request.", tone = "dim" }
    elseif tonumber(u.at) then
      page[#page + 1] = { kind = "text", text = "As of the latest request, " .. os.date("%a %H:%M", tonumber(u.at)), tone = "dim" }
    end
    bone.ui.pager(page, { title = "Claude usage" })
  end)
end
bone.cmd.create("claude-usage", show_usage, { desc = "show Claude plan usage and reset times" })
