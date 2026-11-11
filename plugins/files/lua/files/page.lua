-- A page as a browser draws it: the HTML handed to the browser that is
-- installed (Firefox, or a Chromium), run without a window, which draws it —
-- its styles, its layout, its scripts — into a picture the panel shows. The
-- plugin's own reader (files.html) knows a page's content; this is the page.
--
-- The browser runs with a profile of its own, kept in the plugin's cache: no
-- history, no cookies and no sign-ins of yours, and nothing of yours changed.
-- It loads what the page asks for, as a browser does.

local P = require("files.platform")
local image = require("files.image")

local M = {}

--- The tallest page drawn; a longer one is drawn to here.
M.MAX_HEIGHT = 8000
--- The pictures kept.
M.KEEP = 40

local CANDIDATES = {
  { "firefox", "firefox" }, { "firefox-esr", "firefox" }, { "librewolf", "firefox" },
  { "chromium", "chromium" }, { "google-chrome-stable", "chromium" }, { "google-chrome", "chromium" },
  { "brave", "chromium" },
}

local found -- nil: not looked for yet; false: none

--- The browser that draws pages here: { bin, kind = "firefox" | "chromium",
--- name }, or nil when there is none.
function M.browser()
  if found ~= nil then return found or nil end
  found = false
  if P.windows then return nil end
  for _, c in ipairs(CANDIDATES) do
    local p = io.popen("command -v " .. c[1] .. " 2>/dev/null")
    local out = p and p:read("*l") or ""
    if p then p:close() end
    if out ~= "" then
      found = { bin = out, kind = c[2], name = c[1] }
      break
    end
  end
  return found or nil
end

local function exists(path)
  local f = io.open(path, "rb")
  if f then f:close() return true end
  return false
end

--- A file's URL, its path's odd characters escaped.
function M.url(path)
  return "file://" .. path:gsub("[^%w/%-%._~]", function(c) return string.format("%%%02X", c:byte()) end)
end

--- The text with the folder it came from as the base of its links, so a
--- stylesheet or a picture beside the file is found from the cache too.
function M.based(body, base)
  local tag = '<base href="' .. M.url((base:gsub("/+$", "")) .. "/") .. '">'
  local _, at = body:lower():find("<head[^>]*>")
  if at then return body:sub(1, at) .. tag .. body:sub(at + 1) end
  return tag .. body
end

-- One browser at a time (its profile is one process's); of the pages asked
-- for meanwhile, only the last is drawn.
local running, waiting = false, nil

--- Draw `body` (the text of a page from the folder `base`) `width` points
--- wide: `done({ path, width, height, cut })` with the picture, or
--- `done(nil, why)`. A page drawn before comes from the cache.
function M.render(body, base, width, done)
  local b = M.browser()
  if not b then return done(nil, "there is no browser here to draw it (Firefox or Chromium)") end
  width = math.max(200, math.floor(tonumber(width) or 900))
  local key = (bone.sha256(body .. "|" .. base .. "|" .. width) or tostring(#body)):sub(1, 32)
  local dir = P.cache("page")
  local png = dir .. "/" .. key .. ".png"
  if exists(png) then
    local w, h = image.size(png)
    if w and h then return done({ path = png, width = w, height = h, cut = h >= M.MAX_HEIGHT }) end
  end
  if running then
    waiting = { body, base, width, done }
    return
  end
  running = true
  pcall(bone.fs.mkdir, dir .. "/profile")
  local src = dir .. "/" .. key .. ".html"
  local f = io.open(src, "wb")
  if not f then
    running = false
    return done(nil, "the cache could not be written")
  end
  f:write(M.based(body, base))
  f:close()

  local function finish(shot, why)
    running = false
    os.remove(src)
    done(shot, why)
    -- Only the newest pictures stay.
    bone.job.start("cd " .. P.quoted(dir) .. " && ls -t *.png 2>/dev/null | tail -n +" .. (M.KEEP + 1)
      .. " | while read -r f; do rm -f -- \"$f\"; done", { name = "files: page cache", timeout = 10000, buffer = true })
    if waiting then
      local w = waiting
      waiting = nil
      M.render(w[1], w[2], w[3], w[4])
    end
  end

  --- One drawing: the whole page's height, or `height` of it.
  local function shot(height, after)
    local cmd
    if b.kind == "firefox" then
      cmd = P.quoted(b.bin) .. " --headless --no-remote --profile " .. P.quoted(dir .. "/profile")
        .. " --window-size=" .. width .. (height and ("," .. height) or "")
        .. " --screenshot " .. P.quoted(png) .. " " .. P.quoted(M.url(src))
    else
      -- A Chromium draws a window's worth: a tall one.
      cmd = P.quoted(b.bin) .. " --headless --disable-gpu --hide-scrollbars --user-data-dir=" .. P.quoted(dir .. "/profile")
        .. " --window-size=" .. width .. "," .. (height or 2400)
        .. " --screenshot=" .. P.quoted(png) .. " " .. P.quoted(M.url(src))
    end
    bone.job.start(cmd .. " >/dev/null 2>&1", { name = "files: page", timeout = 40000, buffer = true,
      on_exit = function(r) after(r and r.code == 0 and exists(png)) end })
  end

  shot(nil, function(ok)
    if not ok then return finish(nil, b.name .. " did not draw it") end
    local w, h = image.size(png)
    if not (w and h) then return finish(nil, b.name .. " drew nothing that can be shown") end
    if h > M.MAX_HEIGHT and b.kind == "firefox" then
      -- Too tall for one picture: its top, to that height.
      os.remove(png)
      return shot(M.MAX_HEIGHT, function(again)
        local w2, h2 = image.size(png)
        if not again or not (w2 and h2) then return finish(nil, b.name .. " did not draw it") end
        finish({ path = png, width = w2, height = h2, cut = true })
      end)
    end
    finish({ path = png, width = w, height = h, cut = false })
  end)
end

return M
