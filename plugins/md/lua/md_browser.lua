-- Local Markdown popup, implemented only with existing Bone Lua APIs.
local M = {}
local CHAR = "^[%z\1-\127\194-\244][\128-\191]*$"

local markdown_close
function M.open(path)
  path = (path or ""):match("^%s*(.-)%s*$"):gsub("^%./", "")
  if path:sub(1, 1) == "/" or path:find("%z") or path:find("^%.%./")
    or path:find("/%.%./") or path:match("/%.%.$") or path == ".." then
    return bone.notify("/md expects a relative Markdown path inside the working directory", "error")
  end
  if markdown_close then markdown_close() end
  local session = bone.chat.session() or bone.api.session() or {}
  local cwd = session.cwd or "."
  local st = { files = {}, filtered = {}, query = "", sel = 1, pane = "files",
    rows = 1, top = 0, total = 0, positions = {}, loading = true }
  local id, scan, read, closed, close_event
  local scan_version, read_version = 0, 0
  local MAX_BYTES, MAX_FILES = 1024 * 1024, 20000
  local function alive() return not closed and bone.ui.is_open(id) end
  local function cancel(job) if job then job:cancel() end end
  local function close()
    if closed then return end
    closed = true
    cancel(scan)
    cancel(read)
    if close_event then bone.off(close_event) end
    bone.ui.close(id)
    markdown_close = nil
  end
  local function select_file()
    local file = st.filtered[st.sel]
    if file == st.file then return end
    if st.file then st.positions[st.file] = st.top end
    st.file, st.top = file, file and st.positions[file] or 0
    st.text, st.lines, st.read_error = nil, nil, nil
    read_version = read_version + 1
    local version = read_version
    cancel(read)
    read = nil
    if not file then return end
    local chunks, bytes, stderr = {}, 0, ""
    -- argv, not shell interpolation: spaces, quotes and newlines are safe.
    read = bone.job.start({ "head", "-c", tostring(MAX_BYTES + 1), "--", "./" .. file }, {
      name = "md read", cwd = cwd, timeout = 10000,
      on_stdout = function(data)
        if not alive() or version ~= read_version then return end
        local piece = data:sub(1, math.max(0, MAX_BYTES + 1 - bytes))
        chunks[#chunks + 1], bytes = piece, bytes + #piece
      end,
      on_stderr = function(data) stderr = (stderr .. data):sub(1, 2048) end,
      on_exit = function(r)
        if not alive() or version ~= read_version then return end
        read = nil
        if r.state ~= "exited" or r.code ~= 0 then
          st.read_error = "Cannot read file: " .. (stderr ~= "" and stderr or r.error or r.state)
        elseif bytes > MAX_BYTES then st.read_error = "File exceeds the 1 MiB reader limit."
        else
          st.text = table.concat(chunks):gsub("\r\n", "\n")
          if st.text:find("%z") then st.text, st.read_error = nil, "Not a text Markdown file (contains NUL bytes)." end
        end
      end,
    })
  end
  local function filter()
    st.filtered = {}
    for _, file in ipairs(st.files) do
      local match = true
      for word in st.query:lower():gmatch("%S+") do
        if not file:lower():find(word, 1, true) then match = false; break end
      end
      if match then st.filtered[#st.filtered + 1] = file end
    end
    st.sel = math.max(1, math.min(st.sel, #st.filtered))
    select_file()
  end
  local function discover(wanted)
    scan_version = scan_version + 1
    local version = scan_version
    cancel(scan)
    st.loading, st.scan_error = true, nil
    local files, pending, stderr, limited = {}, "", "", false
    scan = bone.job.start({ "find", "-P", ".", "-name", ".git", "-prune", "-o",
      "-type", "f", "-iname", "*.md", "-print0" }, {
      name = "md scan", cwd = cwd, timeout = 30000,
      on_stdout = function(data, job)
        if not alive() or version ~= scan_version or limited then return end
        pending = pending .. data
        local start = 1
        while true do
          local stop = pending:find("\0", start, true)
          if not stop then break end
          files[#files + 1] = pending:sub(start, stop - 1):gsub("^%./", "")
          start = stop + 1
          if #files >= MAX_FILES then limited = true; job:cancel(); break end
        end
        pending = pending:sub(start)
      end,
      on_stderr = function(data) stderr = (stderr .. data):sub(1, 2048) end,
      on_exit = function(r)
        if not alive() or version ~= scan_version then return end
        scan, st.loading = nil, false
        table.sort(files)
        st.files, st.sel = files, 1
        if limited then st.scan_error = "Showing the first 20,000 files; scan limit reached."
        elseif r.state ~= "exited" or r.code ~= 0 then
          st.scan_error = "Scan incomplete: " .. (stderr ~= "" and stderr or r.error or r.state)
        end
        filter()
        if wanted and wanted ~= "" then
          local found = false
          for i, file in ipairs(st.filtered) do
            if file == wanted then st.sel, found = i, true; break end
          end
          if found then select_file(); st.pane = "reader"
          else bone.notify("Markdown file not found: " .. wanted, "error") end
        end
      end,
    })
  end
  local function clip(spans, width, pad)
    local out, left = {}, width
    for _, span in ipairs(spans) do
      if left <= 0 then break end
      local text = bone.text.truncate(span[1]:gsub("[%z\1-\31\127]", " "), left)
      out[#out + 1], left = { text, span[2] }, left - bone.text.width(text)
    end
    if pad and left > 0 then out[#out + 1] = { string.rep(" ", left), "Normal" } end
    return out
  end
  local function render(ctx)
    local w, h = math.max(1, ctx.width - 4), math.max(1, ctx.height - 2)
    if w < 20 or h < 8 then
      return { clip({ { "Markdown · enlarge terminal · esc close", "Dim" } }, ctx.width) }
    end
    local inner = w - 4
    local split = inner >= 76
    local left = split and math.min(32, math.floor(inner * 0.3)) or inner
    local right = split and (inner - left - 3) or inner
    st.rows = h - 6
    local reader = {}
    if st.file and st.text then
      local md_width = math.min(right, 88)
      if not st.lines or st.line_width ~= md_width then
        st.lines, st.line_width = bone.ui.markdown(st.text, md_width, ""), md_width
      end
      reader = st.lines
      if #reader == 0 then reader = { { { "Empty Markdown file.", "Dim" } } } end
    else
      local message = st.read_error or (st.file and "Loading document…" or "Select a Markdown file to read.")
      reader = bone.text.wrap({ { message, st.read_error and "Error" or "Dim" } }, right)
    end
    st.total = #reader
    if st.text then st.top = math.max(0, math.min(st.top, st.total - st.rows)) end
    local visible_top = st.text and st.top or 0
    local first, list = math.max(1, st.sel - st.rows + 1), {}
    for i = first, math.min(#st.filtered, first + st.rows - 1) do
      list[#list + 1] = { { (i == st.sel and "› " or "  ") .. st.filtered[i], i == st.sel and "Selection" or "Normal" } }
    end
    if #list == 0 then
      list = { { { st.loading and "Scanning…" or (#st.files == 0 and "No Markdown files." or "No matches."), "Dim" } } }
    end
    local function join(a, b)
      if not split then return clip(st.pane == "files" and a or b, inner) end
      local out = clip(a, left, true)
      out[#out + 1] = { " │ ", "PopupBorder" }
      for _, span in ipairs(clip(b, right)) do out[#out + 1] = span end
      return out
    end
    local body = {
      join({ { "Files · " .. #st.filtered .. (st.pane == "files" and " ◂" or ""), "Accent" } },
        { { (st.file or "Preview") .. (st.pane == "reader" and " ◂" or ""), "Accent" } }),
      clip({ { st.loading and "Scanning Markdown files…" or "Filter: " .. (st.query == "" and "type in file pane…" or st.query), "Dim" } }, inner),
      { { string.rep("─", inner), "PopupBorder" } },
    }
    for i = 1, st.rows do body[#body + 1] = join(list[i] or {}, reader[visible_top + i] or {}) end
    local position = st.file and string.format("%d/%d · ", math.min(st.top + st.rows, st.total), st.total) or ""
    body[#body + 1] = clip({ { st.scan_error or (position .. "↑↓ move/scroll · enter read · tab panes · ctrl+r refresh · esc close"), "Dim" } }, inner)
    return bone.ui.box(body, { title = "Markdown · " .. cwd, width = w })
  end
  local function on_key(k)
    if k == "esc" then close()
    elseif k == "tab" or k == "shift+tab" or k == "backtab" then
      st.pane = st.pane == "files" and "reader" or "files"
    elseif k == "enter" then st.pane = "reader"
    elseif k == "ctrl+r" then
      local wanted = st.file
      if wanted then st.positions[wanted] = st.top end
      st.file = nil
      read_version = read_version + 1
      cancel(read)
      st.text, st.lines = nil, nil
      discover(wanted)
    elseif k == "up" or k == "down" or k == "wheelup" or k == "wheeldown"
      or k == "pageup" or k == "pagedown" or k == "home" or k == "end"
      or (st.pane == "reader" and k == "space") then
      local by = (k == "up" or k == "wheelup" or k == "pageup") and -1 or 1
      if k == "pageup" or k == "pagedown" or k == "space" then by = by * st.rows end
      if st.pane == "files" then
        st.sel = k == "home" and 1 or k == "end" and #st.filtered or st.sel + by
        st.sel = math.max(1, math.min(st.sel, #st.filtered))
        select_file()
      else
        st.top = k == "home" and 0 or k == "end" and st.total or st.top + by
        st.top = math.max(0, math.min(st.top, st.total - st.rows))
      end
    elseif st.pane == "files" then
      if k == "backspace" then st.query = st.query:gsub(CHAR:sub(2, -2) .. "$", "")
      elseif k == "ctrl+u" then st.query = ""
      elseif k == "space" then st.query = st.query .. " "
      elseif k:match(CHAR) then st.query = st.query .. k
      else return false end
      st.sel = 1
      filter()
    else return false end
    return true
  end
  id = bone.ui.popup({ lines = render, on_key = on_key })
  markdown_close = close
  close_event = bone.on("panel/closed", function(ev) if ev.id == id and ev.kind == "popup" then close() end end)
  discover(path)
  return id
end

function M.close()
  if markdown_close then markdown_close() end
end

return M
