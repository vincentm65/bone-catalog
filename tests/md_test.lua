-- Run from catalog root: luajit tests/md_test.lua
-- BONE_SOURCE may point to a Bone 3 checkout (default: ../bone3).
-- Real popup box helper, deterministic UTF-8 text/Markdown and async job mocks.
local original_print = print
local ROOT = (arg[0]:match("^(.*)/tests/md_test%.lua$") or ".") .. "/"
local BONE_SOURCE = (os.getenv("BONE_SOURCE") or "../bone3") .. "/"
package.path = ROOT .. "plugins/md/lua/?.lua;" .. package.path
local CHAR = "[%z\1-\127\194-\244][\128-\191]*"
local function chars(s)
  local out = {}
  for ch in s:gmatch(CHAR) do out[#out + 1] = ch end
  return out
end
local function width(s) return #chars(s) end
local function truncate(s, n)
  local out = chars(s)
  while #out > math.max(0, n) do out[#out] = nil end
  return table.concat(out)
end
local function wrap(spans, n)
  assert(n > 0, "wrap width must be positive")
  local out, row, used = {}, {}, 0
  local function flush() out[#out + 1], row, used = row, {}, 0 end
  for _, span in ipairs(spans) do
    for _, ch in ipairs(chars(span[1])) do
      if ch == "\n" then flush()
      else
        if used == n then flush() end
        local last = row[#row]
        if last and last[2] == span[2] then last[1] = last[1] .. ch
        else row[#row + 1] = { ch, span[2] } end
        used = used + 1
      end
    end
  end
  if #row > 0 then flush() end
  return out
end
-- Loading the API only to obtain its actual box helper; no calls reach Rust.
bone = { _api = function() end, on = function() end, text = {} }
dofile(BONE_SOURCE .. "runtime/ui/api.lua")
local real_box, real_edit = bone.ui.box, bone.text.edit
print = original_print

local function eq(actual, expected, why)
  if actual ~= expected then
    error((why or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
  end
end
local function contains(s, part, why)
  assert(s:find(part, 1, true), (why or "missing text") .. ": " .. part .. "\n" .. s)
end
local function excludes(s, part)
  assert(not s:find(part, 1, true), "unexpected text: " .. part .. "\n" .. s)
end
local function argv(job, expected)
  eq(#job.argv, #expected, "argv length")
  for i, value in ipairs(expected) do eq(job.argv[i], value, "argv[" .. i .. "]") end
end
local SCAN = { "find", "-P", ".", "-name", ".git", "-prune", "-o", "-type", "f", "-iname", "*.md", "-print0" }
local function fixture(opts)
  opts = opts or {}
  local f = { jobs = {}, popups = {}, events = {}, notices = {}, md_calls = {}, off_ids = {}, next_id = 0 }
  function f:emit(name, ev)
    local callbacks = {}
    for _, entry in pairs(self.events) do
      if entry.name == name then callbacks[#callbacks + 1] = entry.fn end
    end
    for _, fn in ipairs(callbacks) do fn(ev) end
  end
  bone = {
    text = { width = width, truncate = truncate, wrap = wrap, edit = real_edit },
    chat = { session = function()
      if opts.chat_session == false then return nil end
      return opts.chat_session or { cwd = "/project with spaces" }
    end },
    api = { session = function() return opts.api_session end },
    notify = function(text, level) f.notices[#f.notices + 1] = { text = text, level = level } end,
    on = function(name, fn)
      f.next_id = f.next_id + 1
      f.events[f.next_id] = { name = name, fn = fn }
      return f.next_id
    end,
    off = function(id) f.events[id] = nil; f.off_ids[#f.off_ids + 1] = id end,
    ui = {}, job = {},
  }
  bone.ui.box = real_box
  bone.ui.popup = function(spec)
    f.next_id = f.next_id + 1
    f.popups[f.next_id] = { spec = spec, open = true, closes = 0 }
    return f.next_id
  end
  bone.ui.is_open = function(id) return f.popups[id] and f.popups[id].open or false end
  bone.ui.close = function(id)
    local popup = assert(f.popups[id])
    if not popup.open then return end
    popup.open, popup.closes = false, popup.closes + 1
    f:emit("panel/closed", { id = id, kind = "popup" })
  end
  bone.ui.markdown = function(text, n, prefix)
    f.md_calls[#f.md_calls + 1] = { text = text, width = n, prefix = prefix }
    if text == "" then return {} end
    return wrap({ { text, "Normal" } }, n)
  end
  bone.job.start = function(args, spec)
    local job = { argv = args, spec = spec, cancellations = 0 }
    function job:cancel() self.cancellations = self.cancellations + 1 end
    function job:stdout(data) self.spec.on_stdout(data, self) end
    function job:stderr(data) self.spec.on_stderr(data, self) end
    function job:exit(state, code, err)
      self.spec.on_exit({ state = state or "exited", code = code == nil and 0 or code, error = err }, self)
    end
    f.jobs[#f.jobs + 1] = job
    return job
  end
  f.help = dofile(ROOT .. "plugins/md/lua/md_browser.lua")
  function f:open(path) self.id = self.help.open(path); return self.id end
  function f:key(k, id) return self.popups[id or self.id].spec.on_key(k) end
  -- The popup's view as words; a Markdown body through bone.ui.markdown.
  function f:render(_, _, id)
    local out = {}
    local function walk(el)
      if type(el) ~= "table" then return end
      if el.kind == "markdown" then
        for _, line in ipairs(bone.ui.markdown(el.text, 88, "")) do
          local parts = {}
          for _, span in ipairs(line) do parts[#parts + 1] = span[1] end
          out[#out + 1] = table.concat(parts)
        end
        return
      end
      for _, k in ipairs({ "text", "label", "value" }) do
        if type(el[k]) == "string" then out[#out + 1] = el[k] end
      end
      for _, it in ipairs(el.items or {}) do out[#out + 1] = it.text end
      if el.kind == "list" and #el.items == 0 and el.empty then out[#out + 1] = el.empty end
      for i = 1, table.maxn(el) do walk(el[i]) end
    end
    walk(self.popups[id or self.id].spec.view())
    return table.concat(out, "\n")
  end
  function f:last(name)
    for i = #self.jobs, 1, -1 do if self.jobs[i].spec.name == name then return self.jobs[i] end end
  end
  function f:scan(files, job)
    job = job or self:last("md scan")
    for _, file in ipairs(files) do job:stdout("./" .. file .. "\0") end
    job:exit()
    return self:last("md read")
  end
  function f:read(text, job)
    job = job or self:last("md read")
    job:stdout(text); job:exit()
    return job
  end
  return f
end
local function long_document()
  local lines = {}
  for i = 1, 80 do lines[i] = string.format("ROW%02d", i) end
  return table.concat(lines, "\n")
end
local tests = {}
local function test(name, fn) tests[#tests + 1] = { name, fn } end

test("NUL-delimited chunks preserve newline, spaces, quotes and UTF-8 paths; sort files", function()
  local f = fixture(); f:open()
  local scan = f:last("md scan")
  argv(scan, SCAN)
  eq(scan.spec.cwd, "/project with spaces"); eq(scan.spec.timeout, 30000)
  scan:stdout("./z.md\0./white space.md\0./line\n")
  scan:stdout("break.md\0./quote'\".md\0./é.md")
  scan:stdout("\0./a.md\0")
  eq(#f.jobs, 1, "no reads before scan exits")
  scan:exit()
  local read = f:last("md read")
  argv(read, { "head", "-c", "1048577", "--", "./a.md" })
  eq(read.spec.cwd, scan.spec.cwd); eq(read.spec.timeout, 10000)
  f:render(); f:key("down")
  argv(f:last("md read"), { "head", "-c", "1048577", "--", "./line\nbreak.md" })
  f:key("down"); eq(f:last("md read").argv[5], "./quote'\".md")
  f:key("down"); eq(f:last("md read").argv[5], "./white space.md")
  f:key("down"); eq(f:last("md read").argv[5], "./z.md")
  f:key("down"); eq(f:last("md read").argv[5], "./é.md")
  local text = f:render()
  contains(text, "line break.md"); excludes(text, "line\nbreak.md")
end)

test("file filter uses all words, literal punctuation, Unicode backspace and clear", function()
  local f = fixture(); f:open(); f:scan({ "z.md", "notes/é space.md", "other/é.md", "literal[.md" })
  f:key("é"); contains(f:render(), "Filter · 2 files")
  f:key("space"); f:key("s"); contains(f:render(), "Filter · 1 file")
  eq(f:last("md read").argv[5], "./notes/é space.md")
  f:key("backspace"); f:key("backspace"); f:key("backspace")
  contains(f:render(), "Filter · 4 files", "whole Unicode codepoint removed")
  f:key("["); contains(f:render(), "Filter · 1 file")
  eq(f:last("md read").argv[5], "./literal[.md")
  f:key("ctrl+u"); contains(f:render(), "Filter · 4 files")
  f:key("x"); contains(f:render(), "No matches.")
  eq(f:key("ctrl+z"), false, "unhandled key")
end)

test("direct relative path opens reader and normalizes CRLF", function()
  local f = fixture(); f:open("  ./docs/a b.md  ")
  f:scan({ "z.md", "docs/a b.md", "a.md" })
  eq(f:last("md read").argv[5], "./docs/a b.md")
  f:read("# Title\r\nhello\r\n")
  local text = f:render(70, 18)
  contains(text, "docs/a b.md"); contains(text, "# Title"); contains(text, "hello")
  eq(f.md_calls[1].text, "# Title\nhello\n"); eq(f.md_calls[1].prefix, "")
  eq(f:key("x"), false, "typing in reader does not filter")
end)

test("invalid paths rejected before replacing existing popup", function()
  local f = fixture(); local id = f:open()
  for _, path in ipairs({ "/etc/a.md", "../a.md", "a/../b.md", "a/..", "..", "a\0.md" }) do
    eq(f.help.open(path), nil); eq(#f.jobs, 1)
    eq(f.popups[id].open, true)
    contains(f.notices[#f.notices].text, "relative Markdown path")
    eq(f.notices[#f.notices].level, "error")
  end
end)

test("missing direct path notifies but leaves file browser usable", function()
  local f = fixture(); f:open("missing.md"); f:scan({ "exists.md" })
  contains(f.notices[1].text, "Markdown file not found: missing.md")
  contains(f:render(70, 18), "Filter · 1 file")
end)

test("session cwd fallback and default cwd", function()
  local f = fixture({ chat_session = false, api_session = { cwd = "/fallback" } })
  f:open(); eq(f:last("md scan").spec.cwd, "/fallback")
  f = fixture({ chat_session = false }); f:open(); eq(f:last("md scan").spec.cwd, ".")
end)

test("switching file cancels read; stale output/error/exit cannot overwrite new content", function()
  local f = fixture(); f:open(); f:scan({ "a.md", "b.md" })
  local old = f:last("md read"); old:stdout("old partial")
  f:key("down"); eq(old.cancellations, 1)
  f:read("CURRENT B")
  old:stdout("STALE A"); old:stderr("old error"); old:exit("failed", 1)
  f:key("enter"); local text = f:render(70, 18)
  contains(text, "CURRENT B"); excludes(text, "STALE A"); excludes(text, "old error")
end)

test("refresh cancels outstanding jobs and rejects stale scan/read callbacks", function()
  local f = fixture(); f:open()
  local old_scan = f:last("md scan"); old_scan:stdout("./stale.md\0")
  f:key("ctrl+r"); eq(old_scan.cancellations, 1)
  old_scan:stdout("./late.md\0"); old_scan:stderr("stale scan error"); old_scan:exit("failed", 1)
  eq(#f.jobs, 2, "stale scan must not start a read")
  f:scan({ "a.md" }); local old_read = f:last("md read")
  f:key("ctrl+r"); eq(old_read.cancellations, 1)
  old_read:stdout("STALE"); old_read:exit()
  f:scan({ "a.md", "b.md" }); f:read("FRESH"); f:key("enter")
  local text = f:render(70, 18)
  contains(text, "FRESH"); excludes(text, "STALE"); excludes(text, "stale scan error")
end)

test("escape closes once, cancels jobs, removes event subscription and rejects late scan", function()
  local f = fixture(); local id = f:open(); local scan = f:last("md scan")
  f:key("esc"); eq(scan.cancellations, 1); eq(f.popups[id].closes, 1); eq(#f.off_ids, 1)
  scan:stdout("./late.md\0"); scan:stderr("late error"); scan:exit()
  eq(#f.jobs, 1); eq(#f.notices, 0)
  f:key("esc"); eq(scan.cancellations, 1); eq(f.popups[id].closes, 1)
end)

test("external popup close cancels reader; unrelated panel close is ignored", function()
  local f = fixture(); local id = f:open(); f:scan({ "a.md" })
  local read = f:last("md read")
  f:emit("panel/closed", { id = id, kind = "panel" }); eq(read.cancellations, 0)
  f:emit("panel/closed", { id = id + 100, kind = "popup" }); eq(read.cancellations, 0)
  bone.ui.close(id); eq(read.cancellations, 1); eq(#f.off_ids, 1)
  read:stdout("late"); read:stderr("late error"); read:exit("failed", 1)
  eq(#f.notices, 0); eq(#f.md_calls, 0)
end)

test("opening replacement closes old popup without stale callbacks affecting new one", function()
  local f = fixture(); local old_id = f:open(); local old_scan = f:last("md scan")
  local id = f:open("new.md"); eq(f.popups[old_id].open, false); eq(old_scan.cancellations, 1)
  old_scan:stdout("./old.md\0"); old_scan:exit(); eq(#f.jobs, 2)
  f:scan({ "new.md" }); f:read("new popup"); contains(f:render(70, 18), "new popup")
  f:emit("panel/closed", { id = old_id, kind = "popup" }); eq(f.popups[id].open, true)
  f:key("esc"); eq(f.popups[id].open, false)
end)

test("no files and scan failures show informative messages, including partial results", function()
  local f = fixture(); f:open(); contains(f:render(), "Scanning…"); f:scan({})
  contains(f:render(), "No Markdown files."); eq(#f.jobs, 1)
  f:key("ctrl+r"); local scan = f:last("md scan")
  scan:stdout("./partial.md\0"); scan:stderr("permission denied"); scan:exit("exited", 1)
  local text = f:render(); contains(text, "partial.md"); contains(text, "Scan incomplete: permission denied")
  f:key("ctrl+r"); f:last("md scan"):exit("failed", nil, "spawn failed")
  contains(f:render(), "Scan incomplete: spawn failed")
end)

test("read errors prefer bounded stderr and fall back to error or state", function()
  for _, case in ipairs({
    { "exited", 1, "ignored", "permission denied", "permission denied" },
    { "failed", nil, "spawn failed", nil, "spawn failed" },
    { "cancelled", nil, nil, nil, "cancelled" },
  }) do
    local f = fixture(); f:open("a.md"); f:scan({ "a.md" })
    local read = f:last("md read")
    if case[4] then read:stderr(case[4]) end
    read:exit(case[1], case[2], case[3])
    local text = f:render(70, 18)
    contains(text, "Cannot read file:"); contains(text, case[5]); eq(#f.md_calls, 0)
  end
  local f = fixture(); f:open(); f:scan({ "a.md" })
  local read = f:last("md read"); read:stderr(string.rep("x", 2048)); read:stderr("MUST_NOT_APPEAR"); read:exit("failed", 1)
  f:key("enter"); excludes(f:render(70, 18), "MUST_NOT_APPEAR")
end)

test("empty Markdown and NUL-containing documents", function()
  local f = fixture(); f:open("empty.md"); f:scan({ "empty.md" }); f:last("md read"):exit()
  contains(f:render(70, 18), "Empty Markdown file."); eq(#f.md_calls, 0)
  f:key("ctrl+r"); f:scan({ "empty.md" }); f:read("a\0b")
  contains(f:render(70, 18), "Not a text Markdown file"); eq(#f.md_calls, 0)
end)

test("read byte cap allows exactly 1 MiB and rejects larger chunked documents", function()
  local limit = 1024 * 1024
  local f = fixture(); f:open("large.md"); f:scan({ "large.md" })
  f:read(string.rep("x", limit))
  f:key("ctrl+r"); f:scan({ "large.md" })
  local read = f:last("md read")
  read:stdout(string.rep("x", limit - 1)); read:stdout("xx"); read:stdout(string.rep("y", 100)); read:exit()
  contains(f:render(70, 18), "File exceeds the 1 MiB reader limit."); eq(#f.md_calls, 0)
  -- Verify the successful exact-limit case through the renderer with a cheap stub.
  f:key("ctrl+r"); f:scan({ "large.md" }); f:read(string.rep("x", limit))
  bone.ui.markdown = function(text) eq(#text, limit); return { { { "EXACT LIMIT", "Normal" } } } end
  contains(f:render(70, 18), "EXACT LIMIT")
end)

test("scan file cap cancels at 20,000 names and reports truncated listing", function()
  local f = fixture(); f:open(); local scan = f:last("md scan")
  local names = {}
  for i = 1, 20001 do names[i] = string.format("./f%05d.md\0", i) end
  scan:stdout(table.concat(names)); eq(scan.cancellations, 1)
  scan:stdout("./extra.md\0"); scan:exit("cancelled")
  local text = f:render(130, 24)
  contains(text, "Filter · 20000 files"); contains(text, "Showing the first 20,000 files; scan limit reached.")
  -- 500 are listed at once; typing narrows to the rest.
  contains(text, "19500 more")
  f:key("end"); eq(f:last("md read").argv[5], "./f00500.md")
end)

test("plugin /md command is registered and forwards optional argument; shutdown closes popup", function()
  local f = fixture(); local commands = {}
  bone.cmd = { create = function(name, fn, opts) commands[name] = { fn = fn, opts = opts } end }
  local shutdown
  bone.plugin = { on_shutdown = function(fn) shutdown = fn end }
  local saved = package.loaded["md_browser"]
  package.loaded["md_browser"] = f.help
  dofile(ROOT .. "plugins/md/ui.lua")
  assert(commands.md); contains(commands.md.opts.desc, "Markdown")
  local id = commands.md.fn({ args = "docs/a.md" }); eq(id, f.next_id - 1)
  f.id = id; f:scan({ "docs/a.md" }); f:read("command document")
  contains(f:render(70, 18), "command document")
  id = commands.md.fn({ args = "" }); f.id = id
  f:scan({}); contains(f:render(), "No Markdown files.")
  assert(shutdown); shutdown(); eq(f.popups[id].open, false)
  package.loaded["md_browser"] = saved
end)

local failures = 0
for _, entry in ipairs(tests) do
  local ok, err = xpcall(entry[2], debug.traceback)
  if ok then original_print("ok - " .. entry[1])
  else failures = failures + 1; original_print("FAIL - " .. entry[1] .. "\n" .. err) end
end
original_print(string.format("%d tests, %d failures", #tests, failures))
os.exit(failures == 0 and 0 or 1)
