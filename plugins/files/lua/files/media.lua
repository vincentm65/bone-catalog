-- The moving and the solid in the preview: a GIF played frame by frame, a
-- video's poster and a row of pictures along it with a silent preview to
-- play, and a 3D model to turn. What they need from outside is ffmpeg, for
-- video only (and for APNG); a GIF and a model are read here in Lua.
--
-- M.load(preview, redraw) fills the preview table; the look draws it and
-- calls the actions below. Each runs against the preview it was started
-- for: a file left behind stops what was being made for it.

local P = require("files.platform")
local ffmpeg = require("files.ffmpeg")
local gif = require("files.gif")
local mesh = require("files.mesh")
local image = require("files.image")

local M = {}

local redraw = function() end
local current = nil

local function live(p) return current == p end

local function write(path, data)
  local f = io.open(path, "wb")
  if not f then return false end
  f:write(data)
  f:close()
  return true
end

local function exists(path)
  local f = io.open(path, "rb")
  if f then f:close() return true end
  return false
end

local function read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local d = f:read("*a")
  f:close()
  return d
end

local SEP = P.windows and "\\" or "/"

--- `dir` and every folder above it that is missing.
local function mkdirp(dir)
  local at = ""
  for part in dir:gmatch("[^/\\]+") do
    if at == "" and P.windows and part:match("^%a:$") then at = part
    else
      at = (at == "" and (P.windows and "" or "/") or (at .. SEP)) .. part
      if not exists(at) then pcall(bone.fs.mkdir, at) end
    end
  end
end

