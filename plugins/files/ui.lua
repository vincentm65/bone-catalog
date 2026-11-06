-- Files in a sidebar: the folder this chat works in, what is in it, what
-- this session changed, what Git thinks of it, a search through it, and a
-- text editor. One panel docked at the right, drawn by the terminal and the
-- desktop app alike from the same elements, that keeps its place while you do
-- other things. The patch itself stays /diff's job.

local text = require("files.text")
local kinds = require("files.kinds")
local html = require("files.html")
local linediff = require("files.diff")
local image = require("files.image")
local buffer = require("files.buffer")
local clip = require("files.clip")
local quick = require("files.quick")
local gutter = require("files.gutter")
local fileops = require("files.fileops")
local media = require("files.media")
local extedit = require("files.extedit")

-- The desktop draws the panel with its own look (files.look); a terminal
-- draws the shared elements below.
local GUI = bone.has_capability("gui.window_nodes")
local look = nil
if GUI then
  local ok, mod = pcall(require, "files.look")
  if ok then look = mod else GUI = false end
end

-- A terminal draws the panel as its own lines (files.tlook) unless the
-- tui_look setting asks for the shared elements.
local tlook = nil

local ID = "files"
local HIT_LIMIT = 400     -- the most search hits kept
local ROW_LIMIT = 1500    -- the most rows a folder listing draws
local EDIT_WINDOW = 200   -- the most buffer lines shown at once
local EDIT_PAGE = 50      -- the lines a page key moves the caret: a quarter of that window
local EDIT_COLUMNS = 62   -- columns assumed for a drawn line when the panel says nothing
local EDIT_GUTTER = 2     -- "1234  ", the space after the line number
local PREVIEW_LINES = 600 -- the most lines a preview shows
local CHANGED_LIMIT = 200 -- the most files the Changed pane lists
local UNDO_MAX = 100
local NOTE_MS = 9000      -- how long a note about something that just happened stays

-- The panes. The first three are the tabs; the last two are where a press
-- takes you.
local FILES, SEARCH, CHANGED, PREVIEW, EDIT = "files", "search", "changed", "preview", "edit"
local TAB_NAMES = { "Files", "Search", "Changed" }
local TAB_AT = { [FILES] = 1, [SEARCH] = 2, [CHANGED] = 3 }

local HINTS = {
  [FILES] = "↑↓ move · enter open · p find a file · f filter · s search · c changed"
    .. " · a new file · A new folder · R rename · D duplicate · delete to the Trash"
    .. " · y copy path · ctrl+k add to chat · F follow the agent · e edit · o open outside"
    .. " · r reload · ctrl+h hidden · left up a folder · q close",
  [SEARCH] = "type to search · lowercase matches any case, a capital exactly"
    .. " · enter open the hit · up down through the hits"
    .. " · backspace delete a letter · left back to the folder · right the changed files"
    .. " · esc back · q close",
  [CHANGED] = "↑↓ move · enter go to that file · r reload · esc back · q close",
  [PREVIEW] = "o open outside · e edit · ctrl+k add to chat · v read it again · ctrl+tab next file"
    .. " · ctrl+w close · esc back to the folder",
  [EDIT] = "type to edit · shift+arrows select · ctrl+c ctrl+x ctrl+v · ctrl+a all · ctrl+f find"
    .. " · ctrl+l go to line · ctrl+k add to chat · ctrl+s save · ctrl+z undo · ctrl+y redo"
    .. " · ctrl+g changes · alt+m Markdown · ctrl+tab next file · ctrl+w close · ctrl+p find a file"
    .. " · esc back to the folder",
}

--- What /config can change for this plugin; manifest.json declares the page.
local function setting(key, default)
  local ok, value = pcall(bone.settings.get, "files." .. key)
  if ok and value ~= nil then return value end
  return default
end

local SETTINGS = {
  width = (tonumber(setting("width", 50)) or 50) / 100,
  preview_limit = tonumber(setting("preview_limit", 256)) or 256,
  mark_changes = setting("mark_changes", true) and true or false,
  show_git = setting("show_git", true) and true or false,
  autorefresh = setting("autorefresh", true) and true or false,
  follow = setting("follow_agent", false) and true or false,
  link_files = setting("link_files", true) and true or false,
  tui_look = tostring(setting("tui_look", "drawn")),
  -- built-in | nvim | vim | custom (editor_command, with {file} and {line})
  editor = tostring(setting("editor", "built-in")),
  editor_command = tostring(setting("editor_command", "")),
}
if not GUI and SETTINGS.tui_look ~= "elements" then
  local ok, mod = pcall(require, "files.tlook")
  if ok then tlook = mod end
end

