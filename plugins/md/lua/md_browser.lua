-- Project Markdown browser; uses Bone popup, Markdown and job APIs. One view
-- for the terminal and the desktop app: the project's Markdown files (type to
-- filter), then the one opened, read as Markdown.
local M = {}

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
  local st = { files = {}, filtered = {}, query = "", sel = 1, pane = "files", loading = true }
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
    st.file = file
    st.text, st.read_error = nil, nil
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
        st.tree = nil
        if bone.ui.update and id then bone.ui.update(id, {}) end
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
          if found then select_file(); st.pane = "reader"; st.tree = nil
          else bone.notify("Markdown file not found: " .. wanted, "error") end
        end
        st.tree = nil
        if bone.ui.update and id then bone.ui.update(id, {}) end
      end,
    })
  end
  local SHOWN = 500 -- files listed at once; filtering finds the rest
  local function touch()
    st.tree = nil
    if bone.ui.update and id then bone.ui.update(id, {}) end
  end
  local function open_file(i)
    st.sel, st.pane = i, "reader"
    select_file()
    touch()
  end
  local function back()
    st.pane = "files"
    touch()
  end
  local function files_view()
    local items = {}
    for i = 1, math.min(#st.filtered, SHOWN) do
      items[i] = { text = (st.filtered[i]:gsub("[%z\1-\31\127]", " ")) }
    end
    local more = #st.filtered - #items
    return {
      kind = "column",
      { kind = "text", text = cwd, tone = "dim", truncate = true },
      st.scan_error and { kind = "text", text = st.scan_error, tone = "warning" } or nil,
      -- Typing filters while the list shows; ↑↓ choose, enter reads.
      { kind = "field", label = "Filter · " .. #st.filtered .. (#st.filtered == 1 and " file" or " files"),
        value = st.query, editing = true, empty = "type to filter" },
      { kind = "list", items = items, selected = math.min(st.sel, math.max(#items, 1)),
        on_select = function(i) st.sel = i; select_file(); touch() end, on_press = open_file,
        empty = st.loading and "Scanning…" or (#st.files == 0 and "No Markdown files." or "No matches.") },
      more > 0 and { kind = "text", text = more .. " more; type to narrow the list", tone = "dim" } or nil,
      { kind = "hints", text = "↑↓ choose · enter read · ctrl+r refresh · esc close" },
    }
  end
  local function reader_view()
    local body
    if st.read_error then
      body = { kind = "text", text = st.read_error, tone = "error" }
    elseif not st.text then
      body = { kind = "text", text = st.file and "Loading document…" or "Select a Markdown file to read.", tone = "dim" }
    elseif st.text == "" then
      body = { kind = "text", text = "Empty Markdown file.", tone = "dim" }
    else
      body = { kind = "markdown", text = st.text }
    end
    return {
      kind = "column",
      { kind = "button", label = "‹ Files", on_press = back },
      { kind = "text", text = st.file or "", tone = "accent", truncate = true },
      body,
      { kind = "hints", text = "↑↓ scroll · tab files · ctrl+r refresh · esc close" },
    }
  end
  -- Built again only when something changed: the terminal draws every frame.
  local function view()
    st.tree = st.tree or (st.pane == "files" and files_view() or reader_view())
    return st.tree
  end
  local function on_key(k)
    if k == "esc" then close(); return true end
    if k == "ctrl+r" then
      local wanted = st.file
      st.file = nil
      read_version = read_version + 1
      cancel(read)
      st.text = nil
      discover(wanted)
    elseif st.pane == "reader" then
      if k ~= "tab" and k ~= "shift+tab" and k ~= "backtab" and k ~= "b" and k ~= "left" then return false end
      st.pane = "files"
    elseif k == "up" or k == "down" or k == "home" or k == "end" or k == "pageup" or k == "pagedown" then
      local by = (k == "up" and -1) or (k == "down" and 1) or (k == "pageup" and -10) or (k == "pagedown" and 10)
        or (k == "home" and -#st.filtered) or #st.filtered
      st.sel = math.max(1, math.min(st.sel + by, math.min(#st.filtered, SHOWN)))
      select_file()
    elseif k == "enter" or k == "tab" then
      if st.filtered[st.sel] then st.pane = "reader"; select_file() end
    else
      local query = bone.text.edit(st.query, k)
      if not query then return false end
      st.query, st.sel = query, 1
      filter()
    end
    touch()
    return true
  end
  -- The desktop window asks for room to read in (a node window is smaller
  -- otherwise); the terminal one keeps fitting its content.
  local gui = bone.has_capability and bone.has_capability("gui.nodes")
  id = bone.ui.popup({ title = "Markdown", view = view, on_key = on_key,
    width = gui and 170 or 100, height = gui and 10000 or nil })
  markdown_close = close
  close_event = bone.on("panel/closed", function(ev) if ev.id == id and ev.kind == "popup" then close() end end)
  discover(path)
  return id
end

function M.close()
  if markdown_close then markdown_close() end
end

return M