--- The files ffmpeg wrote as `prefix-0001.ext` on, in order.
local function numbered(dir, prefix, ext)
  local out = {}
  for i = 1, 100000 do
    local path = string.format("%s%s%s-%04d.%s", dir, SEP, prefix, i, ext)
    if not exists(path) then break end
    out[#out + 1] = path
  end
  return out
end

-- ---- GIF ---------------------------------------------------------------------

local function load_gif(p)
  local data = read(p.path)
  if not data then p.error = "The file could not be read." return end
  local key = (bone.sha256(data) or tostring(#data)):sub(1, 24)
  local dir = P.cache("gif", key)
  mkdirp(dir)
  p.anim = { frames = {}, total = 0, playing = true }
  local index = read(dir .. SEP .. "frames.txt")
  if index then
    for line in index:gmatch("[^\n]+") do
      local w, h = line:match("^size (%d+) (%d+)$")
      if w then p.width, p.height = tonumber(w), tonumber(h) else
        local file, delay = line:match("^(%S+) (%d+)$")
        if file then
          p.anim.frames[#p.anim.frames + 1] = { path = dir .. SEP .. file, delay = tonumber(delay) }
          p.anim.total = p.anim.total + tonumber(delay)
        end
      end
    end
    if #p.anim.frames > 0 then return end
  end
  local is_png = data:sub(1, 8) == "\137PNG\r\n\26\n"
  if is_png then
    -- An APNG: ffmpeg splits it; without ffmpeg it is its first frame.
    local w, h = image.size(p.path)
    p.width, p.height = w, h
    local ff = ffmpeg.find()
    if not ff then p.kind = "image" p.alpha = true return end
    p.anim.decoding = true
    ffmpeg.run("-i " .. P.quoted(p.path) .. " -vsync 0 " .. P.quoted(dir .. SEP .. "f-%04d.png"), function(ok)
      if not live(p) then return end
      p.anim.decoding = false
      local files = numbered(dir, "f", "png")
      if not ok or #files == 0 then p.kind = "image" redraw() return end
      local lines = { "size " .. tostring(w) .. " " .. tostring(h) }
      for _, f in ipairs(files) do
        p.anim.frames[#p.anim.frames + 1] = { path = f, delay = 100 }
        p.anim.total = p.anim.total + 100
        lines[#lines + 1] = f:match("[^/\\]+$") .. " 100"
      end
      write(dir .. SEP .. "frames.txt", table.concat(lines, "\n") .. "\n")
      redraw()
    end)
    return
  end
  local g, why = gif.open(data)
  if not g then p.error = "This GIF could not be read: " .. tostring(why) return end
  p.width, p.height = g.width, g.height
  p.anim.decoding = true
  local lines = { "size " .. g.width .. " " .. g.height }
  -- A frame at a time, so the panel keeps answering while it decodes.
  local function step()
    if not live(p) then return end
    local t0 = os.clock()
    while os.clock() - t0 < 0.03 do
      local ok, delay = g.step()
      if not ok then
        p.anim.decoding = false
        write(dir .. SEP .. "frames.txt", table.concat(lines, "\n") .. "\n")
        if #p.anim.frames == 0 then p.error = "There are no frames in this GIF." end
        redraw()
        return
      end
      local name = string.format("f-%04d.png", #p.anim.frames + 1)
      write(dir .. SEP .. name, g.png())
      p.anim.frames[#p.anim.frames + 1] = { path = dir .. SEP .. name, delay = delay }
      p.anim.total = p.anim.total + delay
      lines[#lines + 1] = name .. " " .. delay
    end
    redraw()
    bone.defer(0, step)
  end
  step()
end

--- The frame of an animation to show at `ms` into it.
function M.frame_at(anim, ms)
  local n = #anim.frames
  if n == 0 then return nil end
  if anim.total <= 0 then return 1 end
  local t = ms % anim.total
  for i, f in ipairs(anim.frames) do
    if t < f.delay then return i end
    t = t - f.delay
  end
  return n
end

-- ---- video -------------------------------------------------------------------

M.THUMBS = 12
M.CHUNK = 20 -- seconds of preview made at a time
M.FPS = 12

local function load_video(p)
  local ff = ffmpeg.find()
  if not ff then
    p.need_ffmpeg = true
    p.install = ffmpeg.install_line()
    return
  end
  p.loading_info = true
  ffmpeg.probe(p.path, function(info, why)
    if not live(p) then return end
    p.loading_info = false
    if not info then p.error = "This video could not be read: " .. tostring(why) redraw() return end
    p.info = info
    p.width, p.height = info.width, info.height
    local key = (bone.sha256(p.path .. "|" .. tostring(info.size) .. "|" .. tostring(info.duration)) or "v"):sub(1, 24)
    p.dir = P.cache("video", key)
    mkdirp(p.dir)
    local dur = info.duration or 0
    local poster = p.dir .. SEP .. "poster.jpg"
    local thumbs = {}
    local jobs = {}
    if not exists(poster) then
      jobs[#jobs + 1] = "-ss " .. string.format("%.2f", dur * 0.1) .. " -i " .. P.quoted(p.path)
        .. " -frames:v 1 -vf " .. P.quoted("scale='min(1280,iw)':-2") .. " -q:v 3 " .. P.quoted(poster)
    end
    for k = 1, M.THUMBS do
      local t = dur > 0 and dur * (k - 0.5) / M.THUMBS or 0
      local file = string.format("%s%st-%02d.jpg", p.dir, SEP, k)
      thumbs[k] = { path = file, at = t }
      if not exists(file) then
        jobs[#jobs + 1] = "-ss " .. string.format("%.2f", t) .. " -i " .. P.quoted(p.path)
          .. " -frames:v 1 -vf " .. P.quoted("scale=240:-2") .. " -q:v 5 " .. P.quoted(file)
      end
    end
    local function finish()
      if not live(p) then return end
      p.poster = exists(poster) and poster or nil
      p.thumbs = {}
      for _, t in ipairs(thumbs) do if exists(t.path) then p.thumbs[#p.thumbs + 1] = t end end
      redraw()
    end
    if #jobs == 0 then return finish() end
    p.making_thumbs = true
    -- One after another, the poster first: it shows as soon as it is there.
    local i = 0
    local function next_job()
      i = i + 1
      if not live(p) then return end
      if i > #jobs then p.making_thumbs = false return finish() end
      ffmpeg.run(jobs[i], function()
        if i == 1 then finish() end
        next_job()
      end, 30000)
    end
    next_job()
  end)
end

--- The preview's frames from `from` seconds: made when they are not there.
local function chunk(p, from, done)
  local id = string.format("c%06d", math.floor(from * 10))
  local frames = numbered(p.dir, id, "jpg")
  if #frames > 0 and exists(p.dir .. SEP .. id .. ".done") then return done(frames) end
  ffmpeg.run("-ss " .. string.format("%.2f", from) .. " -t " .. M.CHUNK .. " -i " .. P.quoted(p.path)
    .. " -an -vf " .. P.quoted("fps=" .. M.FPS .. ",scale='min(720,iw)':-2") .. " -q:v 5 "
    .. P.quoted(p.dir .. SEP .. id .. "-%04d.jpg"), function(ok)
      local got = numbered(p.dir, id, "jpg")
      if ok then write(p.dir .. SEP .. id .. ".done", "") end
      done(got)
    end, 180000)
end

--- Play the silent preview from `from` seconds (the start by default).
function M.play(p, from)
  if not p.info or not p.dir then return end
  local dur = p.info.duration or 0
  from = math.max(0, math.min(from or (p.clip and p.position) or 0, math.max(0, dur - 0.1)))
  p.buffering = true
  p.playing = true
  p.position = from
  redraw()
  chunk(p, from, function(frames)
    if not live(p) then return end
    p.buffering = false
    if #frames == 0 then p.playing = false p.error_note = "The preview could not be made." redraw() return end
    p.clip = { start = from, frames = frames, fps = M.FPS, t0 = nil }
    -- The next part, made while this one plays.
    local after = from + M.CHUNK
    if after < dur then chunk(p, after, function() end) end
    redraw()
  end)
end

function M.pause(p)
  p.playing = false
  if p.clip and p.clip.t0 then p.position = p.clip.start + (p.clip.elapsed or 0) end
  if p.clip then p.clip.t0 = nil end
  redraw()
end

--- Where a playing preview is, at canvas time `now` (seconds): the frame,
--- and the position in the video; at the end of its part, the next part.
function M.tick(p, now)
  local c = p.clip
  if not c then return nil end
  if not p.playing then
    local i = math.max(1, math.min(#c.frames, math.floor(((p.position or c.start) - c.start) * c.fps) + 1))
    return c.frames[i], p.position or c.start
  end
  if not c.t0 then c.t0 = now - math.max(0, (p.position or c.start) - c.start) end
  local elapsed = now - c.t0
  c.elapsed = elapsed
  local i = math.floor(elapsed * c.fps) + 1
  if i > #c.frames then
    local dur = p.info and p.info.duration or 0
    local next_from = c.start + #c.frames / c.fps
    if next_from < dur - 0.2 and not p.buffering then
      bone.defer(0, function() M.play(p, next_from) end)
    elseif not p.buffering then
      p.playing = false
      p.position = 0
      c.t0 = nil
    end
    return c.frames[#c.frames], c.start + #c.frames / c.fps
  end
  p.position = c.start + elapsed
  return c.frames[i], p.position
end

-- ---- 3D ----------------------------------------------------------------------

M.MODEL_LIMIT = 96 * 1024 * 1024

local function load_model(p)
  local f = io.open(p.path, "rb")
  local size = f and f:seek("end") or 0
  if f then f:close() end
  if size > M.MODEL_LIMIT then p.error = "This model is too big to draw here (" .. math.floor(size / 1048576) .. " MB)." return end
  local model, why = mesh.load(p.path)
  if not model then p.error = "This model could not be read: " .. tostring(why) return end
  p.model = model
  p.view = { yaw = -0.7, pitch = 0.45, zoom = 1 }
end

-- ---- loading -------------------------------------------------------------------

function M.load(p, on_change)
  redraw = on_change or redraw
  current = p
  if p.kind == "gif" then load_gif(p)
  elseif p.kind == "video" then load_video(p)
  elseif p.kind == "model" then load_model(p) end
end

-- ---- getting ffmpeg, and the desktop's player ---------------------------------------

--- Install with the system's package manager, in a terminal (it may ask
--- for a password); without a terminal the line goes on the clipboard.
function M.install(p)
  local line = ffmpeg.install_line()
  if not line then
    bone.notify("There is no package manager here that the panel knows: fetch ffmpeg instead.", "info")
    return
  end
  local ok, term = pcall(require, "bone.terminal")
  if ok and type(term) == "table" and term.open then
    local opened = pcall(term.open, nil, { cmd = line })
    if opened then
      p.installing = line
      redraw()
      return
    end
  end
  require("files.clip").copy(line, function() end)
  bone.notify("Run this in a terminal (it is on the clipboard): " .. line, "info")
end

--- Ask what a fetch would download, then show it (the panel asks first).
function M.offer_fetch(p)
  p.fetch = { state = "asking" }
  redraw()
  ffmpeg.fetch_plan(function(plan, why)
    if not live(p) then return end
    if not plan then p.fetch = { state = "failed", why = why } redraw() return end
    p.fetch = { state = "offered", plan = plan }
    redraw()
  end)
end

function M.fetch(p)
  local f = p.fetch
  if not f or not f.plan then return end
  f.state, f.bytes = "fetching", 0
  redraw()
  ffmpeg.fetch(f.plan, function(n)
    f.bytes = n
    redraw()
  end, function(ok, why)
    if not live(p) then return end
    if not ok then p.fetch = { state = "failed", why = why } redraw() return end
    p.fetch = nil
    p.need_ffmpeg = nil
    M.load(p, redraw)
    redraw()
  end)
end

--- Look for ffmpeg again (after installing it in a terminal).
function M.check_again(p)
  ffmpeg.find(true)
  if ffmpeg.find() then
    p.need_ffmpeg, p.installing, p.fetch = nil, nil, nil
    M.load(p, redraw)
  else
    p.check_note = "ffmpeg is still not on the PATH"
  end
  redraw()
end

--- The file in the desktop's player: mpv (or VLC, Celluloid) when there is
--- one, else whatever opens it.
function M.open_player(path)
  local q = P.quoted(path)
  local cmd
  if P.mac then
    cmd = "open " .. q
  elseif P.windows then
    cmd = "Start-Process " .. q
  else
    cmd = 'd=""; command -v setsid >/dev/null 2>&1 && d="setsid -f"; '
      .. "if command -v mpv >/dev/null 2>&1; then $d mpv --force-window=yes --keep-open=yes " .. q .. " >/dev/null 2>&1 </dev/null; "
      .. "elif command -v celluloid >/dev/null 2>&1; then $d celluloid " .. q .. " >/dev/null 2>&1 </dev/null; "
      .. "elif command -v vlc >/dev/null 2>&1; then $d vlc " .. q .. " >/dev/null 2>&1 </dev/null; "
      .. "else $d xdg-open " .. q .. " >/dev/null 2>&1 </dev/null; fi"
  end
  bone.job.start(cmd, { name = "files: player", timeout = 10000, buffer = true, on_exit = function() end })
end

return M
