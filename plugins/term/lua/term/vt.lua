-- What every terminal pane does the same way, whichever module draws it (the
-- multiplexer's panes, bone.ui.terminal's panels): the cursor's cell, a
-- mouse report's bytes, and the keys that scroll back instead of typing.
local M = {}

--- `line` with the cell at `col` drawn as the cursor.
function M.with_cursor(line, col)
  local out, x, done = {}, 1, false
  for _, item in ipairs(line) do
    local text, hl = item[1], item[2]
    local w = bone.text.width(text)
    if not done and col < x + w then
      local before, cell, after, cx = "", nil, "", x
      for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        if cell then after = after .. ch
        elseif cx + bone.text.width(ch) > col then cell = ch
        else before = before .. ch end
        cx = cx + bone.text.width(ch)
      end
      if before ~= "" then out[#out + 1] = { before, hl } end
      out[#out + 1] = { cell or " ", "TermCursor" }
      if after ~= "" then out[#out + 1] = { after, hl } end
      done = true
    else
      out[#out + 1] = item
    end
    x = x + w
  end
  if not done then
    out[#out + 1] = { string.rep(" ", math.max(0, col - x)) }
    out[#out + 1] = { " ", "TermCursor" }
  end
  return out
end

-- A value of xterm's UTF-8 mouse encoding (LuaJIT has no utf8 library).
local function utf8(n)
  return n < 128 and string.char(n) or string.char(192 + math.floor(n / 64), 128 + n % 64)
end

--- xterm's report of a mouse action at `col`, `row` of screen `s` (nil when
--- the program does not ask for the mouse).
function M.mouse(s, action, button, col, row)
  local mode = s and s.mouse
  if mode == nil or mode == "none" then return nil end
  if action == "up" and mode == "press" then return nil end
  if action == "drag" and mode ~= "button_motion" and mode ~= "any_motion" then return nil end
  local code
  if action == "wheel" then code = button == "up" and 64 or 65
  else
    code = ({ left = 0, middle = 1, right = 2 })[button or "left"]
    if not code then return nil end
    if action == "up" then code = 3 elseif action == "drag" then code = code + 32 end
  end
  if s.mouse_encoding == "sgr" then
    return string.format("\27[<%d;%d;%d%s", code, col, row, action == "up" and "m" or "M")
  end
  if s.mouse_encoding == "utf8" then return "\27[M" .. utf8(32 + code) .. utf8(32 + col) .. utf8(32 + row) end
  -- The legacy encoding stops at its printable range; programs that need
  -- more ask for SGR.
  return "\27[M" .. string.char(32 + code, 32 + math.min(223, col), 32 + math.min(223, row))
end

--- Scroll terminal `t` ({ screen, scroll }) back or forth when `key` is one
--- that does: the wheel, shift+page keys, ctrl+home/end, and the plain page
--- keys once it is scrolled back. Every other key is the program's. True
--- when it scrolled.
function M.scroll(t, key)
  local s = t.screen
  local max, page = s and s.max or 0, math.max(1, (s and #s.lines or 24) - 1)
  local by = key == "wheelup" and 3 or key == "wheeldown" and -3
    or (key == "shift+pageup" or (key == "pageup" and t.scroll > 0)) and page
    or (key == "shift+pagedown" or (key == "pagedown" and t.scroll > 0)) and -page
    or (key == "ctrl+home" and max > 0) and max
    or key == "ctrl+end" and -max
  if not by then return false end
  t.scroll = math.max(0, math.min(max, t.scroll + by))
  return true
end

return M
