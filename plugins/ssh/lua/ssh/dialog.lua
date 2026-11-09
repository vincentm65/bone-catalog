-- The SSH window: saved profiles (connect, test, edit, delete), the hosts of
-- ~/.ssh/config not saved yet, and a form for a new or changed profile.
local core = require("ssh.core")

local M = {}

local ok_style, style = pcall(require, "bone.nodes.style")
local ok_widgets, widgets = pcall(require, "bone.nodes.widgets")
if not (ok_style and ok_widgets) then style, widgets = nil, nil end

local trim = core.trim

local function ago(t)
  if not t then return nil end
  local s = os.time() - t
  if s < 60 then return "just now" end
  if s < 3600 then return math.floor(s / 60) .. " min ago" end
  if s < 86400 then return math.floor(s / 3600) .. " h ago" end
  return math.floor(s / 86400) .. " d ago"
end

-- What a test found, in a line.
local function found(res)
  if not res.ok then return res.error or "failed" end
  local os_name = res.kind == "windows" and "Windows" or "Linux/macOS"
  return os_name .. " · bone: " .. (res.bone or "?") .. " · home " .. (res.home or "?")
end

--- Open the window. `opts.edit` opens the form on that profile, `opts.new`
--- on a new one (a table of prefilled fields).
function M.open(opts)
  if not widgets then
    return bone.notify("ssh: this desktop library has no widgets; use /ssh <host>", "error")
  end
  opts = opts or {}
  local id
  local st = {
    view = "list", sel = 1, testing = {}, results = {},
    form = nil, old = nil, tried = false, errors = nil, ask = nil, focus = nil,
  }

  -- The window is built again on the next frame.
  local function refresh()
    if id then bone.ui.update(id, {}) end
    pcall(bone.gui.invalidate)
  end

  local paste_event
  local function close()
    if paste_event then bone.off(paste_event); paste_event = nil end
    if id then bone.ui.close(id); id = nil end
  end

  -- ── Rows of the list ───────────────────────────────────────────────────
  local function rows()
    local list = {}
    local saved = {}
    for _, p in ipairs(core.profiles()) do
      list[#list + 1] = { kind = "profile", profile = p }
      saved[p.host] = true
      saved[p.name] = true
    end
    list[#list + 1] = { kind = "new" }
    local extra = {}
    for _, h in ipairs(core.config_hosts()) do
      if not saved[h.name] then extra[#extra + 1] = { kind = "config", host = h } end
    end
    for i, r in ipairs(extra) do
      r.first = i == 1
      list[#list + 1] = r
    end
    return list
  end

  -- ── Acting ─────────────────────────────────────────────────────────────
  local function test(p, key)
    key = key or p.name
    if st.testing[key] then return end
    st.testing[key] = true
    refresh()
    core.probe(p, function(res)
      st.testing[key] = nil
      st.results[key] = res
      local saved = core.find(p.name)
      if saved and key == p.name then
        core.touch(saved, { test = { ok = res.ok, text = found(res), at = os.time() } })
      end
      refresh()
    end)
  end

  local function connect(p)
    core.touch(p, { last_used = os.time() })
    core.launch(p, function(err)
      if err then
        bone.notify("ssh " .. p.name .. ": " .. err, "error")
      else
        bone.notify("Opening a window on " .. p.name .. "…")
      end
    end)
    close()
  end

  local function edit(p, prefill)
    st.view = "form"
    st.old = p and p.name or nil
    st.form = {}
    for _, f in ipairs(core.FIELDS) do
      st.form[f.key] = (p and p[f.key]) or (prefill and prefill[f.key]) or ""
    end
    -- Problems with what is there already show at once (a key file since
    -- deleted); empty required fields only once saving is tried.
    st.tried, st.errors, st.focus = false, core.check(st.form, st.old), 1
    st.formkey = (st.formkey or 0) + 1
    refresh()
  end

  local function back()
    st.view, st.form, st.ask = "list", nil, nil
    refresh()
  end

  -- A form that passes its checks, saved; the profile (nil when it does not).
  local function save_form()
    st.tried = true
    st.errors = core.check(st.form, st.old)
    if st.errors then refresh() return nil end
    local base = st.old and core.find(st.old) or nil
    local p = core.from_form(st.form, base)
    if base and (base.host ~= p.host or base.user ~= p.user or base.port ~= p.port) then p.test = nil end
    core.put(p, st.old)
    st.old = p.name
    return p
  end

  local function act(r, what)
    if not r then return end
    if r.kind == "new" then return edit(nil) end
    if r.kind == "config" then
      local h = r.host
      return edit(nil, { name = h.name, host = h.name, user = "", port = "", identity = "" })
    end
    local p = r.profile
    if what == "edit" then return edit(p) end
    if what == "test" then return test(p) end
    if what == "delete" then
      st.ask = { text = "Delete " .. p.name .. "?", yes = function()
        core.remove(p.name)
        st.ask = nil
        refresh()
      end }
      return refresh()
    end
    connect(p)
  end

  -- ── Drawing ────────────────────────────────────────────────────────────
  local function heading(text, sub)
    return {
      direction = "column", padding = { 2, 8 }, margin = { 0, 0, 6, 0 },
      { text = text, hl = "Normal", bold = true, size = style.size.title },
      sub and { text = sub, hl = "Dim", size = style.size.body, margin = { 2, 0, 0, 0 } } or nil,
    }
  end

  local function section(text)
    return { text = text:upper(), hl = "Dim", size = style.size.micro, bold = true, padding = { 10, 10, 2, 10 } }
  end

  local function status_of(p)
    if st.testing[p.name] then
      return { direction = "row", gap = 6, align = "center", widgets.spinner(12),
        { text = "testing", hl = "Dim", size = style.size.small } }
    end
    local t = p.test
    if not t then return nil end
    return widgets.pill(t.ok and "OK" or "FAILED",
      { hl = t.ok and "DiffAdd" or "ErrorMsg" })
  end

  local function list_view()
    local items, selected = {}, nil
    local list = rows()
    st.sel = math.max(1, math.min(st.sel, #list))
    items[#items + 1] = heading("SSH", "Open a bone window on another machine.")
    local profiles = 0
    for _, r in ipairs(list) do if r.kind == "profile" then profiles = profiles + 1 end end
    if profiles > 0 then items[#items + 1] = section("Saved") end
    for i, r in ipairs(list) do
      local on = i == st.sel
      local click = function()
        if st.sel == i then act(r) else st.sel = i; refresh() end
      end
      if r.kind == "config" and r.first then items[#items + 1] = section("From ~/.ssh/config") end
      local node
      if r.kind == "profile" then
        local p = r.profile
        local sub = core.target(p)
        if trim(p.dir) ~= "" then sub = sub .. "  ·  " .. p.dir end
        local used = ago(p.last_used)
        node = widgets.entry(on, { {
          direction = "row", align = "center", gap = 10,
          { grow = 1, width = 0, direction = "column",
            { text = p.name, hl = "Normal", bold = true, size = style.size.body },
            { text = sub, hl = "Dim", size = style.size.small, margin = { 2, 0, 0, 0 },
              text_overflow = "ellipsis" } },
          status_of(p),
          used and { text = used, hl = "Dim", size = style.size.micro, wrap = false } or nil,
          { text = "›", hl = on and "Accent" or "Dim", size = style.size.lead },
        } }, click)
      elseif r.kind == "new" then
        if profiles == 0 then
          items[#items + 1] = { text = "No saved connections yet.", hl = "Dim", size = style.size.caption,
            padding = { 4, 10 } }
        end
        node = widgets.entry(on, { {
          direction = "row", align = "center", gap = 10,
          { text = "+", hl = "Accent", bold = true, size = style.size.lead, width = 16 },
          { text = "New connection", hl = on and "Normal" or "Accent", bold = on, size = style.size.body, grow = 1 },
        } }, click)
      else
        local h = r.host
        local sub = (h.user and (h.user .. "@") or "") .. (h.hostname or h.name)
          .. (h.port and (":" .. h.port) or "")
        node = widgets.entry(on, { {
          direction = "row", align = "center", gap = 10,
          { grow = 1, width = 0, direction = "column",
            { text = h.name, hl = "Normal", size = style.size.body },
            { text = sub, hl = "Dim", size = style.size.small, margin = { 2, 0, 0, 0 } } },
          { text = on and "save as a profile" or "", hl = "Dim", size = style.size.small },
        } }, click)
      end
      items[#items + 1] = node
      if on then selected = #items end
    end

    -- Under the list: a question, or the selected profile's last test.
    local r = list[st.sel]
    local detail
    if st.ask then
      local small = { size = style.size.caption, padding = { 3, 14 } }
      detail = widgets.detail({
        direction = "row", align = "center", gap = 8,
        { text = st.ask.text, hl = "WarningMsg", size = style.size.caption, grow = 1, width = 0 },
        widgets.button("Delete", function() st.ask.yes() end, true, false, small),
        widgets.button("Keep", function() st.ask = nil; refresh() end, false, false, small),
      })
    elseif r and r.kind == "profile" then
      local p = r.profile
      local res = st.results[p.name]
      if st.testing[p.name] then
        detail = widgets.detail("Testing " .. core.target(p) .. "…")
      elseif res and not res.ok then
        local hint = core.advice(res.error)
        detail = widgets.detail(res.error .. (hint and ("  " .. hint) or ""), "ErrorMsg")
      elseif p.test then
        detail = widgets.detail((p.test.ok and "✓ " or "✗ ") .. p.test.text .. "  (tested " .. ago(p.test.at) .. ")",
          p.test.ok and "Dim" or "ErrorMsg")
      else
        detail = widgets.detail("Not tested yet: press t.")
      end
    elseif r and r.kind == "config" then
      detail = widgets.detail("enter makes a profile from this ~/.ssh/config host.")
    else
      detail = widgets.detail("A host name, a user and where chats start; only the host is required.")
    end
    local hint = (r and r.kind == "profile")
      and "↑↓ move · enter connect · t test · e edit · d delete · n new · esc close"
      or "↑↓ move · enter choose · n new · esc close"
    return style.as_dialog(widgets.list("ssh-list", items, selected, {
      estimate = 44,
      footer = { direction = "column", widgets.divider({ margin = { 4, 0, 0, 0 } }), detail,
        widgets.hints(hint, { 0, 0 }) },
    }))
  end

  -- The form types into the selected field itself (a popup keeps the
  -- keyboard for its own controls), as /setup does.
  local function focus(i)
    st.focus = (i - 1) % #core.FIELDS + 1
  end

  -- Field `key` becomes `text`; user@host in Host fills in User.
  local function set_field(key, text)
    st.form[key] = text
    if key == "host" then
      -- A user name may have spaces (Windows: "Vincents XPS").
      local user, rest = text:match("^([^@]-%S)@(%S*)$")
      if user and trim(st.form.user) == "" then
        st.form.user, st.form.host = user, rest
      end
    end
    st.errors = core.check(st.form, st.old)
  end

  local function do_test_form()
    local errors = core.check(st.form, st.old)
    -- A test needs only a host.
    if errors and errors.host then st.tried = true; st.errors = errors; return refresh() end
    local p = core.from_form(st.form)
    test(p, "@form")
  end

  local function do_save(and_connect)
    local p = save_form()
    if not p then return end
    if and_connect then return connect(p) end
    -- Back to the list, on the saved one.
    st.view, st.form = "list", nil
    for i, r in ipairs(rows()) do
      if r.kind == "profile" and r.profile.name == p.name then st.sel = i end
    end
    refresh()
  end

  local function form_view()
    local items, selected = {}, nil
    items[#items + 1] = heading(st.old and ("Edit " .. st.old) or "New connection",
      "Fields marked * are required.")
    for i, f in ipairs(core.FIELDS) do
      local on = st.focus == i
      local value = st.form[f.key] or ""
      -- "Required" waits for a save; other mistakes show as they are typed.
      local err = (st.tried or trim(value) ~= "") and st.errors and st.errors[f.key]
      local label = {
        direction = "row", gap = 4, margin = { 0, 0, 3, 2 },
        { text = f.label, size = style.size.small, hl = on and "Accent" or "Dim", bold = on },
        f.required and { text = "*", size = style.size.small, hl = "ErrorMsg", bold = true } or nil,
      }
      local box = style.finish({
        text = on and (value .. "▏") or (value ~= "" and value or f.placeholder),
        size = style.size.body, hl = (value == "" and not on) and "Dim" or "Normal",
        bg = "InputBackground", radius = style.radius.lg, padding = { 6, 12 },
        border = 1, border_color = err and "ErrorMsg" or (on and "Accent" or "PromptBorder"),
        transition = style.motion.base,
      })
      local note = err and { text = err, size = style.size.small, hl = "ErrorMsg", margin = { 4, 0, 0, 2 } }
        or (on and f.hint and { text = f.hint, size = style.size.small, hl = "Dim", margin = { 4, 0, 0, 2 } })
        or nil
      items[#items + 1] = style.finish({
        direction = "column", margin = { 0, 8, 10, 8 }, cursor = "pointer",
        on_click = function() focus(i) refresh() end,
        label, box, note,
      })
      if on then selected = #items end
    end

    -- The test's result, with what to do about a failure; under the
    -- fields, always in view.
    local result
    local res = st.results["@form"]
    if st.testing["@form"] then
      result = { direction = "row", gap = 8, align = "center", padding = { 4, 10 },
        widgets.spinner(14), { text = "Testing " .. core.target(st.form) .. "…", hl = "Dim", size = style.size.caption } }
    elseif res then
      local box = { direction = "column", gap = 4, padding = { 8, 12 }, margin = { 6, 8, 0, 8 },
        radius = style.radius.lg, bg = "Selection" }
      box[#box + 1] = { text = (res.ok and "✓ " or "✗ ") .. found(res), hl = res.ok and "DiffAdd" or "ErrorMsg",
        size = style.size.caption }
      local hint, needs_key = core.advice(res.error)
      if not res.ok and hint then box[#box + 1] = { text = hint, hl = "Normal", size = style.size.caption } end
      if needs_key then
        local path, key = core.public_key()
        if key then
          box[#box + 1] = { text = key, hl = "Dim", size = style.size.small, font = "mono" }
          box[#box + 1] = { direction = "row", gap = 8,
            widgets.link("Copy public key", function()
              bone.clipboard.copy(key)
              bone.notify("Copied " .. path)
            end) }
        else
          box[#box + 1] = { text = "This machine has no ~/.ssh key yet: run ssh-keygen -t ed25519.",
            hl = "Normal", size = style.size.caption }
        end
      end
      result = box
    end

    local small = { padding = { 7, 14 } }
    local actions = {
      direction = "row", gap = 8, margin = { 8, 0, 2, 0 }, padding = { 0, 8 }, flex_wrap = true,
      widgets.button("Save & connect", function() do_save(true) end, true, false, small),
      widgets.button("Save", function() do_save(false) end, false, false, small),
      widgets.button("Test connection", do_test_form, false, false, small),
      widgets.button("Cancel", back, false, false, small),
    }
    -- The buttons stay in view under the fields, however long the form gets.
    return style.as_dialog(widgets.list("ssh-form-" .. st.formkey, items, selected, {
      estimate = 70,
      footer = { direction = "column", widgets.divider({ margin = { 4, 0, 0, 0 } }), result, actions,
        widgets.hints("tab next · ctrl+t test · ctrl+s save · ctrl+enter save & connect · esc back", { 6, 0 }) },
    }))
  end

  local function on_key(k)
    if st.view == "form" then
      if k == "esc" then back() return true end
      if k == "tab" or k == "down" then focus(st.focus + 1) refresh() return true end
      if k == "shift+tab" or k == "up" then focus(st.focus - 1) refresh() return true end
      if k == "enter" then
        if st.focus == #core.FIELDS then do_save(false) else focus(st.focus + 1) refresh() end
        return true
      end
      if k == "ctrl+s" then do_save(false) return true end
      if k == "ctrl+enter" then do_save(true) return true end
      if k == "ctrl+t" then do_test_form() return true end
      local f = core.FIELDS[st.focus]
      local text = bone.text.edit(st.form[f.key] or "", k)
      if text then set_field(f.key, text) refresh() end
      return true
    end
    local list = rows()
    if st.ask then
      if k == "y" or k == "enter" then st.ask.yes() return true end
      if k == "n" or k == "esc" then st.ask = nil; refresh() return true end
      return true
    end
    if k == "up" or k == "k" then st.sel = math.max(1, st.sel - 1)
    elseif k == "down" or k == "j" then st.sel = math.min(#list, st.sel + 1)
    elseif k == "home" then st.sel = 1
    elseif k == "end" then st.sel = #list
    elseif k == "enter" then act(list[st.sel]) return true
    elseif k == "e" then act(list[st.sel], "edit") return true
    elseif k == "t" then act(list[st.sel], "test") return true
    elseif k == "d" or k == "delete" then act(list[st.sel], "delete") return true
    elseif k == "n" then edit(nil) return true
    elseif k == "esc" or k == "q" then close() return true
    else return false end
    refresh()
    return true
  end

  id = bone.ui.popup({
    node = function() return st.view == "form" and form_view() or list_view() end,
    on_key = on_key,
    focus = true,
  })
  -- Pasted text goes into the selected field, on one line.
  paste_event = bone.on("paste", function(ev)
    if not id then return end
    if st.view == "form" and ev.context == "popup" then
      local f = core.FIELDS[st.focus]
      set_field(f.key, (st.form[f.key] or "") .. (ev.text or ""):gsub("[\r\n]+", " "))
      refresh()
      return true
    end
  end)
  if opts.edit then edit(opts.edit) elseif opts.new then edit(nil, opts.new) end
  return id
end

return M
