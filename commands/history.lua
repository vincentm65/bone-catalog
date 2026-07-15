-- /history — pick a recent conversation and resume it.
local history = require("history")
local menu = require("ui.menu")

local function truncate(value, max_len)
   local text = tostring(value or ""):gsub("%s+", " ")
   if #text <= max_len then return text end
   return text:sub(1, max_len - 3) .. "..."
end

local function format_when(value)
   local y, month, day, hour, minute = tostring(value or ""):match(
      "^(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d)"
   )
   if not y then return truncate(value, 16) end

   local local_epoch = os.time({
      year = tonumber(y), month = tonumber(month), day = tonumber(day),
      hour = tonumber(hour), min = tonumber(minute), sec = 0,
   })
   if not local_epoch then return truncate(value, 16) end

   local sign, offset_hour, offset_minute = os.date("%z", local_epoch)
      :match("([%+%-])(%d%d)(%d%d)")
   local offset = 0
   if sign then
      offset = (tonumber(offset_hour) * 3600 + tonumber(offset_minute) * 60)
         * (sign == "-" and -1 or 1)
   end
   return os.date("%Y-%m-%d %H:%M", local_epoch + offset)
end

local function label(row)
   local when = format_when(row.activity_at or row.started_at)
   local status = tonumber(row.assistant_count or 0) == 0 and "  [interrupted]" or ""
   return string.format("%s  %s/%s  #%s%s  %s",
      when,
      truncate(row.provider or "?", 14),
      truncate(row.model or "?", 24),
      tostring(row.id),
      status,
      truncate(row.preview or "(no preview)", 60))
end

bone.register_command("history", {
   description = "Resume a recent conversation",
   handler = function(_, ctx)
      local ok, rows = pcall(history.list, ctx, 100)
      if not ok then
         ctx.ui.notify("Failed to list history: " .. tostring(rows), "error")
         return nil
      end
      if not rows or #rows == 0 then
         ctx.ui.notify("No conversation history found.", "warn")
         return nil
      end

      local options, by_label = {}, {}
      for _, row in ipairs(rows) do
         local text = label(row)
         options[#options + 1] = text
         by_label[text] = row.id
      end

      local ask_ok, result = pcall(menu.select, ctx, {
         question = "Resume conversation  ·  Enter load  ·  Esc cancel",
         options = options,
         default = 1,
         allow_custom = false,
      })
      menu.clear(ctx)

      if not ask_ok then
         ctx.ui.notify("History picker failed: " .. tostring(result), "error")
         return nil
      end
      if type(result) ~= "table" or result.cancelled then return nil end

      local id = by_label[result.value]
      if not id then return nil end

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
         display = "Loading conversation #" .. tostring(id) .. "...",
         submit = false,
      }
   end,
})