--- A single quote around a path or a term, for the shell.
local function quoted(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

--- The hash of a text, for telling one read of a file from the next.
local function hash_of(body)
  local ok, hash = pcall(bone.sha256, body)
  if ok and hash then return hash end
  return nil
end

--- Trim, and keep a message to one short line.
local function brief(value, longest)
  local clean = tostring(value or ""):gsub("[\r\n\t]+", " "):match("^%s*(.-)%s*$") or ""
  if #clean > (longest or 200) then clean = clean:sub(1, longest or 200) .. "…" end
  return clean
end

-- ---- paths ----------------------------------------------------------------

local function join(dir, name)
  if dir == "" then return name end
  if dir:sub(-1) == "/" then return dir .. name end
  return dir .. "/" .. name
end

--- The folder above `dir`.
local function parent(dir)
  if dir == "/" or dir == "" then return dir end
  local clean = dir:gsub("/+$", "")
  local up = clean:match("^(.*)/[^/]+$")
  if not up or up == "" then return "/" end
  return up
end

--- Where the sidebar starts: the conversation's own directory.
local function home()
  local ok, session = pcall(function() return bone.chat.session() end)
  if ok and type(session) == "table" and session.cwd and session.cwd ~= "" then
    return session.cwd
  end
  return os.getenv("HOME") or "/"
end

--- `path` as an absolute one (what the tools want).
local function absolute(path)
  path = tostring(path or ""):match("^%s*(.-)%s*$")
  if path == "" then return home() end
  if path == "~" then
    path = os.getenv("HOME") or "/"
  elseif path:sub(1, 2) == "~/" then
    path = (os.getenv("HOME") or "/") .. path:sub(2)
  end
  if path:sub(1, 1) ~= "/" then path = join(home(), path) end
  return path
end

local name_of -- a path's last part
name_of = function(path)
  return tostring(path or ""):match("([^/]+)$") or tostring(path or "")
end

-- ---- what the sidebar holds ------------------------------------------------

-- The listing: the tree as one flat list of rows (so one selection covers
-- expanded folders), which folders are open, and each folder read at most
-- once. `rows` holds the tree, or the hits while search is on.
local listing = {
  root = "",
  rows = {},
  open = {},
  read = {},
  selected = 1,
  selected_key = nil,
  changed_selected = 1,
  hit_selected = 1,  -- the search keeps its own: the tree re-reads under it
  hidden = false,
  truncated = false,
  marks = {},        -- a path -> { tool, at, writes }: what the agent changed
  git = {},          -- a path -> "M", "?", "A" …: what Git says
  git_state = "off", -- off | loading | done | none (not a repository)
  query = "",
  filter = "",       -- the tree's own filter: names that hold it, and the folders above them
  ignored = {},      -- a path -> true: what .gitignore keeps out (folders whole)
  search_state = "off",
  note = nil,
  error = nil,
}

--- A path the way the sidebar writes it: ~ for the home folder.
local function display(path)
  local house = home()
  if house ~= "" and house ~= "/" and path:sub(1, #house) == house then
    return "~" .. path:sub(#house + 1)
  end
  return path
end

--- A path inside the folder being shown, as that folder's own relative one.
local function relative(path)
  local root = listing.root
  if root ~= "/" and path:sub(1, #root + 1) == root .. "/" then return path:sub(#root + 2) end
  return path
end

--- A file's bytes as one short word, for the right edge of a row. Rows are
--- not lined up by it: it says how big, not how big exactly.
local function size_of(bytes)
  bytes = tonumber(bytes)
  if not bytes then return nil end
  if bytes < 1024 then return tostring(bytes) .. " B" end
  if bytes < 1048576 then return string.format("%.1f KB", bytes / 1024) end
  return string.format("%.1f MB", bytes / 1048576)
end

--- A file's size, where the panel has read its folder already: nil elsewhere
--- (a search can reach a file the tree never opened).
local function size_at(path)
  local entries = listing.read[parent(path)]
  if not entries then return nil end
  local leaf = path:match("[^/]+$")
  for _, entry in ipairs(entries) do
    if entry.name == leaf then return entry.size end
  end
  return nil
end

-- What a file was last read as, so previewing it again reads it once:
-- a path -> { kind, hash, body, note }.
local preview_cache = {}

local preview = { path = "", name = "", kind = "", body = nil, note = nil,
  error = nil, hash = nil, stale = nil, loading = false }

-- The buffer the editor holds: the file it has open, and what was done to it.
local editor = {
  path = "", lines = { "" }, trailing = false, original = "", disk_hash = nil,
  line = 1, col = 0, dirty = false, conflict = false, saving = false, confirm = false,
  shown = "buffer", -- buffer | changes | markdown: what stands in place of the text
  status = nil, error = nil,
  undo = {}, redo = {}, undo_kind = nil, undo_row = nil,
  diff_key = nil, diff_rows = nil, diff_summary = nil,
}

-- What the entries of a pane stand for, so a press can find them.
local hit_rows, changed_rows, edit_rows = {}, {}, {}
-- The search's own messages: `build` already prints the folder's note above
-- every pane, so the search pane keeps its own and says it once.
local search_note, search_error

-- The files open in the panel, as tabs: { kind = "edit", ed = <an editor> }
-- or { kind = "preview", path, name }. `editor` is the shown tab's editor.
local docs, doc_at = {}, 0
local DOC_LIMIT = 20
-- What the panel shows over everything else, one at a time: quick open
-- (quick_on), a name being asked for (ask), a menu (menu). The new functions
-- live in `act`, so the chunk keeps room for its locals.
local act = { following = SETTINGS.follow }
local SESSION = "files-session" -- what the panel holds, kept for a reload (bone.state)
local quick_on, quick_q, quick_sel = false, "", 1
local ask, menu = nil, nil

local pane = FILES
-- The column of files' own tab, kept while a file has the keys, and the
-- file that is open: nil, "edit" or "preview". The desktop shows the file
-- beside the column; a terminal shows whichever has the keys.
local side = FILES
local doc = nil
local panel, shown, shown_columns
local git_job, git_generation = nil, 0
local search_job, search_generation = nil, 0
local watcher = 0
local note_generation = 0

-- Forward: the panes, the keys and the panel reach each other.
local move, go_up, activate, reveal, open_preview, open_hit, open_editor, open_externally
local set_pane, open_folder, close_panel, size_for, title_for, ask_hash, load_preview
local fetch_marks, fetch_git, run_search, catch_up, build_rows, redraw, open
local note, enter_search, reveal_cursor, open_file, close_doc, chrome

--- Draw the sidebar from the current state next time it is asked for a view.
redraw = function()
  shown = nil
  act.gen = (act.gen or 0) + 1
  if act.save_soon then act.save_soon() end
  -- The desktop builds its view again on a key or a click by itself; what
  -- lands later (a search, git status, a read) has to say so.
  if GUI then pcall(bone.gui.invalidate) end
end

--- What a panel update carries: its size, and in a terminal its title (the
--- desktop draws its own header).
chrome = function()
  return { size = size_for(), title = (not GUI and not tlook) and title_for() or nil }
end

--- Put the cursor the frontends keep back under the pane's own first row.
--- They number the pressable things of the tree they last drew and the arrows
--- walk through those numbers; the three tabs are pressable (that is what
--- makes them clickable) and they are the only pressable thing above a pane,
--- so the row just after them is where this pane's list begins — and the
--- elements snap it from there to the row the pane has selected. Left alone,
--- a pane whose list is empty has no row to move the cursor to, so it stays
--- on a tab: the folder pane drawn with Search looking chosen, and ↑↓ moving
--- the panes instead of the files.
reveal_cursor = function()
  if not (panel and panel:is_open()) then return end
  local st = require("bone.elements").state("panel:" .. ID)
  local list = st and st.targets
  if not list then return end
  local tabs = 0
  for n, t in ipairs(list) do
    if t.el and t.el.kind == "tabs" then tabs = n end
  end
  st.cursor = tabs + 1
end

--- A word about something that just happened. It clears itself: a note from
--- three folders ago should not still be sitting at the top of the panel.
note = function(text)
  listing.note = text
  note_generation = note_generation + 1
  local token = note_generation
  bone.defer(NOTE_MS, function()
    if token == note_generation and listing.note == text then
      listing.note = nil
      redraw()
    end
  end)
end

--- Stop a running job, so a refresh never races the one it replaces.
local function stop_job(which)
  if which == "search" then
    search_generation = search_generation + 1
    local previous = search_job
    search_job = nil
    if previous then previous:cancel() end
  else
    git_generation = git_generation + 1
    local previous = git_job
    git_job = nil
    if previous then previous:cancel() end
  end
end

--- Ask the core what a file holds on disk now: its hash and size. This is how
--- the sidebar notices a file moved under it — the core is the one doing most
--- of the writing.
ask_hash = function(path, done)
  bone.rpc.call("files.hash", { path = path }, function(result, err)
    if result and result.hash then return done(result, nil) end
    local why = (result and result.error)
      or (err and (type(err) == "table" and err.message or tostring(err)))
      or "The file could not be read."
    return done(nil, why)
  end)
end

-- ---- the folder tree -------------------------------------------------------

--- The bytes of a folder's files, asked in one pass. `find` reports them
--- without opening anything — and not opening is the point: a named pipe would
--- hold an open for good, and nothing a plugin can do would undo that. The
--- numbers land a moment after the rows, which say nothing about size until
--- they are there; comparing the reading this job was started for with the one
--- the panel holds now is how a reading `r` threw away is told from this one.
local function read_sizes(dir, entries)
  -- GNU find says sizes itself; macOS's BSD tools ask stat.
  local cmd = require("files.platform").mac
    and "find . -maxdepth 1 -type f -exec stat -f '%z%t%N' {} +"
    or "find . -maxdepth 1 -type f -printf '%s\t%p\n'"
  bone.job.start(cmd,
    { name = "files: sizes", cwd = dir, timeout = 5000, buffer = true,
      on_exit = function(result)
        if listing.read[dir] ~= entries or not panel or not panel:is_open() then return end
        local bytes = {}
        for line in (result and result.stdout or ""):gmatch("[^\n]+") do
          local size, name = line:match("^(%d+)\t%./(.+)$")
          if size then bytes[name] = tonumber(size) end
        end
        local any = false
        for _, entry in ipairs(entries) do
          entry.size = bytes[entry.name]
          any = any or entry.size ~= nil
        end
        if any then build_rows(false) redraw() end
      end })
end

--- What is in `dir`, folders first: read once and kept, so expanding a folder
--- again is free and `r` is what throws the readings away.
local function read_dir(dir, force)
  local held = listing.read[dir]
  if held and not force then return held end
  local list, err = bone.fs.list(dir)
  if not list then return nil, tostring(err or ("cannot read " .. dir)) end
  local entries, files = {}, false
  for _, entry in ipairs(list) do
    if listing.hidden or entry.name:sub(1, 1) ~= "." then
      entries[#entries + 1] = { name = entry.name, type = entry.type }
      files = files or entry.type == "file"
    end
  end
  table.sort(entries, function(a, b)
    if a.type ~= b.type then return a.type == "dir" end
    return a.name:lower() < b.name:lower()
  end)
  listing.read[dir] = entries
  if files then read_sizes(dir, entries) end
  return entries, nil
end

--- The filter over every file under the folder (paths relative to it): the
--- files and folders whose name holds `needle`, under the folders that hold
--- them, folders first, as the tree orders them.
function act.sift_all(needle, files)
  local root = { dirs = {}, files = {} }
  local any = false
  local hiding = not listing.hidden
  for _, rel in ipairs(files) do
    if not (hiding and (rel:sub(1, 1) == "." or rel:find("/.", 1, true))) then
      local parts = {}
      for part in rel:gmatch("[^/]+") do parts[#parts + 1] = part end
      -- The deepest part of the path whose name holds the letters.
      local last = 0
      for i, part in ipairs(parts) do
        if part:lower():find(needle, 1, true) then last = i end
      end
      if last > 0 then
        any = true
        local node = root
        for i = 1, last - 1 do
          node.dirs[parts[i]] = node.dirs[parts[i]] or { dirs = {}, files = {} }
          node = node.dirs[parts[i]]
        end
        local name = parts[last]
        if last == #parts then
          node.files[name] = true
        else
          node.dirs[name] = node.dirs[name] or { dirs = {}, files = {}, hit_only = true }
        end
      end
    end
  end
  local rows, cut = {}, false
  if not any then return rows, cut end
  local ignored = listing.ignored
  local function walk(node, dir, depth)
    local names = {}
    for name in pairs(node.dirs) do names[#names + 1] = name end
    table.sort(names, function(a, b) return a:lower() < b:lower() end)
    for _, name in ipairs(names) do
      if #rows >= ROW_LIMIT then cut = true return end
      local path = join(dir, name)
      local s, e = name:lower():find(needle, 1, true)
      local child = node.dirs[name]
      local has = next(child.dirs) ~= nil or next(child.files) ~= nil
      rows[#rows + 1] = { type = "dir", name = name, path = path, depth = depth, ignored = ignored[path] or false,
        hit = s and { s, e } or nil, unfolded = has }
      walk(child, path, depth + 1)
    end
    local leaves = {}
    for name in pairs(node.files) do leaves[#leaves + 1] = name end
    table.sort(leaves, function(a, b) return a:lower() < b:lower() end)
    for _, name in ipairs(leaves) do
      if #rows >= ROW_LIMIT then cut = true return end
      local path = join(dir, name)
      local s, e = name:lower():find(needle, 1, true)
      rows[#rows + 1] = { type = "file", name = name, path = path, depth = depth, size = size_at(path),
        hit = s and { s, e } or nil }
    end
  end
  walk(root, listing.root, 0)
  return rows, cut
end

--- Keep the same file under the cursor while the tree changes shape.
local function restore_selection()
  if listing.selected_key then
    for i, row in ipairs(listing.rows) do
      if row.path == listing.selected_key then
        listing.selected = i
        return
      end
    end
  end
  listing.selected = math.max(1, math.min(listing.selected, math.max(#listing.rows, 1)))
  local row = listing.rows[listing.selected]
  listing.selected_key = row and row.path or nil
end

--- The tree as the keys see it: one flat list of rows, a folder's children
--- straight after it while it is open.
build_rows = function(force)
  if force then listing.read = {} end
  local rows, error, cut = {}, nil, false
  -- Only the folders you opened are walked, and the row cap stops the walk:
  -- that is the limit, so no folder is out of reach because of how deep it
  -- sits. The readings are cached, so a folder is listed once.
  -- What .gitignore keeps out is still listed, dimmed: a folder it names
  -- dims everything in it.
  local ignored = listing.ignored
  local function walk(dir, depth, dim)
    if #rows >= ROW_LIMIT then
      cut = true
      return
    end
    local entries, err = read_dir(dir, false)
    if not entries then
      error = error or err
      return
    end
    for _, entry in ipairs(entries) do
      local path = join(dir, entry.name)
      local off = dim or ignored[path] or false
      rows[#rows + 1] = { type = entry.type, name = entry.name, path = path, depth = depth,
        size = entry.size, ignored = off }
      if entry.type == "dir" and listing.open[path] then
        walk(path, depth + 1, off)
      end
    end
  end
  -- With a filter, the folders read so far are looked through, open or not:
  -- what holds the letters, and the folders on the way to it, opened.
  local needle = listing.filter:lower()
  local function sift(dir, depth, dim)
    local entries = listing.read[dir]
    if not entries and depth == 0 then
      local err
      entries, err = read_dir(dir, false)
      if not entries then error = error or err return {} end
    end
    local out = {}
    for _, entry in ipairs(entries or {}) do
      local path = join(dir, entry.name)
      local off = dim or ignored[path] or false
      local s, e = entry.name:lower():find(needle, 1, true)
      local below = (entry.type == "dir" and listing.read[path]) and sift(path, depth + 1, off) or {}
      if s or #below > 0 then
        out[#out + 1] = { type = entry.type, name = entry.name, path = path, depth = depth,
          size = entry.size, ignored = off, hit = s and { s, e } or nil, unfolded = #below > 0 }
        for _, r in ipairs(below) do out[#out + 1] = r end
      end
      if #out >= ROW_LIMIT then cut = true break end
    end
    return out
  end
  if needle ~= "" then
    -- The whole folder when its file list is there (quick open's, from
    -- ripgrep); the folders read so far while it is being read.
    local held = quick.listing(listing.root)
    if held and held.files and #held.files > 0 then
      rows, cut = act.sift_all(needle, held.files)
    else
      rows = sift(listing.root, 0, false)
    end
    if not held or held.loading or (held.at or 0) == 0 then
      quick.load(listing.root, function()
        if listing.filter ~= "" then build_rows() redraw() end
      end)
    end
  else
    walk(listing.root, 0, false)
  end
  local was_cut = listing.truncated
  listing.rows = rows
  listing.error = error
  listing.truncated = cut
  -- An expansion that ran into the row cap says so, instead of doing nothing.
  if cut and not was_cut then note(ROW_LIMIT .. " rows is as deep as this goes") end
  restore_selection()
  return rows
end

--- What the agent changed a path as, or nil.
local function mark_of(path)
  return listing.marks[path]
end

--- Git's two-character opinion about a path, shown as one letter.
local function sign_of(path)
  return listing.git[path]
end

--- Is this file, or a folder above it, one of the dotfiles the tree keeps out
--- unless ctrl+h asks for them? The Changed pane obeys the same rule.
local function hidden_path(path)
  return path:match("/%.") ~= nil or name_of(path):sub(1, 1) == "."
end

--- The marks an entry carries: this session's write, or Git's own letter.
local function badges_of(path)
  local out = {}
  local mark = mark_of(path)
  if mark then
    out[#out + 1] = { text = (mark.writes or 1) > 1 and ("edited ×" .. mark.writes) or "edited",
      tone = "warning" }
  end
  local sign = sign_of(path)
  if sign and not mark then
    out[#out + 1] = { text = sign,
      tone = (sign == "?" or sign == "A") and "success" or "warning" }
  end
  return #out > 0 and out or nil
end

move = function(by)
  local count = #listing.rows
  if count == 0 then return end
  listing.selected = math.max(1, math.min(count, listing.selected + by))
  local row = listing.rows[listing.selected]
  listing.selected_key = row and row.path or nil
end

--- Close the deepest open folder, so the tree goes back the way it came.
go_up = function()
  local deepest, depth
  for _, row in ipairs(listing.rows) do
    if row.type == "dir" and listing.open[row.path] and (not depth or row.depth > depth) then
      deepest, depth = row, row.depth
    end
  end
  if not deepest then return false end
  listing.open[deepest.path] = nil
  build_rows()
  for i, row in ipairs(listing.rows) do
    if row.path == deepest.path then
      listing.selected = i
      break
    end
  end
  listing.selected_key = deepest.path
  return true
end

--- Show `dir`: a fresh reading of it, the session's changed files, and Git's
--- opinion of it.
open_folder = function(dir)
  stop_job("search")
  listing.root = dir
  listing.query, listing.search_state = "", "off"
  listing.open, listing.read = {}, {}
  listing.selected, listing.selected_key = 1, nil
  listing.note, listing.error = nil, nil
  search_note, search_error = nil, nil
  hit_rows, changed_rows = {}, {}
  build_rows()
  set_pane(FILES)
  reveal_cursor()
  fetch_marks()
  fetch_git()
  if panel and panel:is_open() then panel:update(chrome()) end
  redraw()
end

-- ---- what the core knows, and what Git knows -------------------------------

--- The files this session's agent wrote, from the core: what the tree marks,
--- and what the editor refuses to overwrite unnoticed.
fetch_marks = function()
  if not SETTINGS.mark_changes then return end
  bone.rpc.call("files.touched", {}, function(result)
    if not result or not result.paths then return end
    local marks = {}
    for _, entry in ipairs(result.paths) do
      if entry.path then marks[entry.path] = entry end
    end
    listing.marks = marks
    act.follow(result.paths)
    redraw()
  end)
end

--- Git's own list of what is changed and what is new: untracked files, and
--- where each one sits in this folder. Run from the repository's own root so
--- the paths it prints are the ones this folder holds; the first line of its
--- output is that root.
fetch_git = function()
  if not SETTINGS.show_git then return end
  stop_job("git")
  listing.git_state = "loading"
  redraw()
  local token = git_generation
  git_job = bone.job.start(
    'root=$(git --no-pager rev-parse --show-toplevel 2>/dev/null) || exit 1\n'
      .. 'printf "%s\\n" "$root"\n'
      .. 'git --no-pager -C "$root" status --porcelain=v1 --untracked-files=all --ignored=matching',
    { name = "files: git status", cwd = listing.root, timeout = 6000, buffer = true,
      on_exit = function(result)
        if token ~= git_generation or not panel or not panel:is_open() then return end
        git_job = nil
        local status, known = {}, result and result.code == 0
        local ignored = {}
        if known then
          local root = ""
          for line in (result.stdout or ""):gmatch("[^\n]+") do
            if root == "" then
              root = line:gsub("/+$", "")
            elseif line:sub(1, 2) == "!!" then
              local path = line:sub(4):gsub("/+$", "")
              ignored[(root == "" and path or root .. "/" .. path)] = true
            else
              local code, path = line:sub(1, 2), line:sub(4)
              if code:match("R") then path = path:match("%->%s*(.+)$") or path end
              if path and path ~= "" then
                status[(root == "" and path or root .. "/" .. path)] =
                  (code:match("^#") and "?") or code:match("%S")
              end
            end
          end
        end
        listing.git, listing.git_state = status, known and "done" or "none"
        listing.ignored = ignored
        build_rows()
        redraw()
      end })
end

-- ---- searching the folder --------------------------------------------------

--- A search through this folder: ripgrep when it is installed, grep when it is
--- not. Its hits become rows, so the same keys move through them.
run_search = function(term)
  stop_job("search")
  listing.query, listing.search_state = term, "loading"
  hit_rows, listing.hit_selected = {}, 1
  search_note, search_error = nil, nil
  set_pane(SEARCH)
  redraw()
  local token = search_generation
  -- The same rule as the tree: dotfiles are looked into only when hidden
  -- files are being shown.
  local peeking = listing.hidden
  -- ripgrep's smart case: an all-lowercase term matches any case, a term with
  -- a capital in it is matched exactly. grep has no such thing, so it gets -i
  -- only for an all-lowercase term.
  local exact = term:match("%u") ~= nil
  search_job = bone.job.start(
    "if command -v rg >/dev/null 2>&1; then "
      .. "rg --line-number --no-heading --color=never --smart-case "
      .. (peeking and "--hidden " or "") .. "--glob '!.git' "
      .. "--max-columns 240 --max-columns-preview -- " .. quoted(term) .. "; "
      .. "else grep -rn -I" .. (exact and "" or " -i") .. " --exclude-dir=.git "
      .. (peeking and "" or "--exclude='.*' --exclude-dir='.*' ")
      .. "-- " .. quoted(term) .. "; fi",
    { name = "files: search", cwd = listing.root, timeout = 15000, buffer = true,
      on_exit = function(result)
        if token ~= search_generation or not panel or not panel:is_open() then return end
        search_job = nil
        local rows = {}
        for line in (result and result.stdout or ""):gmatch("[^\n]+") do
          local path, num, rest = line:match("^([^:\n]+):(%d+):(.*)$")
          if path then
            rows[#rows + 1] = { name = path, path = join(listing.root, path),
              line = tonumber(num), text = brief(rest, 160) }
            if #rows >= HIT_LIMIT then break end
          end
        end
        hit_rows = rows
        listing.search_state = #rows > 0 and "done" or "empty"
        if not result then
          search_error = "the search did not run"
        elseif (result.code or 1) > 1 then
          search_error = brief(result.stderr or "the search failed")
        elseif #rows == 0 then
          search_note = "Nothing here matches “" .. term .. "”."
        elseif #rows >= HIT_LIMIT or result.truncated then
          search_note = "The first " .. HIT_LIMIT .. " hits."
        end
        redraw()
      end })
end

--- Typing a search: it runs a moment after the last letter stops, so typing a
--- whole word costs one search rather than one per letter.
local function schedule_search()
  search_generation = search_generation + 1
  local token = search_generation
  bone.defer(240, function()
    if token ~= search_generation or listing.query == "" then return end
    run_search(listing.query)
  end)
end

--- Start a search afresh: an empty field, and none of the last one's hits.
enter_search = function()
  stop_job("search")
  listing.query, listing.search_state = "", "off"
  hit_rows, search_note, search_error = {}, nil, nil
  listing.hit_selected = 1
  set_pane(SEARCH)
  -- A field takes the keyboard by itself only the first time it is drawn;
  -- every later search asks for it, once the field is there again.
  if GUI then
    redraw()
    bone.defer(30, function() pcall(bone.gui.focus, "files:search") end)
  end
end

--- Leave search and show the folder again.
local function exit_search()
  stop_job("search")
  listing.query, listing.search_state = "", "off"
  listing.note, listing.error = nil, nil
  search_note, search_error = nil, nil
  hit_rows = {}
  build_rows()
  set_pane(FILES)
  redraw()
end

--- Move the sidebar to one of the changed files, even when it is not in the
--- folder being shown: what pressing a name in Changed does.
reveal = function(path)
  stop_job("search")
  listing.query, listing.search_state, hit_rows = "", "off", {}
  search_note, search_error = nil, nil
  local root = listing.root
  if path:sub(1, #root + 1) ~= root .. "/" then root = parent(path) end
  listing.root, listing.read = root, {}
  listing.chosen = true
  listing.open = { [root] = true }
  local dir = parent(path)
  while dir and dir ~= root and dir ~= "" and dir ~= "/" do
    listing.open[dir] = true
    local up = parent(dir)
    if up == dir then break end
    dir = up
  end
  listing.selected_key = path
  build_rows()
  side = FILES
  if panel and panel:is_open() then panel:update(chrome()) end
  open_file(path)
end

-- ---- the file itself -------------------------------------------------------

--- A PDF's pages as pictures, for the desktop: Ghostscript draws the first
--- twenty into a cache folder named by the file's own hash, so the same file
--- is drawn once and a changed one is drawn again. The forty folders used last
--- are kept. No Ghostscript, and the preview stays the PDF's text.
local PAGE_LIMIT = 20 -- pages drawn at a time
local pages_held = {}  -- a path -> { pages, ended }
local function render_pages(path, batch)
  batch = batch or 1
  local base = (os.getenv("XDG_CACHE_HOME") or ((os.getenv("HOME") or "/tmp") .. "/.cache")) .. "/bone/files-pdf2"
  local held = pages_held[path]
  if held and batch == 1 then
    preview.pages, preview.pages_state, preview.pages_ended = held.pages, "done", held.ended
    return
  end
  if batch == 1 then preview.pages_state = "rendering" else preview.pages_more = "rendering" end
  local first, last = (batch - 1) * PAGE_LIMIT + 1, batch * PAGE_LIMIT
  local tag = string.format("%02d", batch)
  -- Each run draws twenty pages into the file's folder (named by its hash),
  -- p<run>-<page>.png; a run that draws fewer than twenty marks the end.
  local script = "f=" .. quoted(path) .. "; base=" .. quoted(base) .. "; "
    .. "command -v gs >/dev/null 2>&1 || exit 3; "
    .. "k=$(" .. require("files.platform").sha256_of_f() .. " | cut -c1-24) || exit 4; d=\"$base/$k\"; mkdir -p \"$d\" || exit 5; "
    .. "if [ ! -e \"$d/.done-" .. tag .. "\" ]; then rm -f \"$d\"/p" .. tag .. "-*.png; "
    .. "gs -q -dSAFER -dBATCH -dNOPAUSE -sDEVICE=png16m -r144 -dTextAlphaBits=4 -dGraphicsAlphaBits=4 "
    .. "-dFirstPage=" .. first .. " -dLastPage=" .. last .. " -sOutputFile=\"$d/p" .. tag .. "-%03d.png\" -f \"$f\" >/dev/null 2>\"$d/.err\"; "
    .. "n=$(ls -1 \"$d\" | grep -c '^p" .. tag .. "-'); "
    .. "if [ \"$n\" -eq 0 ] && [ " .. batch .. " -eq 1 ]; then cat \"$d/.err\" >&2; rm -rf \"$d\"; exit 6; fi; "
    .. "[ \"$n\" -lt " .. PAGE_LIMIT .. " ] && touch \"$d/.end\"; touch \"$d/.done-" .. tag .. "\"; fi; "
    .. "touch \"$d\"; (cd \"$base\" && ls -1t | tail -n +41 | xargs -r rm -rf --); "
    .. "echo \"$d\"; [ -e \"$d/.end\" ] && echo END; ls -1 \"$d\" | grep '^p[0-9]' | sort"
  local shown = path
  bone.job.start(script, { name = "files: pdf pages", timeout = 120000, buffer = true,
    on_exit = function(result)
      if preview.path ~= shown then return end
      local out = result and result.stdout or ""
      local dir = out:match("^([^\n]+)")
      preview.pages_more = nil
      if not result or result.code ~= 0 or not dir then
        if batch == 1 then
          preview.pages_state = "failed"
          preview.pdf_view = "text"
        else
          preview.pages_ended = true
        end
        redraw()
        return
      end
      local pages = {}
      for name in out:gmatch("\n(p%d+%-%d+%.png)") do
        local file = dir .. "/" .. name
        local w, h = image.size(file)
        pages[#pages + 1] = { path = file, width = w, height = h }
      end
      local ended = out:find("\nEND\n", 1, true) ~= nil
      preview.pages, preview.pages_state, preview.pages_ended = pages, #pages > 0 and "done" or "failed", ended
      if #pages > 0 then pages_held[path] = { pages = pages, ended = ended } else preview.pdf_view = "text" end
      redraw()
    end })
end

--- The next twenty pages of the PDF shown, when the list nears its end.
function act.more_pages()
  if preview.kind ~= "pdf" or preview.pages_ended or preview.pages_more or not preview.pages then return end
  render_pages(preview.path, math.floor(#preview.pages / PAGE_LIMIT) + 1)
end

--- What the file holds, to show it. Read once and kept: previewing the same
--- file again costs nothing until the file itself changes.
load_preview = function(row)
  local path, kind = row.path, kinds.of(row.name)
  preview = { path = path, name = row.name, kind = kind, loading = false }
  if kind == "gif" or kind == "video" or kind == "model" then
    media.load(preview, redraw)
    return
  end
  if kind == "image" then
    -- The picture's own size, from its header: what a terminal names the
    -- picture by, and what the desktop sizes the drawing to.
    local width, height = image.size(path)
    local detail = (row.name:match("%.(%w+)$") or ""):upper()
    if width and height and width > 0 and height > 0 then
      preview.width, preview.height = width, height
      detail = detail .. " · " .. width .. "×" .. height
    end
    preview.detail = detail ~= "" and detail or nil
    preview.alpha = image.alpha(path)
    preview.note = "An image: press o to open it in the desktop's own viewer."
    return
  end
  if kind == "pdf" then
    if GUI then
      preview.pdf_view = "pages"
      render_pages(path)
    end
    local held = preview_cache[path]
    if held and held.hash then
      preview.kind, preview.hash, preview.body = "pdf", held.hash, held.body
      return
    end
    preview.loading = true
    bone.rpc.call("files.pdftext", { path = path }, function(result, err)
      preview.loading = false
      if result and result.text then
        preview.kind, preview.body = "pdf", result.text
        preview.hash = hash_of(result.text)
        preview_cache[path] = { kind = "pdf", hash = preview.hash, body = preview.body }
      else
        preview.error = (result and result.error)
          or (err and (type(err) == "table" and err.message or tostring(err)))
          or "The PDF could not be read."
      end
      redraw()
    end)
    return
  end
  local held = preview_cache[path]
  if held and held.kind == kind and held.hash then
    preview.kind, preview.hash, preview.body, preview.note, preview.raw = held.kind, held.hash, held.body, held.note, held.raw
    return
  end
  local content, err = text.read(path)
  if not content then
    preview.error = brief(err)
    return
  end
  if text.is_binary(content) then
    preview.error = "This is a binary file: there is nothing to show."
    return
  end
  preview.hash = hash_of(content)
  local body = content
  if #body > SETTINGS.preview_limit * 1024 then
    body = body:sub(1, SETTINGS.preview_limit * 1024)
    preview.note = "The file is large: only its first part is shown."
  end
  if kind == "html" then
    preview.raw = body
    body = html.to_text(body)
  elseif kind == "binary" then
    kind, preview.kind = "code", "code"
  end
  preview.body = body
  preview_cache[path] = { kind = preview.kind or kind, hash = preview.hash,
    body = body, note = preview.note, raw = preview.raw }
end

-- ---- another editor ----------------------------------------------------------

--- Open `path` in the editor the `editor` setting names (Neovim, Vim, a
--- command of your own), in a terminal panel beside this one: true when it
--- did. With the built-in editor chosen, or when it cannot run, false (the
--- caller opens the built-in one; a word says why).
function act.external_open(path, line)
  local kind = SETTINGS.editor
  -- A terminal's setting: the desktop app keeps its own editor.
  if GUI or kind == "built-in" or kind == "" then return false end
  if kind == "custom" and SETTINGS.editor_command:match("^%s*$") then
    note("No editor_command set · using the built-in editor")
    return false
  end
  local ok, why = extedit.open(kind, SETTINGS.editor_command, path, line, function()
    -- The editor has closed: the tree, Git's marks and the sizes again.
    act.ext_on = false
    if listing.note and listing.note:find("^Editing ") then listing.note = nil end
    listing.read[parent(path)] = nil
    preview_cache[path] = nil
    if panel and panel:is_open() then
      build_rows()
      fetch_git()
      fetch_marks()
      panel:update(chrome())
      -- The keys come back here, not to the prompt.
      panel:focus()
    end
    redraw()
  end)
  if not ok then
    note("Could not open it in " .. (extedit.program(kind, SETTINGS.editor_command) or "the editor") .. ": " .. tostring(why)
      .. " · using the built-in editor")
    return false
  end
  act.ext_on = true
  quick.opened(path)
  for n, row in ipairs(listing.rows) do
    if row.path == path then listing.selected, listing.selected_key = n, path break end
  end
  note("Editing " .. name_of(path) .. " in " .. (extedit.program(kind, SETTINGS.editor_command) or "the editor")
    .. " · ctrl+] gives the keys back")
  if panel and panel:is_open() then panel:update(chrome()) end
  redraw()
  return true
end

-- ---- the tabs ---------------------------------------------------------------

--- The tab that holds `path`, or nil.
function act.tab_of(path)
  for i, t in ipairs(docs) do
    if (t.kind == "edit" and t.ed.path == path) or (t.kind == "preview" and t.path == path) then return i end
  end
  return nil
end

--- Show tab `i`: its editor, or its file in the preview.
function act.show_tab(i)
  local t = docs[i]
  if not t then return end
  doc_at = i
  local path
  if t.kind == "edit" then
    editor = t.ed
    doc = "edit"
    path = t.ed.path
    -- A file shown again may have moved while it waited.
    act.check_editor()
  else
    doc = "preview"
    path = t.path
    if preview.path ~= t.path then load_preview({ path = t.path, name = t.name }) end
  end
  for n, row in ipairs(listing.rows) do
    if row.path == path then listing.selected, listing.selected_key = n, path break end
  end
  if panel and panel:is_open() then panel:update(chrome()) end
end

--- A new tab after the one shown; past DOC_LIMIT the oldest one with no
--- unsaved work makes room.
function act.push_tab(entry)
  if #docs >= DOC_LIMIT then
    for i, t in ipairs(docs) do
      if i ~= doc_at and not (t.kind == "edit" and t.ed.dirty) then
        table.remove(docs, i)
        if i < doc_at then doc_at = doc_at - 1 end
        break
      end
    end
  end
  local at = math.min(doc_at + 1, #docs + 1)
  if at < 1 then at = 1 end
  table.insert(docs, at, entry)
  return at
end

--- Close tab `i` (the shown one by default). A tab with unsaved work asks
--- first; `force` does not.
function act.close_tab(i, force)
  i = i or doc_at
  local t = docs[i]
  if not t then return false end
  if t.kind == "edit" and t.ed.dirty and not force and not t.ed.confirm then
    if i ~= doc_at then act.show_tab(i) set_pane(EDIT) end
    t.ed.confirm = true
    t.ed.status = "Unsaved changes · close again to leave them · ctrl+s saves them"
    redraw()
    return true
  end
  table.remove(docs, i)
  if #docs == 0 then
    doc_at, doc = 0, nil
    if pane == EDIT or pane == PREVIEW then set_pane(side) end
  elseif i == doc_at then
    act.show_tab(math.min(i, #docs))
  elseif i < doc_at then
    doc_at = doc_at - 1
  end
  if panel and panel:is_open() then panel:update(chrome()) end
  redraw()
  return true
end

--- The next tab (or with -1 the one before), round.
function act.cycle(dir)
  if #docs < 2 then return end
  local i = ((doc_at - 1 + dir) % #docs) + 1
  act.show_tab(i)
  set_pane(docs[i].kind == "edit" and EDIT or PREVIEW)
  redraw()
end

--- Open a file in the preview pane.
open_preview = function(row)
  local at = act.tab_of(row.path)
  if at and docs[at].kind == "preview" then
    act.show_tab(at)
    if row.fresh then load_preview(row) end
  else
    load_preview(row)
    local entry = { kind = "preview", path = row.path, name = row.name }
    if at then docs[at] = entry else at = act.push_tab(entry) end
    act.show_tab(at)
  end
  quick.opened(row.path)
  set_pane(PREVIEW)
  redraw()
end

--- Open a file: its text straight in the editor; a picture, a PDF or a file
--- with no text in it in the preview. `line` is where the caret starts.
open_file = function(path, line)
  local name = name_of(path)
  local kind = kinds.of(name)
  if kind ~= "image" and kind ~= "pdf" and kind ~= "gif" and kind ~= "video" and kind ~= "model" then
    -- The head of the file says whether it is text: a large binary is not
    -- read whole to find out.
    local file = io.open(path, "rb")
    local head = file and file:read(8192) or ""
    if file then file:close() end
    if file and not text.is_binary(head) then
      if act.external_open(path, line) then return end
      open_editor(path, line)
      return
    end
  end
  open_preview({ path = path, name = name })
end

--- Close the open file (its tab), the second time of asking when it has
--- unsaved work.
close_doc = function()
  if not doc then return false end
  return act.close_tab(doc_at)
end

--- Is the file being shown still what it was when it was read? Asked only
--- after something has been written, so browsing costs nothing.
local function check_preview()
  if not preview.hash or preview.kind == "pdf" then return end
  local wanted = preview
  ask_hash(preview.path, function(found, why)
    if preview ~= wanted then return end
    if not found then
      preview.stale = "gone"
    elseif found.hash ~= preview.hash then
      preview.stale = true
    else
      preview.stale = nil
    end
    redraw()
  end)
end

--- Open the file with the desktop's own app.
open_externally = function()
  local path = preview.path
  if pane ~= PREVIEW and pane ~= EDIT then
    local row = listing.rows[listing.selected]
    path = row and row.type == "file" and row.path or nil
  elseif pane == EDIT then
    path = editor.path
  end
  if not path or path == "" then return end
  note("Opening " .. name_of(path) .. "…")
  redraw()
  bone.rpc.call("files.open", { path = path }, function(result, err)
    if result and result.opened then
      note("Opened " .. name_of(path))
    else
      listing.note = nil
      bone.notify((result and result.error)
        or (err and (type(err) == "table" and err.message or tostring(err)))
        or ("Could not open " .. path), "error")
    end
    redraw()
  end)
end

--- A search hit is the file itself, opened at the line that matched.
open_hit = function(hit)
  if not hit then return end
  open_file(hit.path, hit.line)
end

--- Open what is selected: a folder to expand or close, a file to read.
activate = function(index)
  local row = listing.rows[index]
  if not row then return end
  listing.selected = index
  listing.selected_key = row.path
  if row.type == "dir" then
    local entries, err = read_dir(row.path, false)
    if err then
      listing.error = brief(err)
      redraw()
      return
    end
    -- (not `open and nil or true`: that is always true, so a click never closed one)
    if listing.open[row.path] then listing.open[row.path] = nil else listing.open[row.path] = true end
    build_rows()
  else
    open_file(row.path)
  end
  redraw()
end

-- ---- the editor ------------------------------------------------------------

-- How long a word about what the editor just did stays. The ones you have to
-- act on are not these: the conflict text, a failed save and the
-- unsaved-changes warning live in `editor.error` and the badges, which stay
-- until something answers them.
local status_generation = 0

--- A word about what the editor just did. It clears itself, like a note about
--- the folder: `Saved` from five minutes ago should not still head the pane.
local function editor_note(message)
  editor.status = message
  status_generation = status_generation + 1
  local token = status_generation
  bone.defer(NOTE_MS, function()
    if token == status_generation and editor.status == message then
      editor.status = nil
      redraw()
    end
  end)
end

--- Remember the buffer as it was, so the edit can be taken back (files.buffer
--- keeps the stack).
local function remember(kind, row) buffer.remember(editor, kind, row) end

--- Whether the buffer differs from the file it came from.
local function changed()
  editor.dirty = text.join(editor.lines, editor.trailing) ~= editor.original
end

--- Take the last edit back, or put it back.
local function undo_edit()
  if not buffer.undo(editor) then return editor_note("Nothing to undo") end
  changed()
  editor_note("Undone")
end

local function redo_edit()
  if not buffer.redo(editor) then return editor_note("Nothing to redo") end
  changed()
  editor_note("Redone")
end

local function move_cursor(rows, cols)
  buffer.move(editor, rows, cols, false)
end

--- Write the buffer as the file. The hash taken when the file was opened is
--- checked first: when the file on disk is not that one any more, the agent (or
--- another editor) got there first, and this says so instead of silently
--- writing over it.
local function save_editor(force)
  if editor.saving then return end
  local body = text.join(editor.lines, editor.trailing)
  if body == editor.original and not editor.conflict then
    editor.dirty = false
    editor_note("No changes to save")
    redraw()
    return
  end
  editor.saving = true
  redraw()
  -- The buffer this save is for: one opened since is not written by it.
  local target = editor
  ask_hash(editor.path, function(found, why)
    target.saving = false
    if not panel or not panel:is_open() or editor ~= target or doc ~= "edit" then return end
    if not found and not force then
      editor.conflict = true
      editor.error = "The file is no longer on disk. ctrl+o writes it there again."
      editor.status = "Not saved"
      redraw()
      return
    end
    if found and found.hash ~= editor.disk_hash and not force then
      editor.conflict = true
      editor.error = "The file changed on disk while it was open — the agent, or another editor, wrote it. "
        .. "ctrl+o writes your version over theirs · ctrl+r reads theirs instead · ctrl+g shows the difference."
      editor.status = "Not saved"
      editor.diff_key = nil
      redraw()
      return
    end
    local ok, err = bone.fs.write(editor.path, body)
    if ok then
      editor.original = body
      editor.disk_hash = hash_of(body)
      editor.dirty = false
      editor.conflict = false
      editor.error = nil
      editor_note("Saved")
      editor.diff_key = nil
      preview_cache[editor.path] = nil
      fetch_git()
    else
      editor.error = brief(err or "The file could not be written.")
      editor.status = "Not saved"
    end
    redraw()
  end)
end

--- Read the file again as it is on disk now. What was in the buffer stays in
--- the undo stack, so it is one ctrl+z away.
local function reload_editor()
  local content = text.read(editor.path)
  if not content then
    editor.error = "The file could not be read again."
    editor.status = "Not reloaded"
    redraw()
    return
  end
  remember("reload", editor.line)
  local lines, trailing = text.split(content)
  editor.lines, editor.trailing = lines, trailing
  editor.original = content
  editor.disk_hash = hash_of(content)
  editor.conflict = false
  editor.error = nil
  editor.line = math.min(editor.line, #lines)
  editor.col = math.min(editor.col, #(editor.lines[editor.line] or ""))
  editor.anchor = nil
  editor.version = (editor.version or 0) + 1
  editor.diff_key = nil
  changed()
  editor_note("Read the file as it is on disk now")
  redraw()
end

--- Open a file in the editor pane. `line` (from a search hit) is where the
--- cursor starts; the file's hash is kept so a write cannot land on a file
--- someone else has changed since.
open_editor = function(path, line)
  local at = act.tab_of(path)
  -- The file already open keeps its buffer, unsaved work and all.
  if at and docs[at].kind == "edit" then
    act.show_tab(at)
    if tonumber(line) then
      buffer.place(editor, tonumber(line), #(text.leading(editor.lines[tonumber(line)] or "")))
    end
    set_pane(EDIT)
    redraw()
    return
  end
  local content, err = text.read(path)
  if not content then
    bone.notify("Cannot open " .. path .. ": " .. tostring(err), "error")
    return
  end
  if text.is_binary(content) then
    bone.notify(path .. " is a binary file.", "error")
    return
  end
  local lines, trailing = text.split(content)
  local ed = {
    path = path, lines = lines, trailing = trailing,
    original = content, disk_hash = hash_of(content), conflict = false,
    line = math.max(1, math.min(tonumber(line) or 1, #lines)), col = 0,
    dirty = false, status = nil, error = nil, saving = false, confirm = false,
    shown = "buffer", version = 0, anchor = nil,
    undo = {}, redo = {}, undo_kind = nil, undo_row = nil,
    diff_key = nil, diff_rows = nil, diff_summary = nil,
  }
  if tonumber(line) then ed.col = #(text.leading(lines[ed.line] or "")) end
  -- A page opens as it reads (Preview); the Edit beside it is the text.
  if kinds.of(name_of(path)) == "html" and not tonumber(line) then ed.shown = "html" end
  local entry = { kind = "edit", ed = ed }
  if at then docs[at] = entry else at = act.push_tab(entry) end
  act.show_tab(at)
  quick.opened(path)
  gutter.fetch(ed, redraw)
  set_pane(EDIT)
  listing.note = nil
  if panel and panel:is_open() then panel:update(chrome()) end
  redraw()
end

--- The buffer against the file it came from. Built again only when one side or
--- the other moved.
local function editor_changes()
  local body = text.join(editor.lines, editor.trailing)
  local key = tostring(editor.disk_hash or "") .. "|" .. tostring(hash_of(body) or "")
  if editor.diff_key ~= key then
    editor.diff_key = key
    local before, after = text.split(editor.original), text.split(body)
    editor.diff_rows = linediff.rows(before, after)
    editor.diff_summary = linediff.summary(before, after)
  end
  return editor.diff_rows, editor.diff_summary
end

-- ---- the panes -------------------------------------------------------------

-- Whether the panel has the keyboard: esc hands it to the prompt while the
-- panel stays open, and nothing else about it changes, so the top row says
-- when it does not. nil: the frontend did not say.
local keys_here = true

local function top_row()
  local row = { kind = "row" }
  -- The panel's own title already names the folder, leaf and all: this says
  -- the rest of the path, when there is a rest to say.
  local whole = display(listing.root)
  if whole ~= (whole:match("[^/]+/?$") or whole) then
    row[#row + 1] = { kind = "text", text = whole, tone = "dim", truncate = true }
  end
  if listing.git_state == "loading" then
    row[#row + 1] = { kind = "spinner" }
  elseif listing.git_state == "none" then
    row[#row + 1] = { kind = "badge", text = "not a Git folder", tone = "dim" }
  elseif listing.git_state == "done" and next(listing.git) == nil then
    row[#row + 1] = { kind = "badge", text = "Git: nothing changed", tone = "dim" }
  end
  if listing.hidden then row[#row + 1] = { kind = "badge", text = "hidden shown", tone = "dim" } end
  if keys_here == false then
    row[#row + 1] = { kind = "badge", text = "keys: prompt", tone = "dim" }
  end
  -- A Git folder with changes in it has nothing to add here: the panel does
  -- not carry a line for nothing.
  if #row == 0 then return nil end
  return row
end

--- What choosing tab `i` means: the pane, and what that pane needs from the
--- core before it can be drawn.
local function select_tab(i)
  if i == 2 then
    enter_search()
  elseif i == 3 then
    fetch_marks()
    fetch_git()
    set_pane(CHANGED)
  else
    stop_job("search")
    listing.query, listing.search_state = "", "off"
    build_rows()
    set_pane(FILES)
  end
  redraw()
end

local function tabs_row()
  return { kind = "tabs", names = TAB_NAMES, current = TAB_AT[pane],
    on_select = select_tab,
    -- The tabs are pressable, so up out of a list lands the cursor on one.
    -- There, left and right mean the panes: this is where they are answered,
    -- rather than left to the tabs row's own idea of the same keys, because
    -- answering them here is what also puts the cursor back on the new pane's
    -- rows. Past the left end of Files, left is the folder above, as the
    -- hints say.
    on_key = function(key)
      if key ~= "left" and key ~= "right" then return false end
      local to = (TAB_AT[pane] or 1) + (key == "left" and -1 or 1)
      if to >= 1 and to <= #TAB_NAMES then
        select_tab(to)
        return true
      end
      if key == "left" and pane == FILES then
        if not go_up() then
          local up = parent(listing.root)
          if up ~= listing.root then
            listing.chosen = true
            open_folder(up)
          end
        end
        redraw()
      end
      return true
    end }
end

--- The folder tree, marked with what this session wrote and what Git says.
local function tree_pane(columns)
  local gui = bone.has_capability("gui.window_nodes")
  local items = {}
  for i, row in ipairs(listing.rows) do
    -- Where a row hangs in the tree is its depth, and the frontends indent
    -- it. A folder's chevron leads its name; a file's name starts two cells
    -- in, so every name at a depth begins in the same column.
    local label = (row.type == "dir"
      and (listing.open[row.path] and "▾ " or "▸ ") or "  ") .. row.name
    local badges = badges_of(row.path)
    local detail = row.type == "file" and size_of(row.size) or nil
    -- The terminal puts the size at the row's far edge itself, as the
    -- desktop's renderer already does: the room in between is spaces. The
    -- widths counted are the renderer's: two cells a depth, two before the
    -- detail, and each badge as " [text]".
    if detail and not gui then
      local used = row.depth * 2 + bone.text.width(label) + 2 + bone.text.width(detail)
      for _, b in ipairs(badges or {}) do
        used = used + 3 + bone.text.width(tostring(b.text or ""))
      end
      if columns - used > 0 then detail = string.rep(" ", columns - used) .. detail end
    end
    items[i] = {
      text = label,
      depth = row.depth,
      tone = row.ignored and "dim" or (row.type == "dir" and "accent" or "normal"),
      badges = badges,
      -- What the name cannot say, at the row's other end.
      detail = detail,
    }
  end
  local rows_list = { kind = "list", items = items,
    selected = math.max(1, math.min(listing.selected, math.max(#items, 1))),
    empty = listing.error or "Nothing here." }
  -- The cursor the frontends move lives here, so the tree they were drawn
  -- from has to say the same thing.
  rows_list.on_select = function(i)
    listing.selected, rows_list.selected = i, i
    local row = listing.rows[i]
    listing.selected_key = row and row.path or nil
  end
  rows_list.on_press = function(i) activate(i) end
  local out = { kind = "column" }
  if listing.filter_typing or listing.filter ~= "" then
    out[#out + 1] = { kind = "field", label = "Filter", value = listing.filter, editing = listing.filter_typing,
      on_press = function() listing.filter_typing = true redraw() end, empty = "names that hold…",
      hint = "names in the whole folder · enter keeps it · esc clears it · p finds a file by its path" }
  end
  out[#out + 1] = rows_list
  if listing.truncated then
    out[#out + 1] = { kind = "text", tone = "dim",
      text = "⋮ " .. ROW_LIMIT .. " rows is as deep as this goes." }
  end
  return out
end

--- The search box and its hits.
local function search_pane()
  local state = "type a word to search inside these files…"
  if listing.search_state == "loading" then
    state = "searching…"
  elseif listing.search_state == "empty" then
    state = "nothing here matches it"
  elseif listing.search_state == "done" then
    state = #hit_rows .. " hits"
  end
  local items = {}
  for i, hit in ipairs(hit_rows) do
    -- The line that matched is the one you scan for; where it came from is
    -- the same for a run of hits, so it sits at the row's other end.
    items[i] = { text = hit.text, tone = "normal",
      detail = hit.name .. ":" .. tostring(hit.line or "") }
  end
  local hits = { kind = "list", items = items,
    selected = math.max(1, math.min(listing.hit_selected, math.max(#items, 1))),
    empty = search_error or search_note or "Type to search this folder." }
  hits.on_select = function(i) listing.hit_selected, hits.selected = i, i end
  hits.on_press = function(i) open_hit(hit_rows[i]) end
  return { kind = "column",
    -- A field draws its `empty` only when it is not being typed in, and this
    -- one always is: so the state rides on the hint, which both frontends
    -- draw for the field being typed in.
    -- Pressing the field is nothing — the search box already has the keys.
    -- Naming one is what makes the field a target the frontends can put their
    -- cursor on: without it a search with no hits has no target at all, and
    -- the cursor stays on a tab, where ↑↓ move the panes instead.
    { kind = "field", label = "Search", value = listing.query, editing = true,
      empty = state, on_press = function() end,
      hint = state .. "  ·  the whole folder, ripgrep when it is installed" },
    hits,
  }
end

--- What this session wrote, then Git's own view of the folder: pressing one
--- moves the sidebar to it.
local function changed_lists()
  local held = {}
  local hiding = not listing.hidden
  for path, mark in pairs(listing.marks) do
    if not (hiding and hidden_path(path)) then
      held[#held + 1] = { path = path, at = mark.at or 0,
        detail = tostring(mark.tool or "written") .. " · "
          .. (mark.at and os.date("%H:%M", mark.at) or "")
          .. ((mark.writes or 1) > 1 and (" · ×" .. mark.writes) or "") }
    end
  end
  table.sort(held, function(a, b)
    if a.at ~= b.at then return a.at > b.at end
    return a.path < b.path
  end)
  local extra = {}
  for path, sign in pairs(listing.git) do
    if not listing.marks[path] and not (hiding and hidden_path(path)) then
      extra[#extra + 1] = { path = path, sign = sign }
    end
  end
  table.sort(extra, function(a, b) return a.path < b.path end)
  changed_rows = {}
  for _, item in ipairs(held) do changed_rows[#changed_rows + 1] = item end
  for _, item in ipairs(extra) do
    if #changed_rows >= CHANGED_LIMIT then break end
    changed_rows[#changed_rows + 1] = item
  end
  return held, extra
end

--- What the desktop's Changed list shows: changed_rows, with what to say.
local function changed_items()
  changed_lists()
  local out = {}
  for i, item in ipairs(changed_rows) do
    out[i] = { path = item.path, rel = relative(item.path), detail = item.detail,
      written = listing.marks[item.path] ~= nil, sign = listing.git[item.path] }
  end
  out.empty = listing.git_state == "none" and "Nothing has changed, and this is not a Git folder."
    or "Nothing has changed here."
  return out
end

local function changed_pane()
  local held, extra = changed_lists()
  local items = {}
  for _, item in ipairs(held) do
    items[#items + 1] = { text = relative(item.path), tone = "normal", detail = item.detail,
      badges = { { text = "written", tone = "warning" } } }
  end
  for n = #held + 1, #changed_rows do
    local item = changed_rows[n]
    items[#items + 1] = { text = relative(item.path), tone = "dim",
      badges = { { text = item.sign,
        tone = (item.sign == "?" or item.sign == "A") and "success" or "warning" } } }
  end
  local held_list = { kind = "list", items = items,
    selected = math.max(1, math.min(listing.changed_selected, math.max(#items, 1))),
    empty = listing.git_state == "none"
      and "Nothing has been changed, and this is not a Git folder."
      or "Nothing has been changed here." }
  held_list.on_select = function(i) listing.changed_selected, held_list.selected = i, i end
  held_list.on_press = function(i)
    local item = changed_rows[i]
    if item then reveal(item.path) end
  end
  return { kind = "column",
    { kind = "text", tone = "dim",
      text = (#held > 0 and "What this session wrote" or "Nothing has been written here yet")
        .. (#extra > 0 and ("  ·  then Git: " .. #extra) or "") },
    held_list,
  }
end

--- What the selected file holds.
local function preview_pane()
  local head = { kind = "row",
    { kind = "button", label = "‹ Files", on_press = function()
      set_pane(FILES)
      redraw()
    end },
    { kind = "text", text = relative(preview.path), truncate = true },
  }
  for _, badge in ipairs(badges_of(preview.path) or {}) do
    head[#head + 1] = { kind = "badge", text = badge.text, tone = badge.tone }
  end
  -- How big the file is, at the head's other end: the same word a row uses.
  local bytes = size_at(preview.path)
  if bytes then
    head[#head + 1] = { kind = "text", text = size_of(bytes), tone = "dim", truncate = true }
  end
  local out = { kind = "column", head }
  if preview.stale == "gone" then
    out[#out + 1] = { kind = "text", text = "The file is no longer on disk.", tone = "error" }
  elseif preview.stale then
    out[#out + 1] = { kind = "text", tone = "warning",
      text = "Changed on disk since this was read · v reads it again" }
  end
  if preview.loading then
    out[#out + 1] = { kind = "row", { kind = "spinner" },
      { kind = "text", text = "Reading the PDF…", tone = "dim" } }
    return out
  end
  if preview.error then
    out[#out + 1] = { kind = "text", text = preview.error, tone = "error" }
    return out
  end
  -- What a terminal can say of a GIF, a video or a model: what it is.
  if preview.kind == "gif" or preview.kind == "video" or preview.kind == "model" then
    local words = act.media_words()
    for _, w in ipairs(words) do out[#out + 1] = { kind = "text", text = w, tone = "dim" } end
    return out
  end
  -- A picture: the desktop draws it, a terminal says what it is. An older
  -- bone has no such element, so the note below stands alone there.
  if preview.kind == "image" and require("bone.elements").kinds.image then
    out[#out + 1] = { kind = "image", path = preview.path, alt = preview.name,
      width = preview.width, height = preview.height, detail = preview.detail,
      on_press = open_externally }
  end
  if preview.note then
    out[#out + 1] = { kind = "text", text = preview.note, tone = "dim" }
  end
  if not preview.body then return out end
  if preview.kind == "markdown" then
    out[#out + 1] = { kind = "markdown", text = preview.body }
    return out
  end
  if preview.kind == "html" and preview.raw then
    out[#out + 1] = { kind = "markdown", text = html.to_markdown(html.parse(preview.raw)) }
    return out
  end
  local lines = text.split(preview.body)
  local shown_lines = math.min(#lines, PREVIEW_LINES)
  local body = table.concat(lines, "\n", 1, shown_lines)
  if shown_lines < #lines then
    body = body .. "\n⋮ " .. (#lines - shown_lines) .. " more lines · e edits the whole file"
  end
  out[#out + 1] = { kind = "code", text = body }
  return out
end

--- How wide the pane is, in columns: the frontends both say (the desktop's in
--- cells), and EDIT_COLUMNS is what is assumed when neither does.
local function panel_columns(ctx)
  local columns = tonumber(ctx and ctx.columns) or 0
  if columns <= 0 then return EDIT_COLUMNS end
  return columns
end

--- The part of a line the pane has room for: `room` of its characters, starting
--- at the `first` one, with `…` at each end that drops text and `▏` where the
--- caret sits (`caret` is a byte offset, nil for a line the caret is not on).
--- Cut with the offsets files.text gives, so a line of accents or CJK is never
--- split in the middle of a character.
local function drawn_line(line, first, room, caret)
  local body = tostring(line or "")
  local from = text.after(body, first - 1)
  local to = text.after(body, first - 1 + room)
  local shown
  if caret then
    local at = math.max(from, math.min(caret, to))
    shown = body:sub(from + 1, at) .. "▏" .. body:sub(at + 1, to)
  else
    shown = body:sub(from + 1, to)
  end
  if from > 0 then shown = "…" .. shown end
  if to < #body then shown = shown .. "…" end
  return shown
end

--- The buffer, its caret, and — when asked — the changes or the Markdown. The
--- panel is narrow, so those stand in place of the text rather than beside it.
local function edit_pane(columns)
  local out = { kind = "column",
    { kind = "row",
      { kind = "text", text = relative(editor.path), truncate = true },
      editor.dirty and { kind = "badge", text = "modified", tone = "warning" } or nil,
      editor.conflict and { kind = "badge", text = "changed on disk", tone = "warning" } or nil,
      { kind = "badge", text = "Ln " .. editor.line .. ", Col " .. (editor.col + 1), tone = "dim" },
    },
  }
  if editor.saving then
    out[#out + 1] = { kind = "text", tone = "dim",
      text = "Checking the file on disk before writing it…" }
  end
  if editor.error then
    out[#out + 1] = { kind = "text", text = editor.error,
      tone = editor.conflict and "warning" or "error" }
  end
  if editor.status then
    out[#out + 1] = { kind = "text", text = editor.status, tone = "dim" }
  end
  if editor.go then
    out[#out + 1] = { kind = "field", label = "Go to line", value = editor.go.value, editing = true,
      on_press = function() end, empty = "a line, or line:column", hint = "enter goes · esc leaves it" }
  elseif editor.find and editor.find.open then
    local hits = buffer.find_all(editor, editor.find.term or "")
    out[#out + 1] = { kind = "field", label = "Find", value = editor.find.term or "", editing = editor.find.typing,
      on_press = function() editor.find.typing = true redraw() end,
      empty = "text in this file",
      hint = ((editor.find.term or "") == "" and "type to find" or ((editor.find.at or 0) .. " of " .. #hits))
        .. " · enter the next · ↑ the one before · esc closes" }
  end
  local l1, c1, l2, c2 = buffer.range(editor)
  if l1 then
    local n = #buffer.slice(editor, l1, c1, l2, c2)
    out[#out + 1] = { kind = "text", tone = "dim",
      text = n .. " characters selected" .. (l2 > l1 and (" on " .. (l2 - l1 + 1) .. " lines") or "")
        .. " · ctrl+c copy · ctrl+x cut · ctrl+k add to chat" }
  end

  if editor.shown == "changes" then
    local rows, summary = editor_changes()
    out[#out + 1] = { kind = "text", tone = editor.conflict and "warning" or "dim",
      text = "Changes · " .. tostring(summary or "")
        .. (editor.conflict and "  ·  against the file as it was opened: the one on disk has changed (ctrl+r reads it)" or "") }
    if rows and #rows > 0 then
      out[#out + 1] = { kind = "diff", rows = rows, numbers = true }
    else
      out[#out + 1] = { kind = "text", text = "Nothing has been changed.", tone = "dim" }
    end
    return out
  end

  if editor.shown == "markdown" then
    out[#out + 1] = { kind = "markdown", text = text.join(editor.lines, editor.trailing) }
    return out
  end
  if editor.shown == "html" then
    out[#out + 1] = { kind = "text", tone = "dim", text = "The page, read · e or enter edits it · o opens it in the browser" }
    out[#out + 1] = { kind = "markdown", text = html.to_markdown(html.parse(text.join(editor.lines, editor.trailing))) }
    return out
  end

  local total = #editor.lines
  local half = math.floor(EDIT_WINDOW / 2)
  local from = math.max(1, math.min(editor.line - half, math.max(1, total - EDIT_WINDOW + 1)))
  local to = math.min(total, from + EDIT_WINDOW - 1)
  -- What a drawn line has room for: the panel's columns, less the gutter, the
  -- caret marker and the two marks that say a cut dropped text (a wide
  -- character takes two columns, so the last two are kept spare).
  local gutter_w = EDIT_GUTTER + math.max(4, #tostring(to))
  local room = math.max(8, columns - gutter_w - 3)
  -- A line longer than that is shown in part, and every line is cut at the
  -- same place, so the text stays lined up: the view slides right when the
  -- caret is past what fits, and the caret ends up about half way across it.
  local first = 1
  local before = text.chars(editor.lines[editor.line] or "", editor.col)
  if before + 1 > room then first = math.max(1, before - math.floor(room / 2)) end
  if from > 1 then
    out[#out + 1] = { kind = "text", text = "⋮ " .. (from - 1) .. " lines above", tone = "dim" }
  end
  local items = {}
  edit_rows = {}
  -- Git's change marks ride between the number and the text: + added,
  -- ~ changed, _ lines taken out just above.
  local marks = gutter.marks(editor) or {}
  -- A terminal row is one color: a selection is its lines in the accent, and
  -- ⟨ ⟩ where it starts and stops inside a line.
  local s1, c1, s2, c2 = buffer.range(editor)
  for line = from, to do
    edit_rows[#edit_rows + 1] = line
    local m = marks[line]
    local sign = (editor.flash and editor.flash[line]) and "•"
      or (m == "add" and "+") or (m == "mod" and "~") or ((marks.del and marks.del[line]) and "_") or " "
    local body = editor.lines[line] or ""
    local caret = line == editor.line and editor.col or nil
    local tone = "normal"
    if s1 and line >= s1 and line <= s2 then
      tone = "accent"
      local cuts = {}
      if line == s2 then cuts[#cuts + 1] = { c2, "⟩" } end
      if line == s1 then cuts[#cuts + 1] = { c1, "⟨" } end
      for _, cut in ipairs(cuts) do -- the later place first, so the earlier one stays put
        body = body:sub(1, cut[1]) .. cut[2] .. body:sub(cut[1] + 1)
        if caret and caret > cut[1] then caret = caret + #cut[2] end
      end
    end
    items[#items + 1] = {
      text = string.format("%4d%s %s", line, sign, drawn_line(body, first, room, caret)),
      tone = tone,
    }
  end
  out[#out + 1] = { kind = "list", items = items,
    selected = editor.line - from + 1,
    on_select = function(i)
      local line = edit_rows[i]
      if not line then return end
      -- The list moves the caret on a plain arrow: a plain move ends a
      -- selection (shift and an arrow make one, through the keys).
      if line ~= editor.line then editor.anchor = nil end
      editor.line = line
      editor.col = math.min(editor.col, #(editor.lines[line] or ""))
      editor.undo_kind = nil
      redraw()   -- the caret and the window of lines are drawn from these
    end,
    empty = "An empty file." }
  if to < total then
    out[#out + 1] = { kind = "text", text = "⋮ " .. (total - to) .. " lines below", tone = "dim" }
  end
  return out
end

--- Quick open, in a terminal: the field and the files under it.
function act.quick_pane()
  local list = act.quick_results()
  local items = {}
  for i, hit in ipairs(list) do
    local dir, leaf = hit.rel:match("^(.*/)([^/]+)$")
    items[i] = { text = leaf or hit.rel, tone = hit.recent and "accent" or "normal", detail = dir }
  end
  local held = quick.listing(listing.root)
  local state = (held and held.loading) and "reading the folder…"
    or (#items .. " files" .. ((held and held.cut) and " (the list stops at " .. quick.LIMIT .. ")" or ""))
  local files = { kind = "list", items = items, selected = math.max(1, math.min(quick_sel, math.max(#items, 1))),
    empty = (held and held.loading) and "Reading the folder…" or "No file matches that." }
  files.on_select = function(i) quick_sel, files.selected = i, i end
  files.on_press = function(i) act.quick_pick(i) end
  return { kind = "column",
    { kind = "field", label = "Open", value = quick_q, editing = true, empty = state, on_press = function() end,
      hint = state .. "  ·  letters of a path in order · name:42 opens at line 42" },
    files }
end

--- The open files, in a terminal: one row of their names.
function act.docs_row()
  if #docs == 0 then return nil end
  local parts = {}
  for i, t in ipairs(docs) do
    local name = name_of(t.kind == "edit" and t.ed.path or t.path)
    local dirty = t.kind == "edit" and t.ed.dirty
    parts[#parts + 1] = (i == doc_at and ("[" .. name .. (dirty and " •" or "") .. "]") or (name .. (dirty and " •" or "")))
  end
  return { kind = "text", tone = "dim", truncate = true, text = table.concat(parts, "  ") .. "   ctrl+tab · ctrl+w" }
end

local function build(columns)
  local out = { kind = "column", top_row() }
  if listing.error then
    out[#out + 1] = { kind = "text", text = listing.error, tone = "error" }
  elseif listing.note then
    out[#out + 1] = { kind = "text", text = listing.note, tone = "dim" }
  end
  if quick_on then
    out[#out + 1] = act.quick_pane()
    out[#out + 1] = { kind = "hints", text = "type letters of a path · ↑↓ choose · enter open · esc back" }
    return out
  end
  if ask and ask.confirm then
    out[#out + 1] = { kind = "text", tone = "error", text = ask.title .. "  " .. (ask.detail or "") }
    out[#out + 1] = { kind = "text", tone = "dim", text = "y " .. (ask.button or "yes"):lower() .. " · any other key leaves it" }
  elseif ask then
    out[#out + 1] = { kind = "field", label = ask.title, value = ask.value, editing = true, on_press = function() end,
      empty = "a name", hint = ask.error or "enter makes it · esc leaves it" }
  end
  out[#out + 1] = tabs_row()
  if pane == EDIT or pane == PREVIEW then out[#out + 1] = act.docs_row() end
  if pane == SEARCH then
    out[#out + 1] = search_pane()
  elseif pane == CHANGED then
    out[#out + 1] = changed_pane()
  elseif pane == PREVIEW then
    out[#out + 1] = preview_pane()
  elseif pane == EDIT then
    out[#out + 1] = edit_pane(columns)
  else
    out[#out + 1] = tree_pane(columns)
  end
  out[#out + 1] = { kind = "hints", text = HINTS[pane] }
  return out
end


--- The panel is asked for its view each time it is drawn; the elements are put
--- together again only when something actually changed — which includes the
--- context's answer to who has the keyboard, since the top row shows it, and a
--- different width, since how much of a long line is drawn depends on it.
local function view(ctx)
  local focused = ctx and ctx.focused
  if focused ~= keys_here then shown = nil end
  keys_here = focused
  local columns = panel_columns(ctx)
  if shown and shown_columns ~= columns then shown = nil end
  shown = shown or build(columns)
  shown_columns = columns
  return shown
end

-- ---- what the keys and the menus do ---------------------------------------

--- Copy, cut and paste, through the system clipboard.
function act.copy(cut_too)
  local what = buffer.selected(editor)
  if not what then
    -- Nothing selected: the caret's line, as editors do.
    what = (editor.lines[editor.line] or "") .. "\n"
    if cut_too then
      buffer.remember(editor, nil)
      table.remove(editor.lines, editor.line)
      if #editor.lines == 0 then editor.lines = { "" } end
      editor.line = math.min(editor.line, #editor.lines)
      editor.col = 0
      buffer.touched(editor)
    end
  elseif cut_too then
    buffer.delete_selection(editor)
  end
  clip.copy(what, function(ok, why)
    if not ok then bone.notify("Could not copy: " .. brief(why or "no clipboard"), "error") end
  end)
  editor_note(cut_too and "Cut" or "Copied")
  redraw()
end

function act.paste()
  local ed = editor
  clip.paste(function(value, why)
    if not value then
      bone.notify("Nothing to paste: " .. brief(why or "the clipboard is empty"), "info")
      return
    end
    if editor ~= ed or doc ~= "edit" then return end
    buffer.insert(ed, value)
    editor_note("Pasted")
    redraw()
  end)
end

--- Copy a path: relative to the folder, or the whole of it.
function act.copy_path(path, whole)
  if not path or path == "" then return end
  local value = whole and path or relative(path)
  clip.copy(value, function(ok)
    if ok then note("Copied " .. value) else bone.notify("Could not copy the path", "error") end
    redraw()
  end)
end

--- The file (and the selected lines) named in the message being written, for
--- the agent to read: "path", or "path:12-40".
function act.to_chat(path, from, to)
  if not path or path == "" then return end
  local where = home()
  local prefix = where:gsub("/$", "") .. "/"
  local named = path:sub(1, #prefix) == prefix and path:sub(#prefix + 1) or path
  if named:find("%s") then named = '"' .. named .. '"' end
  if from then named = named .. ":" .. from .. ((to and to ~= from) and ("-" .. to) or "") end
  local draft = bone.prompt.get() or ""
  local sep = (draft == "" or draft:match("%s$")) and "" or " "
  bone.prompt.set(draft .. sep .. named .. " ")
  note("Added " .. named .. " to the message")
  redraw()
end

--- What ctrl+k adds: the editor's selection (its lines), or the file.
function act.editor_to_chat()
  local l1, _, l2, c2 = buffer.range(editor)
  if l1 then
    if c2 == 0 and l2 > l1 then l2 = l2 - 1 end
    act.to_chat(editor.path, l1, l2)
  else
    act.to_chat(editor.path)
  end
end

-- ---- asking for a name --------------------------------------------------------

--- Ask for a name over the panel: `title`, the name to start from, and what
--- to do with the answer (it returns an error to show, or nothing).
function act.ask(title, value, done, select_stem)
  ask = { title = title, value = value or "", done = done, error = nil, select_stem = select_stem, fresh = true }
  redraw()
  if GUI then bone.defer(30, function() pcall(bone.gui.focus, "files:ask") end) end
end

--- Ask yes or no over the panel: `y` (or the button) does it; enter, esc,
--- `n` and anything else leave it.
function act.confirm(title, detail, button, run)
  ask = { title = title, detail = detail, confirm = true, button = button, done = function() run() end }
  redraw()
  if GUI then bone.defer(30, function() pcall(bone.gui.focus, "files:confirm") end) end
end

function act.answer(value)
  if not ask then return end
  local a = ask
  local why = a.done(tostring(value or a.value or ""))
  if why then
    a.error = why
    redraw()
    return
  end
  ask = nil
  redraw()
end

function act.cancel_ask()
  ask = nil
  redraw()
end

-- ---- what the tree does to files ------------------------------------------------

--- The folder a new file goes into: the selected folder, or the one the
--- selected file is in.
local function target_dir()
  local row = listing.rows[listing.selected]
  if not row then return listing.root end
  if row.type == "dir" then return row.path end
  return parent(row.path)
end

--- After the tree's files changed: read the folder again and select `path`.
local function refreshed(path)
  local dir = parent(path)
  -- Every folder on the way is read again (a new one may be among them)
  -- and opened, so the new name is in view.
  local up = dir
  while up and #up >= #listing.root do
    listing.read[up] = nil
    if up ~= listing.root then listing.open[up] = true end
    local next_up = parent(up)
    if next_up == up then break end
    up = next_up
  end
  listing.selected_key = path
  quick.stale(listing.root)
  build_rows()
  fetch_git()
end

function act.new_file()
  local dir = target_dir()
  act.ask("New file in " .. (relative(dir) == dir and name_of(dir) or relative(dir)), "", function(name)
    local path, why = fileops.new_file(dir, name)
    if not path then return why end
    refreshed(path)
    open_editor(path)
  end)
end

function act.new_folder()
  local dir = target_dir()
  act.ask("New folder in " .. (relative(dir) == dir and name_of(dir) or relative(dir)), "", function(name)
    local path, why = fileops.new_folder(dir, name)
    if not path then return why end
    listing.open[path] = true
    refreshed(path)
  end)
end

--- The tabs and the recent files follow a path that moved.
local function moved(from, to)
  for _, t in ipairs(docs) do
    if t.kind == "edit" and t.ed.path == from then t.ed.path = to elseif t.kind == "preview" and t.path == from then
      t.path, t.name = to, name_of(to)
      if preview.path == from then preview.path, preview.name = to, name_of(to) end
    elseif t.kind == "edit" and to and t.ed.path:sub(1, #from + 1) == from .. "/" then
      t.ed.path = to .. t.ed.path:sub(#from + 1)
    end
  end
  quick.forget(from)
  if to then quick.opened(to) end
end

function act.rename(row)
  row = row or listing.rows[listing.selected]
  if not row then return end
  act.ask("Rename " .. row.name, row.name, function(name)
    local path, why = fileops.rename(row.path, name)
    if not path then return why end
    listing.open[path] = listing.open[row.path]
    listing.open[row.path] = nil
    moved(row.path, path)
    refreshed(path)
    note("Renamed to " .. name_of(path))
  end, row.type == "file")
end

function act.duplicate(row)
  row = row or listing.rows[listing.selected]
  if not row then return end
  fileops.duplicate(row.path, function(path, why)
    if not path then bone.notify("Could not duplicate: " .. brief(why), "error") return end
    refreshed(path)
    note("Made " .. name_of(path))
    redraw()
  end)
end

function act.trash(row)
  row = row or listing.rows[listing.selected]
  if not row then return end
  -- An open tab with unsaved work in it is not thrown away with its file.
  for _, t in ipairs(docs) do
    if t.kind == "edit" and t.ed.dirty and (t.ed.path == row.path or t.ed.path:sub(1, #row.path + 1) == row.path .. "/") then
      note(name_of(t.ed.path) .. " has unsaved changes · save or close it first")
      redraw()
      return
    end
  end
  local function gone(how)
    for i = #docs, 1, -1 do
      local t = docs[i]
      local p = t.kind == "edit" and t.ed.path or t.path
      if p == row.path or p:sub(1, #row.path + 1) == row.path .. "/" then act.close_tab(i, true) end
    end
    moved(row.path, nil)
    listing.read[parent(row.path)] = nil
    listing.open[row.path] = nil
    quick.stale(listing.root)
    build_rows()
    fetch_git()
    note(how)
    redraw()
  end
  fileops.trash(row.path, function(ok, why)
    if not ok and fileops.no_trash(why) then
      -- No Trash here (a system folder such as /tmp): only for good, and
      -- only when you say so.
      act.confirm("Delete “" .. row.name .. "” for good?",
        "This place has no Trash, so it cannot be undone.", "Delete", function()
          fileops.delete(row.path, function(done, err)
            if not done then bone.notify("Could not delete it: " .. brief(err), "error") return end
            gone("Deleted " .. row.name)
          end)
        end)
      return
    end
    if not ok then bone.notify("Could not move it to the Trash: " .. brief(why), "error") return end
    gone("Moved " .. row.name .. " to the Trash")
  end)
end

-- ---- quick open -----------------------------------------------------------------

function act.quick_open()
  if quick_on then return end
  quick_on, quick_q, quick_sel = true, "", 1
  menu = nil
  quick.load(listing.root, function() redraw() end)
  redraw()
  if GUI then bone.defer(30, function() pcall(bone.gui.focus, "files:quick") end) end
end

function act.quick_close()
  quick_on = false
  redraw()
end

function act.quick_results()
  local q = quick.split_line(quick_q)
  return quick.results(listing.root, q)
end

function act.quick_pick(i)
  local list = act.quick_results()
  local hit = list[i or quick_sel]
  if not hit then return end
  local _, line = quick.split_line(quick_q)
  quick_on = false
  reveal(join(listing.root, hit.rel))
  if line and doc == "edit" then
    buffer.place(editor, line, #(text.leading(editor.lines[line] or "")))
  end
  redraw()
end

function act.quick_typed(value)
  quick_q, quick_sel = tostring(value or ""), 1
  redraw()
end

--- Keys while quick open has them: true when taken.
function act.quick_key(k)
  if k == "esc" then act.quick_close() return true end
  if k == "enter" then act.quick_pick() return true end
  local by = ({ up = -1, down = 1, ["ctrl+p"] = -1, ["ctrl+n"] = 1, pageup = -10, pagedown = 10 })[k]
  if by then
    local n = #act.quick_results()
    quick_sel = math.max(1, math.min(math.max(n, 1), quick_sel + by))
    redraw()
    return true
  end
  return false
end

-- ---- menus ----------------------------------------------------------------------

--- A row's menu (a right click): what can be done to that file or folder.
function act.tree_menu(i, top, left)
  local row = listing.rows[i]
  if not row then return end
  listing.selected, listing.selected_key = i, row.path
  local items = {}
  local function add(label, key, run) items[#items + 1] = { label = label, key = key, run = run } end
  local function line() items[#items + 1] = { separator = true } end
  if row.type == "file" then
    add("Open", "enter", function() open_file(row.path) end)
    if not GUI and SETTINGS.editor ~= "built-in" and SETTINGS.editor ~= "" then
      add("Open in the built-in editor", "E", function() open_editor(row.path) end)
    end
    add("Open with the desktop's app", "o", function() open_externally() end)
    add("Add to chat", "ctrl+k", function() act.to_chat(row.path) end)
  else
    add(listing.open[row.path] and "Close folder" or "Open folder", "→", function() activate(i) end)
    add("Show in this panel only", nil, function() listing.chosen = true open_folder(row.path) end)
  end
  line()
  add("New file…", "a", function() act.new_file() end)
  add("New folder…", "A", function() act.new_folder() end)
  line()
  add("Copy path", "y", function() act.copy_path(row.path, false) end)
  add("Copy full path", "Y", function() act.copy_path(row.path, true) end)
  line()
  add("Rename…", "R", function() act.rename(row) end)
  add("Duplicate", "D", function() act.duplicate(row) end)
  add("Move to Trash", "delete", function() act.trash(row) end)
  items[#items].danger = true
  menu = { items = items, top = top, left = left, where = "tree" }
  redraw()
end

--- The editor's menu.
function act.editor_menu(top, left)
  local has = buffer.has(editor)
  local items = {
    -- ctrl+c and ctrl+x reach the panel in a bone that hands a focused
    -- panel the desktop's copy and cut; ctrl+insert and shift+delete in any.
    { label = "Cut", key = "ctrl+x", run = function() act.copy(true) end, off = not has },
    { label = "Copy", key = "ctrl+c", run = function() act.copy(false) end, off = not has },
    { label = "Paste", key = "ctrl+v", run = function() act.paste() end },
    { separator = true },
    { label = "Select all", key = "ctrl+a", run = function() buffer.select_all(editor) redraw() end },
    { label = has and "Add the lines to chat" or "Add the file to chat", key = "ctrl+k", run = function() act.editor_to_chat() end },
    { separator = true },
    { label = "Find…", key = "ctrl+f", run = function() act.find_open() end },
    { label = "Go to line…", key = "ctrl+l", run = function() act.go_open() end },
    { label = "Show changes", key = "ctrl+g", run = function() editor.shown = "changes" redraw() end },
  }
  menu = { items = items, top = top, left = left, where = "editor" }
  redraw()
end

function act.menu_close() menu = nil redraw() end

--- Long lines wrapped or running on, for the file shown (the desktop; a
--- terminal shows a line in part).
function act.toggle_wrap()
  if doc ~= "edit" then return end
  if editor.wrap == nil then
    local ext = (editor.path:match("%.(%w+)$") or ""):lower()
    editor.wrap = ext == "md" or ext == "markdown" or ext == "txt" or ext == "rst" or ext == "org" or ext == "tex" or ext == ""
  end
  editor.wrap = not editor.wrap
  editor_note(editor.wrap and "Long lines wrap" or "Long lines run on")
  redraw()
end

--- Following the agent: each file it writes opens here as it writes it.
function act.toggle_follow()
  act.following = not act.following
  act.followed, act.armed = nil, false
  fetch_marks()
  note(act.following and "Following the agent: the files it writes open here" or "Not following the agent")
  redraw()
end

-- Where the last press landed, in the window: the editor turns a drag into a
-- selection from it (a node hears the press in its own pixels, the drag in
-- the window's).
--- The wheel over the panel: what is under it scrolls, the caret stays.
function act.wheel(by)
  if pane == EDIT and doc == "edit" and (editor.shown == "buffer" or editor.shown == "split") then
    editor.ttop = math.max(1, math.min((editor.ttop or 1) + by, #editor.lines))
    editor.tscrolled = true
  elseif pane == EDIT or pane == PREVIEW then
    act.scroll_reading(by)
    return
  elseif pane == SEARCH then
    listing.htop = math.max(1, (listing.htop or 1) + by)
    listing.tscrolled = true
  elseif pane == CHANGED then
    listing.ctop = math.max(1, (listing.ctop or 1) + by)
    listing.tscrolled = true
  else
    listing.ttop = math.max(1, (listing.ttop or 1) + by)
    listing.tscrolled = true
  end
  redraw()
end

-- The terminal's mouse over the drawn panel: a press does what is under it
-- (a row, a tab, a crumb), in the editor it puts the caret and a drag makes
-- a selection; the right button over a row is its menu.
local tdrag = nil
local function tui_mouse(ev)
  if not tlook or ev.panel ~= ID or not (panel and panel:is_open()) then return nil end
  -- A docked panel is no leaf of the layout: its column is the screen's less
  -- where the panel starts.
  local line, col = tonumber(ev.panel_line), tonumber(ev.col)
  if not col and ev.x then
    local info = panel:info() or {}
    if info.col then col = ev.x - info.col + 1 end
  end
  if not line or not col or col < 1 then return nil end
  if ev.action == "down" then
    if not keys_here then panel:focus() end
    if ev.button == "right" then
      local i = tlook.tree_at(line, col)
      if i then act.tree_menu(i, line + 1, col) return true end
      if doc == "edit" and tlook.editor_at(line, col, editor) then act.editor_menu(line + 1, col) return true end
      return true
    end
    -- Over a card (quick open, a name, a menu) a press is the card's; off
    -- it, the card goes.
    if quick_on or ask or menu then
      if not tlook.press(line, col) then
        if menu then menu = nil
        elseif quick_on then act.quick_close()
        elseif ask then act.cancel_ask() end
      end
      redraw()
      return true
    end
    if tlook.press(line, col) then tdrag = nil return true end
    local li, byte = tlook.editor_at(line, col, editor)
    if li and doc == "edit" then
      set_pane(EDIT)
      -- Twice on one place, quickly: the word there.
      local now = (bone.now and bone.now() or (os.time() * 1000)) / 1000
      if act.tlast and act.tlast.line == li and math.abs(act.tlast.col - byte) <= 1 and now - act.tlast.at < 0.4 then
        buffer.select_word(editor, li, byte)
        act.tlast, tdrag = nil, nil
        redraw()
        return true
      end
      act.tlast = { line = li, col = byte, at = now }
      buffer.place(editor, li, byte)
      tdrag = { line = li, col = byte }
      redraw()
    end
    return true
  elseif ev.action == "drag" and tdrag and doc == "edit" then
    local li, byte = tlook.editor_at(line, col, editor)
    if li then
      editor.anchor = { line = tdrag.line, col = tdrag.col }
      editor.line, editor.col = li, byte
      redraw()
    end
    return true
  elseif ev.action == "up" then
    tdrag = nil
    return true
  end
  return true
end

bone.on("mouse", function(ev)
  if not ev then return end
  if not GUI and SETTINGS.link_files and ev.action == "down" and ev.button == "left" and ev.index and not ev.panel then
    local took = act.chat_press(ev)
    if took then return true end
  end
  if tlook then
    local took = tui_mouse(ev)
    if took ~= nil then return took end
  end
  if ev.action == "down" then
    act.button_down = true
    if ev.px then act.press_at = { ev.px, ev.py } end
  elseif ev.action == "up" then
    act.button_down = false
  end
end)

-- ---- a page's links -----------------------------------------------------------------

--- Follow a link on a page: to a place on it, to a file beside it (opened in
--- the panel), or out to the browser or the mail program.
function act.open_link(href, base)
  href = tostring(href or "")
  if href == "" then return end
  local anchor = href:match("^#(.+)$")
  if anchor then
    local at = look and look.html_anchor and look.html_anchor(anchor)
    if at then
      pcall(bone.gui.scroll_item, "files:html", at, "top")
      bone.defer(80, function() pcall(bone.gui.scroll_item, "files:html", at, "top") end)
      bone.defer(240, function() pcall(bone.gui.scroll_item, "files:html", at, "top") end)
    end
    return
  end
  if href:match("^%a[%w+.-]*:") and not href:match("^file:") then
    local P = require("files.platform")
    bone.job.start(P.open_cmd(href), { name = "files: open link", timeout = 10000, buffer = true, on_exit = function() end })
    note("Opened " .. brief(href, 80))
    redraw()
    return
  end
  local path = href:gsub("^file://", ""):gsub("[?#].*$", ""):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
  if path:sub(1, 1) ~= "/" then path = (base or listing.root) .. "/" .. path end
  -- ./ and ../ as a browser takes them.
  local parts = {}
  for part in path:gmatch("[^/]+") do
    if part == ".." then table.remove(parts) elseif part ~= "." then parts[#parts + 1] = part end
  end
  path = "/" .. table.concat(parts, "/")
  if not fileops.exists(path) then
    note("There is no " .. relative(path) .. " beside the page")
    redraw()
    return
  end
  reveal(path)
end

-- ---- GIFs, videos and models ------------------------------------------------------

--- How long `s` seconds is, as 1:05 or 1:02:05.
function act.clock(s)
  s = math.max(0, math.floor(tonumber(s) or 0))
  local h, m, sec = math.floor(s / 3600), math.floor(s % 3600 / 60), s % 60
  if h > 0 then return string.format("%d:%02d:%02d", h, m, sec) end
  return string.format("%d:%02d", m, sec)
end

--- What the preview is, in a few words a line (a terminal shows these).
function act.media_words()
  local p = preview
  local out = {}
  if p.kind == "gif" then
    local a = p.anim or { frames = {} }
    out[#out + 1] = string.format("GIF · %s×%s · %d frames · %.1f s", tostring(p.width or "?"), tostring(p.height or "?"),
      #a.frames, (a.total or 0) / 1000) .. (a.decoding and " (reading…)" or "")
  elseif p.kind == "video" then
    if p.need_ffmpeg then
      out[#out + 1] = "A video: the panel needs ffmpeg to read it."
      out[#out + 1] = p.install and ("i installs it: " .. p.install) or "There is no package manager here the panel knows."
    elseif p.info then
      local i = p.info
      out[#out + 1] = string.format("Video · %s · %s×%s · %s%s", tostring(i.codec or "?"):upper(), tostring(i.width or "?"),
        tostring(i.height or "?"), act.clock(i.duration), i.fps and string.format(" · %.0f fps", i.fps) or "")
      out[#out + 1] = (i.audio and ("sound: " .. tostring(i.audio)) or "no sound") .. (i.format and (" · " .. i.format) or "")
    else
      out[#out + 1] = "Reading the video…"
    end
  elseif p.kind == "model" and p.model then
    local m = p.model
    out[#out + 1] = string.format("3D model · %d triangles · %.4g × %.4g × %.4g", m.count, m.size[1], m.size[2], m.size[3])
  end
  if p.error then out[#out + 1] = p.error end
  out[#out + 1] = "o opens it in the desktop's player or viewer"
  return out
end

-- ---- zooming a picture or a PDF -------------------------------------------------

--- The zoom: nil is fitted to the pane; a number is the scale (1 is the
--- picture's own pixels; for a PDF, 1 is a page as wide as the pane allows,
--- up to 760 pixels). The look writes preview.fit_scale, the fitted scale.
function act.zoom(by)
  local now = preview.zoom or preview.fit_scale or 1
  local z = by > 0 and now * 1.25 or now / 1.25
  if preview.kind == "pdf" then z = math.max(0.3, math.min(z, 4)) else z = math.max(0.05, math.min(z, 16)) end
  if preview.fit_scale and math.abs(z - preview.fit_scale) < 0.02 then z = nil end
  preview.zoom = z
  if not z then preview.pan = nil end
  redraw()
end

function act.zoom_set(z)
  preview.zoom = z
  preview.pan = nil
  redraw()
end

function act.zoom_key(k)
  if k == "+" or k == "=" or k == "ctrl+=" or k == "ctrl++" then act.zoom(1) return true end
  if k == "-" or k == "ctrl+-" then act.zoom(-1) return true end
  if k == "0" or k == "ctrl+0" then act.zoom_set(nil) return true end
  if k == "1" and (preview.kind == "image" or preview.kind == "gif") then act.zoom_set(1) return true end
  if k == "w" and preview.kind == "pdf" then act.zoom_set("width") return true end
  if k == "g" and preview.kind == "pdf" and GUI then
    bone.defer(0, function() pcall(bone.gui.focus, "files:page") end)
    return true
  end
  return false
end

-- ---- find and go to line in the editor -------------------------------------------

function act.find_open()
  local sel = buffer.selected(editor)
  editor.find = editor.find or { term = "" }
  if sel and not sel:find("\n", 1, true) then editor.find.term = sel end
  editor.find.open = true
  editor.go = nil
  redraw()
  if GUI then bone.defer(30, function() pcall(bone.gui.focus, "files:find") end) end
end

function act.find_typed(value)
  local f = editor.find
  if not f then return end
  f.term = tostring(value or "")
  if f.term ~= "" then
    -- From where the search started, so typing more keeps the same place.
    if f.origin then editor.line, editor.col, editor.anchor = f.origin[1], f.origin[2], nil end
    f.origin = f.origin or { editor.line, editor.col }
    buffer.find_step(editor, 1, true)
  end
  redraw()
end

function act.find_step(dir)
  local f = editor.find
  if not f or (f.term or "") == "" then return end
  f.origin = nil
  if dir < 0 then
    -- From the start of the selected match.
    local l1, c1 = buffer.range(editor)
    if l1 then editor.line, editor.col = l1, c1 end
  end
  buffer.find_step(editor, dir, false)
  redraw()
end

function act.find_close()
  if editor.find then editor.find.open, editor.find.origin = false, nil end
  redraw()
end

function act.go_open()
  editor.go = { value = "" }
  if editor.find then editor.find.open = false end
  redraw()
  if GUI then bone.defer(30, function() pcall(bone.gui.focus, "files:goto") end) end
end

function act.go_to(value)
  local line, col = tostring(value or ""):match("^%s*(%d+)%s*[:,]?%s*(%d*)")
  editor.go = nil
  if line then
    line = tonumber(line)
    buffer.place(editor, line, (tonumber(col) or 0) > 0 and (tonumber(col) - 1) or #(text.leading(editor.lines[line] or "")))
  end
  redraw()
end

-- ---- the keys --------------------------------------------------------------

set_pane = function(which)
  if which == FILES or which == SEARCH or which == CHANGED then side = which end
  if pane == which then return end
  pane = which
  shown = nil
  reveal_cursor()
  if panel and panel:is_open() then
    panel:update(chrome())
  end
end

--- Back from the open file to the column of files. The file stays open in
--- its tab: the desktop shows it beside the column, a terminal (one pane at a
--- time) has it a tab or ctrl+tab away.
local function leave_editor()
  editor.confirm = false
  set_pane(side)
  if side == FILES then build_rows() end
  redraw()
end

--- The keys every pane shares: the tabs, quick open, the agent.
local function common_key(k)
  local lower = k:lower()
  if lower == "ctrl+p" then act.quick_open() return true end
  if lower == "ctrl+tab" or lower == "ctrl+pagedown" then act.cycle(1) return true end
  if lower == "ctrl+shift+tab" or lower == "ctrl+pageup" then act.cycle(-1) return true end
  if lower == "ctrl+w" and doc then act.close_tab() return true end
  return false
end

-- The keys that scroll what is read (a preview, a page) in a terminal.
local READ_KEYS = { up = -1, down = 1, pageup = -20, pagedown = 20, home = -1000000, ["end"] = 1000000 }

-- What the editor's keys move the caret by: { rows, cols } or a buffer move.
local EDIT_MOVES = {
  up = { -1, 0 }, down = { 1, 0 }, left = { 0, -1 }, right = { 0, 1 },
  pageup = { -EDIT_PAGE, 0 }, pagedown = { EDIT_PAGE, 0 },
}

--- The keys of the find and go-to-line fields, in a terminal (the desktop's
--- are text fields of their own): true when taken.
local function field_key(k)
  if editor.go then
    if k == "esc" then editor.go = nil
    elseif k == "enter" then act.go_to(editor.go.value)
    else
      local v = bone.text.edit(editor.go.value, k)
      if not v then return false end
      editor.go.value = v
    end
    return true
  end
  local f = editor.find
  if f and f.open and f.typing then
    if k == "esc" then f.typing = false act.find_close()
    elseif k == "enter" or k == "down" then f.typing = false act.find_step(1)
    elseif k == "up" then act.find_step(-1)
    else
      local v = bone.text.edit(f.term or "", k)
      if not v then return false end
      act.find_typed(v)
    end
    return true
  end
  return false
end

local function edit_key(k)
  local lower = k:lower()
  if not GUI and field_key(k) then redraw() return true end
  if lower == "ctrl+tab" or lower == "ctrl+pagedown" then act.cycle(1) return true end
  if lower == "ctrl+shift+tab" or lower == "ctrl+pageup" then act.cycle(-1) return true end
  if lower == "ctrl+w" then act.close_tab() return true end
  if lower == "ctrl+p" then act.quick_open() return true end
  if lower == "ctrl+k" then act.editor_to_chat() return true end
  if lower == "alt+z" and GUI then act.toggle_wrap() return true end
  if editor.shown ~= "buffer" and editor.shown ~= "split" then
    if tlook and READ_KEYS[k] then act.scroll_reading(READ_KEYS[k]) return true end
    -- Reading rather than typing: only the ways back, and saving.
    if k == "ctrl+g" then
      editor.shown = "buffer"
    elseif lower == "ctrl+shift+v" or k == "alt+m" then
      editor.shown = "buffer"
    elseif k == "e" or k == "enter" then
      -- From reading to writing.
      editor.shown = "buffer"
    elseif k == "ctrl+s" then
      save_editor(false)
    elseif k == "esc" or k == "q" then
      leave_editor()
    else
      return false
    end
    redraw()
    return true
  end
  if k == "esc" then
    if editor.find and editor.find.open then act.find_close() return true end
    if buffer.has(editor) then buffer.clear(editor) redraw() return true end
    leave_editor()
    return true
  end
  editor.confirm = false
  local shift = lower:find("shift+", 1, true) ~= nil
  local base = lower:gsub("shift%+", "")
  local ctrl = base:find("ctrl+", 1, true) ~= nil
  local bare = base:gsub("ctrl%+", "")
  local move = EDIT_MOVES[bare]
  if move and not ctrl then
    -- Left and right with a selection and no shift go to its ends.
    if not shift and move[1] == 0 and buffer.has(editor) then
      buffer.collapse(editor, move[2] > 0)
    else
      buffer.move(editor, move[1], move[2], shift)
    end
  elseif ctrl and (bare == "left" or bare == "right") then
    buffer.word(editor, bare == "left" and -1 or 1, shift)
  elseif ctrl and (bare == "up" or bare == "down") then
    -- ctrl+up and ctrl+down move the view a line, the caret with it.
    buffer.move(editor, bare == "up" and -1 or 1, 0, shift)
  elseif bare == "home" then
    if ctrl then buffer.edge(editor, true, shift) else buffer.home(editor, shift) end
  elseif bare == "end" then
    if ctrl then buffer.edge(editor, false, shift) else buffer.line_end(editor, shift) end
  elseif k == "ctrl+s" then
    save_editor(false)
  elseif k == "ctrl+o" then
    save_editor(true)
  elseif k == "ctrl+r" then
    reload_editor()
  elseif k == "ctrl+z" then
    undo_edit()
  elseif k == "ctrl+y" or lower == "ctrl+shift+z" then
    redo_edit()
  elseif k == "ctrl+g" then
    editor.shown = editor.shown == "changes" and "buffer" or "changes"
  elseif lower == "ctrl+shift+v" or k == "alt+m" then
    editor.shown = kinds.of(name_of(editor.path)) == "html" and "html" or "markdown"
  elseif k == "ctrl+a" then
    buffer.select_all(editor)
  elseif k == "ctrl+c" or lower == "ctrl+insert" then
    act.copy(false)
    return true
  elseif k == "ctrl+x" or lower == "shift+delete" then
    act.copy(true)
    return true
  elseif (k == "ctrl+v" and not GUI) or lower == "shift+insert" then
    act.paste()
    return true
  elseif k == "ctrl+f" then
    act.find_open()
    if not GUI then editor.find.typing = true end
  elseif k == "f3" or k == "ctrl+enter" then
    act.find_step(1)
  elseif lower == "shift+f3" then
    act.find_step(-1)
  elseif k == "ctrl+l" then
    act.go_open()
  elseif k == "ctrl+d" then
    -- The word at the caret, selected (then ctrl+f finds the next one).
    buffer.select_word(editor, editor.line, editor.col)
  elseif k == "enter" then
    buffer.newline(editor)
    editor_note("Modified")
  elseif k == "backspace" then
    buffer.backspace(editor)
    editor_note("Modified")
  elseif k == "ctrl+backspace" or k == "alt+backspace" then
    buffer.backspace_word(editor)
    editor_note("Modified")
  elseif k == "delete" then
    buffer.delete(editor)
    editor_note("Modified")
  elseif k == "tab" then
    buffer.indent(editor, false)
    editor_note("Modified")
  elseif lower == "shift+tab" or k == "backtab" then
    buffer.indent(editor, true)
    editor_note("Modified")
  elseif k == "space" or k == " " then
    buffer.insert(editor, " ")
    editor_note("Modified")
  elseif #k == 1 or k:match("^[\194-\244][\128-\191]*$") then
    buffer.type_char(editor, k)
    editor_note("Modified")
  else
    return false
  end
  redraw()
  return true
end

local function search_key(k)
  if k == "esc" then
    exit_search()
    return true
  end
  if k == "q" then
    exit_search()
    close_panel()
    return true
  end
  if k == "enter" then
    open_hit(hit_rows[listing.hit_selected])
    return true
  end
  if k == "up" or k == "down" or k == "pageup" or k == "pagedown" then
    local by = (k == "up" and -1) or (k == "down" and 1)
      or (k == "pageup" and -10) or (k == "pagedown" and 10)
    listing.hit_selected = math.max(1, math.min(math.max(#hit_rows, 1), listing.hit_selected + by))
    redraw()
    return true
  end
  if k == "left" then
    exit_search()
    return true
  end
  if k == "right" then
    stop_job("search")
    fetch_marks()
    fetch_git()
    set_pane(CHANGED)
    redraw()
    return true
  end
  if k == "backspace" and listing.query == "" then
    exit_search()
    return true
  end
  local edited = bone.text.edit(listing.query, k)
  if not edited then return false end
  listing.query, listing.hit_selected = edited, 1
  if edited == "" then
    stop_job("search")
    hit_rows, listing.search_state = {}, "off"
    search_note, search_error = nil, nil
  else
    schedule_search()
  end
  redraw()
  return true
end

--- Scroll what is read rather than edited (a preview, a page) by `by` lines.
function act.scroll_reading(by)
  if pane == PREVIEW then
    preview.ttop = math.max(1, (preview.ttop or 1) + by)
  elseif doc == "edit" and editor.shown == "changes" then
    editor.dtop = math.max(1, (editor.dtop or 1) + by)
  elseif doc == "edit" then
    editor.ptop = math.max(1, (editor.ptop or 1) + by)
  end
  redraw()
end

local function preview_key(k)
  if common_key(k) then return true end
  if tlook and READ_KEYS[k] and preview.kind ~= "model" then act.scroll_reading(READ_KEYS[k]) return true end
  if k == "q" then
    close_panel()
    return true
  end
  if k == "ctrl+k" then act.to_chat(preview.path) return true end
  if preview.kind == "video" or preview.kind == "gif" then
    if k == "o" then media.open_player(preview.path) return true end
    if k == "i" and preview.need_ffmpeg then media.install(preview) return true end
    if (k == "space" or k == " ") and preview.kind == "video" and preview.info then
      if preview.playing then media.pause(preview) else media.play(preview) end
      return true
    end
    if (k == "space" or k == " ") and preview.anim then
      preview.anim.playing = not preview.anim.playing
      preview.anim.t0 = nil
      redraw()
      return true
    end
  end
  if preview.kind == "model" and preview.view then
    local v = preview.view
    local turn = ({ left = { -0.25, 0 }, right = { 0.25, 0 }, up = { 0, -0.2 }, down = { 0, 0.2 } })[k]
    if turn then v.yaw, v.pitch = v.yaw + turn[1], math.max(-1.5, math.min(1.5, v.pitch + turn[2])) redraw() return true end
    if k == "+" or k == "=" then v.zoom = math.min(8, v.zoom * 1.2) redraw() return true end
    if k == "-" then v.zoom = math.max(0.2, v.zoom / 1.2) redraw() return true end
    if k == "0" then preview.view = { yaw = -0.7, pitch = 0.45, zoom = 1 } redraw() return true end
    if k == "w" then preview.wire = not preview.wire redraw() return true end
  end
  if (preview.kind == "image" or preview.kind == "pdf" or preview.kind == "gif") and act.zoom_key(k) then
    redraw()
    return true
  end
  if k == "esc" or k == "b" or (k == "left" and not preview.zoom) then
    set_pane(side)
    redraw()
    return true
  end
  if k == "e" then
    local content = text.read(preview.path)
    if content and not text.is_binary(content) then
      if not act.external_open(preview.path) then open_editor(preview.path) end
    else
      bone.notify("There is no text there to edit.", "info")
    end
    return true
  end
  if k == "o" then
    open_externally()
    return true
  end
  if k == "t" and preview.kind == "pdf" and preview.pages_state then
    preview.pdf_view = preview.pdf_view == "text" and "pages" or "text"
    redraw()
    return true
  end
  if k == "v" or k == "r" then
    preview_cache[preview.path] = nil
    pages_held[preview.path] = nil
    load_preview({ path = preview.path, name = preview.name })
    redraw()
    return true
  end
  return false
end

local function changed_key(k)
  if common_key(k) then return true end
  if k == "q" then
    close_panel()
    return true
  end
  if k == "r" then
    fetch_marks()
    fetch_git()
    note("Read " .. display(listing.root) .. " again")
    redraw()
    return true
  end
  if k == "esc" or k == "b" or k == "left" then
    set_pane(FILES)
    build_rows()
    redraw()
    return true
  end
  return false
end

--- The open file, given the keys again.
local function focus_doc()
  if doc == "edit" then set_pane(EDIT) elseif doc == "preview" then set_pane(PREVIEW) end
  redraw()
end

local function tree_key(k)
  if common_key(k) then return true end
  if listing.filter_typing then
    if k == "esc" then
      listing.filter_typing, listing.filter = false, ""
    elseif k == "enter" or k == "down" then
      listing.filter_typing = false
    else
      local v = bone.text.edit(listing.filter, k)
      if not v then return false end
      listing.filter = v
    end
    build_rows()
    redraw()
    return true
  end
  local row = listing.rows[listing.selected]
  if k == "q" then
    close_panel()
    return true
  end
  if k == "p" then act.quick_open() return true end
  if k == "L" then act.pick_named() return true end
  if k == "a" then act.new_file() return true end
  if k == "A" then act.new_folder() return true end
  if k == "R" or k == "f2" then act.rename() return true end
  if k == "D" then act.duplicate() return true end
  if k == "delete" or k == "ctrl+backspace" then act.trash() return true end
  if k == "y" or k == "Y" then
    if row then act.copy_path(row.path, k == "Y") end
    return true
  end
  if k == "ctrl+k" then
    if row and row.type == "file" then act.to_chat(row.path) end
    return true
  end
  if k == "f" then
    if GUI then
      bone.defer(0, function() pcall(bone.gui.focus, "files:filter") end)
    else
      listing.filter_typing = true
    end
    redraw()
    return true
  end
  if k == "esc" and listing.filter ~= "" then
    listing.filter = ""
    build_rows()
    redraw()
    return true
  end
  if k == "F" then act.toggle_follow() return true end
  if k == "tab" and doc then
    focus_doc()
    return true
  end
  if k == "esc" and doc then
    return close_doc()
  end
  if k == "ctrl+s" and doc == "edit" then
    save_editor(false)
    return true
  end
  if k == "s" or k == "/" then
    enter_search()
    redraw()
    return true
  end
  if k == "c" then
    fetch_marks()
    fetch_git()
    set_pane(CHANGED)
    redraw()
    return true
  end
  if k == "E" then
    -- The built-in editor, whatever the setting says.
    local row = listing.rows[listing.selected]
    if row and row.type == "file" then open_editor(row.path) end
    return true
  end
  if k == "e" then
    local row = listing.rows[listing.selected]
    if row and row.type == "file" then
      if not act.external_open(row.path) then open_editor(row.path) end
    elseif row and row.type == "dir" then
      bone.notify("That is a folder.", "info")
    end
    return true
  end
  if k == "o" then
    open_externally()
    return true
  end
  if k == "v" then
    local row = listing.rows[listing.selected]
    if row and row.type == "file" then
      preview_cache[row.path] = nil
      open_preview({ path = row.path, name = row.name, fresh = true })
    elseif row and row.type == "dir" then
      bone.notify("That is a folder — enter opens it.", "info")
    end
    return true
  end
  if k == "r" then
    build_rows(true)
    fetch_marks()
    fetch_git()
    note("Read " .. display(listing.root) .. " again")
    redraw()
    return true
  end
  if k == "backspace" or k == "left" then
    if not go_up() then
      local up = parent(listing.root)
      if up ~= listing.root then
        listing.chosen = true
        open_folder(up)
      end
    end
    redraw()
    return true
  end
  return false
end

local PAGE_ROWS = 15

--- The desktop's own moves through the tree and the changed files (in a
--- terminal the elements move the cursor). In the tree right opens a folder
--- or steps into it, left closes it or steps out to the one above, as in a
--- Finder list. nil: not a move, the pane's keys decide.
local function desktop_move(k)
  local by = ({ up = -1, down = 1, pageup = -PAGE_ROWS, pagedown = PAGE_ROWS })[k]
  if pane == CHANGED then
    if by then
      listing.changed_selected = math.max(1, math.min(math.max(#changed_rows, 1), listing.changed_selected + by))
      return true
    end
    if k == "enter" or k == "space" or k == "right" then
      local item = changed_rows[listing.changed_selected]
      if item then reveal(item.path) end
      return true
    end
    return nil
  end
  if pane ~= FILES then return nil end
  local row = listing.rows[listing.selected]
  if by then
    move(by)
  elseif k == "home" then
    move(-#listing.rows)
  elseif k == "end" then
    move(#listing.rows)
  elseif k == "right" then
    if not row then return true end
    if row.type == "dir" and not listing.open[row.path] then
      activate(listing.selected)
    elseif row.type == "dir" then
      move(1)
    else
      open_file(row.path)
    end
  elseif k == "left" then
    if row and row.type == "dir" and listing.open[row.path] then
      activate(listing.selected)
    elseif row and row.depth > 0 then
      for i = listing.selected - 1, 1, -1 do
        local up = listing.rows[i]
        if up.type == "dir" and up.depth == row.depth - 1 then
          listing.selected, listing.selected_key = i, up.path
          break
        end
      end
    else
      local up = parent(listing.root)
      if up ~= listing.root then
        listing.chosen = true
        open_folder(up)
      end
    end
  elseif k == "enter" or k == "space" then
    activate(listing.selected)
  else
    return nil
  end
  return true
end

--- The menu over the panel: up and down, enter, esc.
local function menu_key(k)
  if k == "esc" then menu = nil return true end
  local items = menu.items
  local by = ({ up = -1, down = 1 })[k]
  if by then
    local i = menu.at or 0
    repeat i = ((i - 1 + by) % #items) + 1 until not items[i].separator
    menu.at = i
    return true
  end
  if k == "enter" or k == "space" then
    local it = items[menu.at or 0]
    menu = nil
    if it and it.run then it.run() end
    return true
  end
  return true
end

local function on_key(k)
  if menu then
    menu_key(k)
    redraw()
    return true
  end
  if quick_on then
    if act.quick_key(k) then return true end
    if not GUI then
      local v = bone.text.edit(quick_q, k)
      if v then act.quick_typed(v) return true end
    end
    return true
  end
  if ask then
    if k == "esc" then act.cancel_ask() return true end
    if ask.confirm then
      if k == "y" or k == "Y" then act.answer("") else act.cancel_ask() end
      return true
    end
    if not GUI then
      if k == "enter" then act.answer(ask.value) return true end
      local v = bone.text.edit(ask.value, k)
      if v then ask.value, ask.error = v, nil redraw() end
    end
    return true
  end
  if tlook and (k == "wheelup" or k == "wheeldown") then
    act.wheel(k == "wheelup" and -3 or 3)
    return true
  end
  if GUI or tlook then
    local moved = desktop_move(k)
    if moved ~= nil then
      redraw()
      return moved
    end
  end
  if k == "ctrl+h" and pane ~= EDIT then
    listing.hidden = not listing.hidden
    listing.read = {}
    build_rows()
    redraw()
    return true
  end
  if pane == EDIT then return edit_key(k) end
  if pane == SEARCH then return search_key(k) end
  if pane == PREVIEW then return preview_key(k) end
  if pane == CHANGED then return changed_key(k) end
  return tree_key(k)
end

-- ---- keeping up with the agent ---------------------------------------------

--- The file in the preview, and the file in the editor: both were read at a
--- moment, and the agent is writing all the time. After each tool call this
--- asks the core what they look like now, and says so when they do not.
--- The file in the editor against the disk. A file with no unsaved work
--- takes what was written, the lines that changed lit for a moment; one with
--- unsaved work is not touched, and says the file moved under it.
function act.check_editor()
  local ed = editor
  if doc ~= "edit" or not ed.disk_hash or ed.checking then return end
  ed.checking = true
  ask_hash(ed.path, function(found)
    ed.checking = false
    if not panel or not panel:is_open() or editor ~= ed or doc ~= "edit" then return end
    if not found then
      ed.conflict = true
      ed.status = "The file is no longer on disk"
    elseif found.hash ~= ed.disk_hash then
      if ed.dirty then
        ed.conflict = true
        ed.status = "Changed on disk · ctrl+r reads it · ctrl+g shows the difference"
        ed.diff_key = nil
      else
        act.take_disk(ed)
      end
    elseif ed.conflict then
      ed.conflict = false
      ed.status = nil
    end
    redraw()
  end)
end

--- Read the file again because someone else wrote it, and light what changed.
function act.take_disk(ed)
  local before = ed.lines
  reload_editor()
  local marks = gutter.marks({ head = before, lines = ed.lines, version = -1 }) or {}
  local lit, first = {}, nil
  for line, how in pairs(marks) do
    if type(line) == "number" and how then
      lit[line] = true
      if not first or line < first then first = line end
    end
  end
  for line in pairs(marks.del or {}) do
    lit[line] = true
    if not first or line < first then first = line end
  end
  ed.flash = lit
  ed.status = "Updated on disk" .. (first and (" · line " .. first) or "")
  if first then
    ed.line, ed.col, ed.anchor = math.min(first, #ed.lines), 0, nil
  end
  local token = {}
  ed.flash_token = token
  bone.defer(2600, function()
    if ed.flash_token == token then
      ed.flash = nil
      redraw()
    end
  end)
end

--- Following the agent: the file it wrote last, opened (unless the editor
--- holds unsaved work in another one).
function act.follow(paths)
  local newest = paths and paths[1]
  if not act.following or not newest or not newest.path then return end
  local key = newest.path .. "@" .. tostring(newest.at) .. "#" .. tostring(newest.writes)
  if act.followed == key then return end
  local first = act.followed == nil
  act.followed = key
  if first and not act.armed then return end
  if doc == "edit" and editor.dirty and editor.path ~= newest.path then
    note("The agent wrote " .. name_of(newest.path) .. " · unsaved work here kept it from opening")
    return
  end
  if not (doc == "edit" and editor.path == newest.path) then reveal(newest.path) end
end

catch_up = function()
  if not SETTINGS.autorefresh then return end
  act.armed = true
  -- The agent may have made or removed files: quick open reads the folder again.
  quick.stale(listing.root)
  fetch_marks()
  check_preview()
  act.check_editor()
end

-- ---- the panel itself ------------------------------------------------------

--- The sidebar's share of the window: half of it (the `width` setting says
--- otherwise, in percent), and more while a file is open.
size_for = function()
  local want = SETTINGS.width
  -- The desktop puts the open file beside the tree, so it widens while one
  -- is open; a terminal shows the editor alone, a little wider than a tree.
  -- Beside another editor's panel, only the tree is here: narrow.
  if act.ext_on and not doc then return math.max(0.2, math.min(0.3, want * 0.55)) end
  if GUI or tlook then
    if doc then want = want + 0.1 end
  elseif pane == EDIT then
    want = want + 0.05
  end
  return math.max(0.2, math.min(0.85, want))
end

title_for = function()
  local what = ({ [FILES] = "folder", [SEARCH] = "search", [CHANGED] = "changed",
    [PREVIEW] = name_of(preview.path), [EDIT] = name_of(editor.path) })[pane]
  local leaf = display(listing.root):match("[^/]+/?$") or listing.root
  return "Files · " .. tostring(what) .. " · " .. leaf
end

close_panel = function()
  if panel and panel:is_open() then panel:close() end
end

--- There is no session-switch event: watch the session while the panel is open,
--- and start again when its folder is a different one.
local function watch(token)
  bone.defer(500, function()
    if token ~= watcher or not panel or not panel:is_open() then return end
    local where = home()
    if where ~= listing.root then
      -- A folder you asked for stays yours, and so does one a reveal moved
      -- to: only one that has gone away, or the folder the sidebar was
      -- following on its own, is traded for the session's.
      if listing.chosen then
        -- Only whether it is still there: reading it again (and asking its
        -- sizes) twice a second would redraw the panel for nothing.
        local err = bone.fs.list(listing.root) == nil
        if err then
          listing.chosen = false
          open_folder(where)
        end
      else
        open_folder(where)
      end
    end
    watch(token)
  end)
end

-- ---- what the desktop's look reads, and what its presses do ---------------

local scrolled = {} -- a list's id and key -> the entry last scrolled into view

--- The marks of `path` for the desktop: this session's write, Git's letter,
--- and for a folder whether anything inside it changed.
local function desktop_badges(path)
  local out = { mark = listing.marks[path], sign = listing.git[path] }
  if not out.mark and not out.sign then
    local prefix = path .. "/"
    for p in pairs(listing.git) do
      if p:sub(1, #prefix) == prefix then out.inside = true break end
    end
    if not out.inside then
      for p in pairs(listing.marks) do
        if p:sub(1, #prefix) == prefix then out.inside = true break end
      end
    end
  end
  return out
end

--- Give the panel the keyboard back (after the search field had it).
local function take_keys()
  if not GUI then return end
  pcall(bone.gui.focus, nil)
  bone.defer(0, function()
    if panel and panel:is_open() then panel:focus() end
  end)
end

local bridge = {
    generation = function() return act.gen or 0 end,
    state = function()
      return {
        pane = pane, tab = TAB_AT[side] or 1, doc = doc, doc_focused = pane == EDIT or pane == PREVIEW,
        listing = listing, editor = editor, preview = preview, hits = hit_rows,
        search_note = search_note, search_error = search_error, keys_here = keys_here,
        home = os.getenv("HOME") or "", leaf = name_of(listing.root), relative = relative,
        docs = docs, doc_at = doc_at, quick_on = quick_on, quick_q = quick_q, quick_sel = quick_sel,
        ask = ask, menu = menu, following = act.following,
      }
    end,
    act = act,
    -- The editor, changed by `fn(editor)` (a press, a drag), then drawn again.
    edit = function(fn)
      fn(editor)
      editor.confirm = false
      set_pane(EDIT)
      redraw()
    end,
    marks = function() return gutter.marks(editor) end,
    brackets = function() return buffer.brackets(editor) end,
    find_hits = function()
      local f = editor.find
      if not f or not f.open or (f.term or "") == "" then return nil end
      return buffer.find_all(editor, f.term)
    end,
    tab_click = function(i)
      act.show_tab(i)
      set_pane(docs[i] and docs[i].kind == "edit" and EDIT or PREVIEW)
      redraw()
    end,
    tab_close = function(i) act.close_tab(i) end,
    filter_typed = function(v)
      v = tostring(v or "")
      if v == listing.filter then return end
      listing.filter = v
      build_rows()
      redraw()
    end,
    filter_key = function(k)
      if k == "esc" then
        listing.filter = ""
        build_rows()
        take_keys()
        redraw()
        return true
      end
      if k == "enter" or k == "down" then
        take_keys()
        if k == "enter" and listing.filter ~= "" then
          -- The first file that matched.
          for i, r in ipairs(listing.rows) do
            if r.hit and r.type == "file" then listing.selected, listing.selected_key = i, r.path break end
          end
        end
        redraw()
        return true
      end
      return false
    end,
    quick_results = function() return act.quick_results(), quick.listing(listing.root) end,
    give_keys = function() take_keys() end,
    pdf_page = function(n)
      if not n then return end
      pcall(bone.gui.scroll_item, "files:pages", n, "top")
      take_keys()
    end,
    focused = function(f) keys_here = f end,
    badges = desktop_badges,
    size_of = size_of,
    size_at = size_at,
    scroll_to = function(id, index, key, how)
      if not index then return end
      local at = id .. "|" .. tostring(key or "")
      local before = scrolled[at]
      if before == index then return end
      -- A step keeps the row just in view; a jump (a search hit, a click on
      -- another file) puts it in the middle, unless the caller says.
      how = how or ((before and math.abs(index - before) <= 2) and "nearest" or "center")
      if bone.gui.scroll_item(id, index, how) then
        scrolled[at] = index
      else
        -- The list is drawn for the first time this frame: ask again after it.
        pcall(bone.gui.invalidate, 30)
      end
    end,
    click_row = function(i)
      menu = nil
      if pane ~= FILES then set_pane(FILES) end
      activate(i)
    end,
    tab = function(i) select_tab(i) end,
    crumb = function(path)
      listing.chosen = true
      open_folder(path)
    end,
    search_typed = function(t)
      t = tostring(t or "")
      if t == listing.query then return end
      listing.query, listing.hit_selected = t, 1
      if t == "" then
        stop_job("search")
        hit_rows, listing.search_state = {}, "off"
        search_note, search_error = nil, nil
      else
        schedule_search()
      end
      redraw()
    end,
    search_nav = function(k)
      if k == "esc" then
        exit_search()
        take_keys()
        return true
      end
      if k == "enter" then
        local hit = hit_rows[listing.hit_selected]
        if hit then
          take_keys()
          open_hit(hit)
        end
        return true
      end
      local by = ({ up = -1, down = 1, pageup = -PAGE_ROWS, pagedown = PAGE_ROWS })[k]
      if by then
        listing.hit_selected = math.max(1, math.min(math.max(#hit_rows, 1), listing.hit_selected + by))
        redraw()
        return true
      end
      return false
    end,
    open_hit = function(i)
      listing.hit_selected = i
      take_keys()
      open_hit(hit_rows[i])
    end,
    open_changed = function(i)
      listing.changed_selected = i
      local item = changed_rows[i]
      if item then reveal(item.path) end
    end,
    changed_items = changed_items,
    changed_count = function()
      changed_lists()
      return #changed_rows
    end,
    caret = function(line, byte, extend)
      buffer.place(editor, line, byte, extend)
      editor.confirm = false
      set_pane(EDIT)
      redraw()
    end,
    mode = function(m)
      editor.shown = m
      set_pane(EDIT)
      redraw()
    end,
    save = function(force) save_editor(force) end,
    reload_editor = function() reload_editor() end,
    editor_changes = function() return (editor_changes()) end,
    open_externally = function() open_externally() end,
    pdf_view = function(v)
      preview.pdf_view = v
      redraw()
    end,
    reread = function()
      preview_cache[preview.path] = nil
      pages_held[preview.path] = nil
      load_preview({ path = preview.path, name = preview.name })
      redraw()
    end,
    close_panel = function() close_panel() end,
}
if look then look.setup(bridge) end
if tlook then tlook.setup(bridge) end

open = function()
  if bone.ui.panel.get(ID) then bone.ui.panel.close(ID) end
  listing.chosen = false
  listing.root = home()
  local spec = {
    id = ID, dock = "right", size = size_for(), full_height = true, focus = true,
    on_key = on_key,
    on_close = function()
      panel = nil
      watcher = watcher + 1
      stop_job("git")
      stop_job("search")
      -- Closed by you: a reload leaves it closed. A reload drops this state
      -- before the deferred save runs, so it does not count as closing.
      bone.defer(300, function()
        if panel then return end
        local ok, saved = pcall(bone.state.load, SESSION)
        if ok and type(saved) == "table" then
          saved.shown = false
          pcall(bone.state.save, SESSION, saved)
        end
      end)
    end,
  }
  if look then
    spec.node = function(ctx) return look.view(ctx) end
  elseif tlook then
    spec.render = function(ctx) return tlook.render(ctx) end
  else
    spec.title, spec.view = title_for(), view
  end
  panel = bone.ui.panel.open(spec)
  -- A command typed in the prompt leaves the keyboard there: the panel takes
  -- it once the command is done.
  bone.defer(30, function()
    if panel and panel:is_open() then panel:focus() end
  end)
  build_rows()
  fetch_marks()
  fetch_git()
  redraw()
  watcher = watcher + 1
  watch(watcher)
  return panel
end

-- ---- the commands ----------------------------------------------------------

local COMPLETE_LIMIT = 30 -- the most paths a completion offers

--- Is the word being typed still the first one? Only that one is a path:
--- /files' second word is a search term and /editor's is a line number.
local function first_argument(ctx)
  local args = tostring((ctx and ctx.args) or ""):gsub("^%s+", "")
  local token = tostring((ctx and ctx.token) or "")
  if token == "" then return true end
  return args:find("%s") == nil and args:sub(1, #token) == token
end

--- What the word being typed could become, as paths. The starting folder is
--- home unless the word says otherwise. A folder keeps a "/" on the end, so
--- the next tab goes deeper. `~` means the home folder here too, and hidden
--- names are offered: completing to .bashrc is the point.
--- The menu only keeps a suggestion that starts with exactly what was typed, so
--- a name's case has to match the word being typed.
local function complete_paths(ctx)
  if not first_argument(ctx) then return {} end
  local token = tostring((ctx and ctx.token) or "")
  -- Everything up to the last "/" is the folder being looked into; the rest is
  -- the name being typed. So "doc" asks what is in the starting folder whose
  -- name starts "doc", not what is inside a folder called "doc".
  local dir, leaf = "", token
  if token:find("/", 1, true) then dir, leaf = token:match("^(.*/)(.*)$") end
  if dir == "" and leaf == "~" then dir, leaf = "~/", "" end -- `~` is home here
  local shown = dir -- "", "docs/", "~/", "/" — exactly the prefix being typed
  local probe = absolute(dir)
  if #probe > 1 and probe:sub(-1) == "/" then probe = probe:sub(1, -2) end
  local entries = bone.fs.list(probe)
  if not entries then return {} end
  local hits = {}
  for _, entry in ipairs(entries) do
    local name = tostring(entry.name or "")
    if name ~= "" and name ~= "." and name:sub(1, #leaf) == leaf then
      hits[#hits + 1] = { name = name, dir = entry.type == "dir" }
    end
  end
  -- Folders first, the ones you can see before the hidden ones, then by name:
  -- a list cut at COMPLETE_LIMIT should start with what you were after.
  table.sort(hits, function(a, b)
    if a.dir ~= b.dir then return a.dir end
    local ah, bh = a.name:sub(1, 1) == ".", b.name:sub(1, 1) == "."
    if ah ~= bh then return bh end
    return a.name:lower() < b.name:lower()
  end)
  local out = {}
  for i = 1, math.min(#hits, COMPLETE_LIMIT) do
    local hit = hits[i]
    out[#out + 1] = {
      value = shown .. hit.name .. (hit.dir and "/" or ""),
      desc = hit.dir and "a folder" or "a file",
    }
  end
  return out
end

--- A command run on the sidebar hands it the keyboard, as opening it does.
local function take_keys_soon()
  bone.defer(30, function()
    if panel and panel:is_open() then panel:focus() end
  end)
end

--- /files [path] · /files search <term>: the sidebar.
bone.cmd.create("files", function(c)
  local rest = tostring((c and c.args) or ""):match("^%s*(.-)%s*$")
  if rest == "links" then
    act.pick_named()
    return
  end
  local term = rest:match("^search%s+(.+)$")
  if term then
    if not (panel and panel:is_open()) then open() else take_keys_soon() end
    run_search(term)
    return
  end
  if panel and panel:is_open() then
    if rest == "" then
      close_panel()
    else
      listing.chosen = true
      open_folder(absolute(rest))
      take_keys_soon()
    end
    return
  end
  open()
  if rest ~= "" then
    listing.chosen = true
    open_folder(absolute(rest))
  end
end, { desc = "the files sidebar: a folder tree, a search, a viewer and an editor"
  .. " (/files [path] · /files search <term>)", aliases = { "explorer" },
  complete = function(ctx)
    local out = complete_paths(ctx)
    local token = tostring((ctx and ctx.token) or "")
    if first_argument(ctx) and (token == "" or ("search"):sub(1, #token) == token) then
      table.insert(out, 1, { value = "search", desc = "search the folder's text" })
    end
    if first_argument(ctx) and (token == "" or ("links"):sub(1, #token) == token) then
      table.insert(out, 1, { value = "links", desc = "the files the last reply named, to open one" })
    end
    return out
  end })

bone.cmd.create("editor", function(c)
  local rest = tostring((c and c.args) or ""):match("^%s*(.-)%s*$")
  if rest == "" then
    bone.notify("usage: /editor <path> [line]", "error")
    return
  end
  local path, line = rest:match("^(.-)%s+(%d+)$")
  if not path then path, line = rest, nil end
  if not (panel and panel:is_open()) then open() else take_keys_soon() end
  if not act.external_open(absolute(path), line) then open_editor(absolute(path), line) end
end, { desc = "edit a file in the sidebar, at a line if you give one",
  aliases = { "edit" }, complete = complete_paths })

-- ---- paste -------------------------------------------------------------------

-- What is pasted while the editor has the keyboard goes into it: the desktop
-- turns ctrl+v into a paste (not a key), and a terminal's own paste arrives
-- the same way.
bone.on("paste", function(ev)
  if not (panel and panel:is_open()) or keys_here == false or pane ~= EDIT or doc ~= "edit"
    or (editor.shown ~= "buffer" and editor.shown ~= "split") or not ev or type(ev.text) ~= "string" then
    return
  end
  if editor.go or (editor.find and editor.find.open and editor.find.typing) then return end
  buffer.insert(editor, ev.text)
  editor_note("Pasted")
  redraw()
  return true
end)

-- ---- surviving a reload ------------------------------------------------------

-- What the panel holds is saved as it changes (a desktop reload runs no
-- shutdown hooks), a second after the last change, and put back when a
-- reload opens the panel again: the folder, the folders open in it, the tabs
-- with their carets, and the text of a tab with unsaved work in it.

--- This process: its id and when it started (Linux). A reload keeps the
--- process; a new start of bone does not, so this tells the two apart.
local function process_mark()
  local f = io.open("/proc/self/stat", "r")
  if not f then return nil end
  local line = f:read("*l") or ""
  f:close()
  -- The name in parentheses may hold spaces: the fields after it are fixed.
  local pid, rest = line:match("^(%d+) %b() (.*)$")
  if not pid then return nil end
  local fields = {}
  for w in rest:gmatch("%S+") do fields[#fields + 1] = w end
  -- starttime is field 22 overall: the 20th after the name.
  return pid .. ":" .. tostring(fields[20])
end
local SESSION_TEXT = 2 * 1024 * 1024 -- the most unsaved text kept per tab

function act.save_now()
  if not (panel and panel:is_open()) then return end
  local open_dirs = {}
  for dir in pairs(listing.open) do open_dirs[#open_dirs + 1] = dir end
  local tabs = {}
  for _, t in ipairs(docs) do
    if t.kind == "edit" then
      local e = t.ed
      local entry = { kind = "edit", path = e.path, line = e.line, col = e.col, shown = e.shown }
      if e.dirty then
        local body = text.join(e.lines, e.trailing)
        if #body <= SESSION_TEXT then entry.text, entry.disk_hash = body, e.disk_hash end
      end
      tabs[#tabs + 1] = entry
    else
      tabs[#tabs + 1] = { kind = "preview", path = t.path, name = t.name }
    end
  end
  local data = {
    shown = true, process = process_mark(), root = listing.root, chosen = listing.chosen or false, hidden = listing.hidden,
    open = open_dirs, side = side, pane = pane, docs = tabs, doc_at = doc_at,
    following = act.following or false,
  }
  -- Written only when it says something new.
  local ok, encoded = pcall(bone.json.encode, data)
  if ok and encoded == act.saved_as then return end
  act.saved_as = ok and encoded or nil
  data.at = os.time()
  pcall(bone.state.save, SESSION, data)
end

--- A save a second after the first change, taking every change made by then
--- (not put off by each one: the panel redraws often).
function act.save_soon()
  if act.save_pending then return end
  act.save_pending = true
  bone.defer(1000, function()
    act.save_pending = false
    act.save_now()
  end)
end

--- Put back what was saved, after the panel opened again.
function act.restore()
  local ok, saved = pcall(bone.state.load, SESSION)
  if not ok or type(saved) ~= "table" or not saved.root or os.time() - (saved.at or 0) > 86400 then return end
  listing.hidden = saved.hidden and true or false
  listing.chosen = saved.chosen and true or false
  open_folder(saved.root)
  for _, dir in ipairs(saved.open or {}) do listing.open[dir] = true end
  build_rows()
  act.following = saved.following and true or false
  for _, t in ipairs(saved.docs or {}) do
    if t.kind == "edit" and t.path and fileops.exists(t.path) then
      open_editor(t.path, t.line)
      local at = act.tab_of(t.path)
      local e = at and docs[at] and docs[at].ed
      if e then
        if t.text then
          local lines, trailing = text.split(t.text)
          e.lines, e.trailing = lines, trailing
          e.dirty = t.text ~= e.original
          e.version = (e.version or 0) + 1
          -- The file moved while the reload happened: say so, as a save would.
          if t.disk_hash and t.disk_hash ~= e.disk_hash then e.conflict = true end
        end
        buffer.place(e, t.line or 1, t.col or 0)
        e.shown = t.shown or "buffer"
      end
    elseif t.kind == "preview" and t.path and fileops.exists(t.path) then
      open_preview({ path = t.path, name = t.name or name_of(t.path) })
    end
  end
  if #docs > 0 then act.show_tab(math.max(1, math.min(saved.doc_at or 1, #docs))) end
  side = saved.side or FILES
  local want = saved.pane
  if (want == EDIT and doc ~= "edit") or (want == PREVIEW and doc ~= "preview") then want = side end
  if want == SEARCH or want == CHANGED or want == FILES or want == EDIT or want == PREVIEW then set_pane(want) end
  if panel and panel:is_open() then panel:update(chrome()) end
  redraw()
end

-- ---- files named in the chat ------------------------------------------------------

-- The paths a reply names, as chips under it in the desktop's chat: pressed,
-- the file opens in the panel at its line. Found in the text: `path`,
-- `path:42`, `path:12-40`, `path#L42`, and Markdown links to files; only
-- paths that are there count.
local refs_seen = {} -- a reply's text -> its refs, kept while the chat shows it
local refs_count = 0

local function ref_path(p, cwd)
  p = p:gsub("^file://", ""):gsub("%%20", " ")
  if p:sub(1, 2) == "~/" then p = (os.getenv("HOME") or "") .. p:sub(2) end
  if p:sub(1, 1) ~= "/" then p = cwd:gsub("/$", "") .. "/" .. p:gsub("^%./", "") end
  local parts = {}
  for part in p:gmatch("[^/]+") do
    if part == ".." then table.remove(parts) elseif part ~= "." then parts[#parts + 1] = part end
  end
  return "/" .. table.concat(parts, "/")
end

function act.refs_in(text)
  if refs_seen[text] then return refs_seen[text] end
  local cwd = home()
  local out, seen = {}, {}
  local function add(raw, line, end_line, label_text)
    if not raw or raw == "" or #raw > 300 or raw:match("^%a[%w+.-]*://") and not raw:match("^file://") then return end
    raw = raw:gsub("[%.,;:!?%)%]]+$", "")
    -- A word with no slash and no extension is not a path (`main`, `true`).
    if not raw:find("/", 1, true) and not raw:match("%.[%w]+$") then return end
    -- The chat's folder first, then the one the panel shows.
    local path = ref_path(raw, cwd)
    local f0 = io.open(path, "rb")
    if f0 then f0:close() elseif bone.fs.list(path) == nil and listing.root ~= "" and listing.root ~= cwd then
      local other = ref_path(raw, listing.root)
      local f1 = io.open(other, "rb")
      if f1 then f1:close() path = other elseif bone.fs.list(other) ~= nil then path = other end
    end
    -- A folder lists (and on Linux opens too, so it is asked first).
    local is_dir = bone.fs.list(path) ~= nil
    local is_file = false
    if not is_dir then
      local f = io.open(path, "rb")
      is_file = f ~= nil
      if f then f:close() end
    end
    if not is_file and not is_dir then return end
    -- One chip a file: the one with a line, when it is named both ways.
    local held = seen[path]
    if held then
      if line and not held.line then held.line, held.end_line = tonumber(line), tonumber(end_line) end
      -- Every way the reply writes it, for a terminal to find in its lines.
      held.texts[#held.texts + 1] = raw
      if line then held.texts[#held.texts + 1] = raw .. ":" .. line .. ((end_line and end_line ~= "") and ("-" .. end_line) or "") end
      if label_text then held.texts[#held.texts + 1] = label_text end
      return
    end
    if #out >= 10 then return end
    local label = raw:match("([^/]+)/?$") or raw
    if not is_dir and #out > 0 then
      -- Two files of one name: the folder says which.
      for _, o in ipairs(out) do
        if o.label == label and o.path ~= path then label = (raw:match("([^/]+/[^/]+)$") or raw) break end
      end
    end
    local ref = { path = path, label = label, line = tonumber(line), end_line = tonumber(end_line), dir = is_dir,
      texts = { raw } }
    if line then ref.texts[2] = raw .. ":" .. line .. ((end_line and end_line ~= "") and ("-" .. end_line) or "") end
    if label_text then ref.texts[#ref.texts + 1] = label_text end
    seen[path] = ref
    out[#out + 1] = ref
  end
  -- Markdown links: [text](path:42) and [text](path#L42-L50).
  for label_text, target in text:gmatch("%[([^%]\n]*)%]%(([^%)%s]+)%)") do
    local p, a, b = target:match("^(.-)#L(%d+)%-?L?(%d*)$")
    if not p then p, a, b = target:match("^(.-):(%d+)%-?(%d*)$") end
    add(p or target, a, b ~= "" and b or nil, label_text ~= "" and label_text or nil)
  end
  -- In code: `src/app.lua:42`, `util.py`.
  for inner in text:gmatch("`([^`\n]+)`") do
    local p, a, b = inner:match("^([^%s:]+):(%d+)%-?(%d*)$")
    if p then add(p, a, b ~= "" and b or nil)
    elseif inner:match("^[^%s]+$") then
      local q, la, lb = inner:match("^(.-)#L(%d+)%-?L?(%d*)$")
      add(q or inner, la, lb ~= "" and lb or nil)
    end
  end
  -- Plain text: a/b/c.ext:42, or a path with a slash and an extension.
  for p, a, b in text:gmatch("([%w%._~/%-]+%.%w+):(%d+)%-?(%d*)") do add(p, a, b ~= "" and b or nil) end
  for p in text:gmatch("[%s%(]([%w%._~%-]*/[%w%._/%-]+%.%w+)") do add(p) end
  refs_count = refs_count + 1
  if refs_count > 400 then refs_seen, refs_count = {}, 0 end
  refs_seen[text] = out
  return out
end

--- Open a named file in the panel (the panel too, when it is closed): at its
--- line, the lines it names lit.
function act.open_ref(r)
  if not (panel and panel:is_open()) then open() end
  if r.dir then
    listing.chosen = true
    open_folder(r.path)
    return
  end
  reveal(r.path)
  if doc == "edit" and editor.path == r.path and r.line then
    local first = math.max(1, math.min(r.line, #editor.lines))
    local last = math.max(first, math.min(r.end_line or first, #editor.lines))
    buffer.place(editor, first, #(text.leading(editor.lines[first] or "")))
    local lit = {}
    for i = first, last do lit[i] = true end
    editor.flash = lit
    local token = {}
    editor.flash_token = token
    local ed = editor
    bone.defer(2600, function()
      if ed.flash_token == token then ed.flash = nil redraw() end
    end)
  end
  bone.defer(30, function() if panel and panel:is_open() then panel:focus() end end)
  redraw()
end

--- The desktop's assistant replies, with the files they name under them.
local function link_chat()
  if not (GUI and look and look.ref_chips) then return end
  local views = bone.ui.views
  if not views or not views.assistant then return end
  -- The view as bone drew it, kept on the table once: a reload of this
  -- plugin wraps that again, not the wrapper it left behind.
  if views.assistant ~= views._files_wrapper then views._files_original = views.assistant end
  local base = views._files_original
  if not base then return end
  local wrapped = function(item, ctx)
    local out = base(item, ctx)
    if not out or not out.node or item.streaming or type(item.text) ~= "string" or item.text == "" then return out end
    local ok, refs = pcall(act.refs_in, item.text)
    if not ok or #refs == 0 then return out end
    out.node = { direction = "column", out.node, look.ref_chips(refs, function(r) act.open_ref(r) end) }
    return out
  end
  views._files_wrapper = wrapped
  views.assistant = wrapped
end
-- In a terminal the paths in a reply are drawn as links (FilesTLink) and a
-- press on one opens it: the lines a reply is drawn as are the view's own, so
-- where each path sits is known when they are made.
bone.hl.set("FilesTLink", { link = "ToolPath", underline = true, default = true })
local chat_links = {} -- an item's key -> { [line] = { { from, to, ref } } }

local function cells(s) return bone.text.width(s) end

--- `lines` (a view's) with the texts of `refs` cut out as links; the places
--- of the links, by line.
local function linked(lines, refs)
  local wanted = {}
  for _, r in ipairs(refs) do
    for _, t in ipairs(r.texts or {}) do
      if t and #t >= 3 then wanted[#wanted + 1] = { text = t, ref = r } end
    end
  end
  -- The longest first, so src/app.lua:4-6 is found before src/app.lua.
  table.sort(wanted, function(a, b) return #a.text > #b.text end)
  local places = {}
  for li, line in ipairs(lines) do
    if type(line) == "table" then
      local out, col = {}, 0
      for _, sp in ipairs(line) do
        local t, g = (type(sp) == "table") and sp[1] or tostring(sp), (type(sp) == "table") and sp[2] or nil
        if type(t) ~= "string" then
          out[#out + 1] = sp
        else
          local at = 1
          while at <= #t do
            local best_a, best_b, best_ref
            for _, w in ipairs(wanted) do
              local a, b = t:find(w.text, at, true)
              if a and (not best_a or a < best_a) then best_a, best_b, best_ref = a, b, w.ref end
            end
            if not best_a then break end
            if best_a > at then
              local before = t:sub(at, best_a - 1)
              out[#out + 1] = { before, g }
              col = col + cells(before)
            end
            local piece = t:sub(best_a, best_b)
            out[#out + 1] = { piece, "FilesTLink" }
            local w = cells(piece)
            places[li] = places[li] or {}
            places[li][#places[li] + 1] = { from = col, to = col + w, ref = best_ref }
            col = col + w
            at = best_b + 1
          end
          if at <= #t then
            local rest = t:sub(at)
            out[#out + 1] = { rest, g }
            col = col + cells(rest)
          end
        end
      end
      lines[li] = out
    end
  end
  return lines, places
end

local function link_chat_tui()
  local views = bone.ui.views
  if not views or not views.assistant then return end
  if views.assistant ~= views._files_wrapper then views._files_original = views.assistant end
  local base = views._files_original
  if not base then return end
  local wrapped = function(item, ctx)
    local out = base(item, ctx)
    if type(out) ~= "table" or item.streaming or type(item.text) ~= "string" or item.text == "" then return out end
    local ok, refs = pcall(act.refs_in, item.text)
    if not ok or #refs == 0 then return out end
    local lines, places = linked(out, refs)
    if item.key then chat_links[item.key] = places end
    return lines
  end
  views._files_wrapper = wrapped
  views.assistant = wrapped
  -- Replies drawn before this was here are drawn again, with their links.
  pcall(bone.chat.redraw)
end

--- A press on a link in the chat: the path under it, opened.
function act.chat_press(ev)
  if not (ev.index and ev.line and ev.col) then return nil end
  local item = bone.chat.item(ev.index)
  local places = item and item.key and chat_links[item.key]
  local here = places and places[ev.line]
  if not here then return nil end
  local x = ev.col - 1
  for _, p in ipairs(here) do
    if x >= p.from and x < p.to then
      act.open_ref(p.ref)
      return true
    end
  end
  return nil
end

--- The files the last reply named, to choose one from.
function act.pick_named()
  local items = bone.chat.items({ kind = "assistant", last = 1 }) or {}
  local item = items[#items]
  local refs = (item and type(item.text) == "string") and act.refs_in(item.text) or {}
  if #refs == 0 then
    bone.notify("The last reply names no file that is here.", "info")
    return
  end
  bone.ui.select(refs, {
    prompt = "Files in the last reply",
    format = function(r)
      return relative(r.path) .. (r.line and (":" .. r.line .. ((r.end_line and r.end_line ~= r.line) and ("-" .. r.end_line) or "")) or "")
        .. (r.dir and "/" or "")
    end,
    on_choice = function(r) if r then act.open_ref(r) end end,
  })
end

if SETTINGS.link_files then
  if GUI then
    link_chat()
    bone.on("ready", function() link_chat() end)
  else
    link_chat_tui()
    bone.on("ready", function() link_chat_tui() end)
  end
end

-- ---- the events ------------------------------------------------------------

bone.on("tool/finished", catch_up)
bone.on("turn/finished", function()
  if not panel or not panel:is_open() then return end
  catch_up()
  fetch_git()
end)

bone.on("resize", function()
  if panel and panel:is_open() then panel:update({ size = size_for() }) end
end)

--- After a runtime reload the panel is gone: a TUI `ready` says which ones were
--- open, so this puts this one back.
bone.on("ready", function(ev)
  local back = false
  for _, id in ipairs(ev and ev.panels or {}) do
    if id == ID then back = true end
  end
  -- The desktop's ready says nothing: the saved session says whether this
  -- panel was open, and in this very process (a reload, not a new start).
  if not back then
    local ok, saved = pcall(bone.state.load, SESSION)
    local mark = process_mark()
    back = ok and type(saved) == "table" and saved.shown == true and mark ~= nil and saved.process == mark
  end
  if back and not (panel and panel:is_open()) then
    panel = nil
    open()
    act.restore()
  end
end)

bone.plugin.on_shutdown(function()
  -- The chat's replies as bone draws them again: the view is the chat's,
  -- not this plugin's, so ownership would not put it back.
  local views = bone.ui.views
  if views and views._files_wrapper and views.assistant == views._files_wrapper and views._files_original then
    views.assistant = views._files_original
    views._files_wrapper = nil
  end
  -- Plugin ownership also removes the panel, the commands and the jobs.
  watcher = watcher + 1
  stop_job("git")
  stop_job("search")
  panel = nil
end)


