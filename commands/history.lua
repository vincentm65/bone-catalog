-- /history — pick a recent conversation and resume it.
local history = require("history")
local menu = require("ui.menu")

local function parse_timestamp(value)
   local y, month, day, hour, minute, second = tostring(value or ""):match(
      "^(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d):?(%d*)"
   )
   if not y then return nil end
   local epoch = os.time({
      year = tonumber(y), month = tonumber(month), day = tonumber(day),
      hour = tonumber(hour), min = tonumber(minute), sec = tonumber(second) or 0,
   })
   if not epoch then return nil end

   -- Stored timestamps are UTC. os.time interprets the fields as local time,
   -- so apply the local offset to recover the UTC epoch.
   local zone = os.date("%z", epoch)
   local sign, offset_hour, offset_minute = zone:match("^([%+%-])(%d%d):?(%d%d)$")
   if not sign then
      sign, offset_hour = zone:match("^([%+%-])(%d%d)$")
      offset_minute = "00"
   end
   if sign then
      local offset = (tonumber(offset_hour) * 3600 + tonumber(offset_minute) * 60)
         * (sign == "-" and -1 or 1)
      epoch = epoch + offset
   end
   return epoch
end

local function format_when(value, now)
   local epoch = parse_timestamp(value)
   if not epoch then return tostring(value or "unknown time") end
   now = now or os.time()
   local age = math.max(0, now - epoch)
   if age < 60 then return "just now" end
   if age < 3600 then return string.format("%dm ago", math.floor(age / 60)) end

   local day = os.date("%Y-%m-%d", epoch)
   if day == os.date("%Y-%m-%d", now) then
      return string.format("%dh ago", math.floor(age / 3600))
   end
   local yesterday = os.date("*t", now)
   yesterday.day = yesterday.day - 1
   yesterday.hour, yesterday.min, yesterday.sec = 12, 0, 0
   if day == os.date("%Y-%m-%d", os.time(yesterday)) then
      return "Yesterday " .. os.date("%H:%M", epoch)
   end
   if os.date("%Y", epoch) == os.date("%Y", now) then
      return os.date("%b %d %H:%M", epoch):gsub(" 0", " ")
   end
   return os.date("%Y-%m-%d %H:%M", epoch)
end

local function status_text(status)
   if status == "interrupted" then return "No response" end
   if status == "empty" then return "Empty" end
   return "Completed"
end

local function status_color(status)
   if status == "interrupted" then return "#E5C07B" end
   if status == "empty" then return "darkgray" end
   return "#78B373"
end

local function format_count(value)
   local digits = tostring(math.max(0, math.floor(tonumber(value) or 0)))
   return digits:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
end

local function option(row)
   local preview = tostring(row.preview or "(no user message)"):gsub("%s+", " ")
   local provider = tostring(row.provider or "?")
   local model = tostring(row.model or "?")
   local id = tostring(row.id)
   local when = format_when(row.last_activity or row.started_at)
   local messages = format_count(row.total_message_count) .. " messages"
   local tokens = format_count(row.total_token_count) .. " tokens"
   local status = status_text(row.status)
   local description = table.concat({ when, provider .. "/" .. model, "#" .. id, messages, tokens, status }, " · ")
   return {
      label = preview,
      description = description,
      description_spans = {
         { text = when, fg = "#B3BAC8" },
         { text = " · ", fg = "darkgray" },
         { text = provider .. "/" .. model, fg = "#8CC8FF" },
         { text = " · #" .. id .. " · ", fg = "darkgray" },
         { text = messages, fg = "#E5C07B" },
         { text = " · ", fg = "darkgray" },
         { text = tokens, fg = "#E5C07B" },
         { text = " · ", fg = "darkgray" },
         { text = status, fg = status_color(row.status) },
      },
      search_text = table.concat({ preview, provider, model, id, status }, " "),
      value = row.id,
   }
end

bone.register_command("history", {
   description = "Resume a recent conversation",
   handler = function(_, ctx)
      local ok, rows = pcall(history.list, ctx, 50)
      if not ok then
         ctx.ui.notify("Failed to list history: " .. tostring(rows), "error")
         return nil
      end
      if not rows or #rows == 0 then
         ctx.ui.notify("No conversation history found.", "warn")
         return nil
      end

      local options = {}
      for _, row in ipairs(rows) do
         options[#options + 1] = option(row)
      end

      local ask_ok, result = pcall(menu.select, ctx, {
         title = "History",
         question = "Recent conversations — Enter resume · Esc cancel",
         options = options,
         default = 1,
         allow_custom = false,
         searchable = true,
         visible_rows = 18,
      })
      menu.clear(ctx)

      if not ask_ok then
         ctx.ui.notify("History picker failed: " .. tostring(result), "error")
         return nil
      end
      if type(result) ~= "table" or result.cancelled then return nil end

      local id = result.value
      if id == nil then return nil end

      -- Keep the transcript payload for released clients that preload scrollback
      -- from the command action. New clients ignore it and load by id from the daemon.
      local messages_ok, stored = pcall(history.messages, ctx, id, 1000)
      if not messages_ok then
         ctx.ui.notify("Failed to load conversation: " .. tostring(stored), "error")
         return nil
      end
      local messages = {}
      for _, msg in ipairs(stored) do
         if (msg.role == "user" or msg.role == "assistant" or msg.role == "tool")
            and tostring(msg.content or ""):sub(1, 17) ~= "[Context summary]" then
            messages[#messages + 1] = {
               role = msg.role,
               content = msg.content or "",
               name = msg.tool_name,
               tool_call_id = msg.tool_call_id,
               tool_calls = msg.tool_calls,
            }
         end
      end

      return {
         action = "conversation.load",
         conversation_id = id,
         messages = messages,
         submit = false,
      }
   end,
})
