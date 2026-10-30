-- A persistent override for every Codex provider, applied on the next request.
bone.cmd.create("fast", function(c)
  local arg = (c.args or ""):match("^%s*(.-)%s*$"):lower()
  if arg ~= "" and arg ~= "on" and arg ~= "off" then
    return bone.notify("usage: /fast [on|off]", "error")
  end
  local enabled = arg == "on" or (arg == "" and not bone.settings.get("codex.fast"))
  bone.settings.set("codex.fast", enabled, function(_, err)
    if err then
      return bone.notify("codex: " .. tostring(err), "error")
    end
    bone.notify("Codex fast mode " .. (enabled and "on (priority service tier)" or "off") .. "; applies to the next Codex request")
  end)
end, { desc = "toggle Codex fast mode; /fast on|off sets it explicitly" })

local function show_usage()
  bone.rpc.call("codex.usage", {}, function(u, err)
    if err or not u then return bone.notify(err and tostring(err) or "codex: usage request cancelled", err and "error") end
    -- One page for both frontends: a section per limit, a meter per window.
    local page = { kind = "column", { kind = "text", text = "Plan: " .. tostring(u.plan_type or "unknown"), tone = "accent", strong = true } }
    local function add(el) page[#page + 1] = el end
    for _, section in ipairs({ { "Codex", u.rate_limit }, { "Code review", u.code_review_rate_limit } }) do
      local title, limit = section[1], section[2]
      if type(limit) == "table" then
        local box = { kind = "section", title = title .. (limit.limit_reached and " — limit reached" or "") }
        for _, key in ipairs({ "primary_window", "secondary_window" }) do
          local w = limit[key]
          if type(w) == "table" then
            local seconds, used = tonumber(w.limit_window_seconds), tonumber(w.used_percent)
            local label = key == "primary_window" and "Primary window" or "Secondary window"
            if seconds then label = string.format("%g-%s window", seconds / (seconds >= 86400 and 86400 or 3600), seconds >= 86400 and "day" or "hour") end
            if used then
              local remaining = 100 - math.max(0, math.min(100, used))
              local tone = remaining <= 10 and "error" or (remaining <= 30 and "warning" or "accent")
              box[#box + 1] = { kind = "row", { kind = "text", text = label, strong = true },
                { kind = "meter", value = remaining / 100, label = string.format("%g%% remaining", remaining), tone = tone } }
            else
              box[#box + 1] = { kind = "row", { kind = "text", text = label, strong = true }, { kind = "text", text = "Usage unavailable", tone = "dim" } }
            end
            local reset = tonumber(w.reset_at) or (tonumber(w.reset_after_seconds) and os.time() + tonumber(w.reset_after_seconds))
            if reset then box[#box + 1] = { kind = "text", text = "Resets: " .. os.date("%Y-%m-%d %H:%M %Z", reset), tone = "dim" } end
          end
        end
        add(box)
      end
    end
    local c = type(u.credits) == "table" and u.credits or {}
    local balance = c.unlimited and "unlimited" or c.balance or (c.has_credits == false and "none")
    if balance then add({ kind = "section", { kind = "text", text = "Credits: " .. tostring(balance) } }) end
    if not u.rate_limit then add({ kind = "text", text = "Quota information is unavailable for this account.", tone = "dim" }) end
    bone.ui.pager(page, { title = "Codex usage" })
  end)
end
for _, name in ipairs({ "usage", "codex-usage" }) do
  bone.cmd.create(name, show_usage, { desc = "show Codex plan usage and reset times" })
end
