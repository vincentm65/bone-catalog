-- ffmpeg for the panel: where it is (the plugin's own copy first, then the
-- PATH), getting it when it is not there (fetched from a known build and
-- checked against its SHA-256, or installed with the system's package
-- manager in a terminal), and what it is asked: what a video is (ffprobe),
-- a picture from it, a row of them, a short silent run of frames to play,
-- and the frames of a GIF.

local P = require("files.platform")

local M = {}

local EXE = P.windows and ".exe" or ""
local found = nil -- { ffmpeg, ffprobe } once looked for

function M.bin_dir() return P.cache("ffmpeg", "bin") end

local function exists(path)
  local f = io.open(path, "rb")
  if f then f:close() return true end
  return false
end

local function on_path(name)
  local cmd = P.windows and ("where " .. name .. " 2>NUL") or ("command -v " .. name .. " 2>/dev/null")
  local p = io.popen(cmd)
  if not p then return nil end
  local out = (p:read("*l") or ""):gsub("%s+$", "")
  p:close()
  return out ~= "" and out or nil
end

--- The ffmpeg and ffprobe to run: { ffmpeg, ffprobe, own = bool }, or nil.
function M.find(again)
  -- BONE_FILES_NO_FFMPEG=1 acts as if there were none (to try the panel's offer).
  if os.getenv("BONE_FILES_NO_FFMPEG") == "1" then return nil end
  if found ~= nil and not again then return found or nil end
  local sep = P.windows and "\\" or "/"
  local own_ff, own_fp = M.bin_dir() .. sep .. "ffmpeg" .. EXE, M.bin_dir() .. sep .. "ffprobe" .. EXE
  if exists(own_ff) and exists(own_fp) then
    found = { ffmpeg = own_ff, ffprobe = own_fp, own = true }
  else
    local ff, fp = on_path("ffmpeg"), on_path("ffprobe")
    found = (ff and fp) and { ffmpeg = ff, ffprobe = fp, own = false } or false
  end
  return found or nil
end

--- How to install it here, as a line for a terminal (nil when unknown).
function M.install_line() return P.install_line("ffmpeg") end

-- ---- fetching ---------------------------------------------------------------------

-- Where the builds come from. macOS: evermeet.cx, release 9.0.2, pinned by
-- hash (Intel; Apple silicon runs it through Rosetta). Linux: BtbN's builds
-- on GitHub, Windows: Gyan's, both checked against the SHA-256 GitHub
-- publishes for the file.
local MAC = {
  { url = "https://evermeet.cx/ffmpeg/ffmpeg-9.0.2.zip", sha256 = "4acc0be580f9b2788029eb7bd4d645ff87968911b0a62aeeb3940d42d54558d5", size = 26198325 },
  { url = "https://evermeet.cx/ffmpeg/ffprobe-9.0.2.zip", sha256 = "24a9c968cd4da72d99c7245e914b921815835eb6dff01d99868031aebaf1d439" },
}

--- What a fetch would download: { size (bytes), from } or nil (not offered here).
function M.fetch_plan(done)
  if P.mac then return done({ size = 26198325 + 26000000, from = "evermeet.cx (ffmpeg 9.0.2)" }) end
  local api, pick
  if P.windows then
    api = "https://api.github.com/repos/GyanD/codexffmpeg/releases?per_page=40"
    pick = function(releases)
      for _, r in ipairs(releases) do
        if tostring(r.tag_name):match("^%d+%.%d+") then
          for _, a in ipairs(r.assets or {}) do
            if a.name:match("essentials_build%.zip$") then return a, "Gyan's build " .. r.tag_name end
          end
        end
      end
    end
  else
    local want = P.arch == "arm64" and "linuxarm64" or "linux64"
    api = "https://api.github.com/repos/BtbN/FFmpeg-Builds/releases/tags/latest"
    pick = function(release)
      local best, best_v
      for _, a in ipairs(release.assets or {}) do
        local v = a.name:match("^ffmpeg%-n([%d.]+)%-latest%-" .. want .. "%-gpl%-[%d.]+%.tar%.xz$")
        if v then
          local major, minor = v:match("^(%d+)%.?(%d*)")
          local n = tonumber(major) * 100 + (tonumber(minor) or 0)
          if not best_v or n > best_v then best, best_v = a, n end
        end
      end
      return best, best and ("BtbN's build " .. best.name:match("n([%d.]+)")) or nil
    end
  end
  local cmd = P.windows and ("(Invoke-WebRequest -UseBasicParsing -Uri " .. P.quoted(api) .. ").Content")
    or ("curl -sSfL -H 'Accept: application/vnd.github+json' " .. P.quoted(api))
  bone.job.start(cmd, { name = "files: ffmpeg release", timeout = 20000, buffer = true,
    on_exit = function(r)
      if not r or r.code ~= 0 then return done(nil, "GitHub could not be asked which build to get") end
      local ok, doc = pcall(bone.json.decode, r.stdout or "")
      if not ok or type(doc) ~= "table" then return done(nil, "GitHub's answer could not be read") end
      local asset, from = pick(doc)
      if not asset then return done(nil, "there is no build for this system there") end
      local sha = tostring(asset.digest or ""):match("^sha256:(%x+)$")
      if not sha then return done(nil, "GitHub gives no SHA-256 for that file, so it is not fetched") end
      done({ size = asset.size, from = from, url = asset.browser_download_url, sha256 = sha:lower(), name = asset.name })
    end })
end

--- Fetch ffmpeg and ffprobe into the plugin's folder. `progress(bytes)`
--- while it downloads; `done(true)` or `done(nil, why)`.
function M.fetch(plan, progress, done)
  local dir = P.cache("ffmpeg")
  local bin = M.bin_dir()
  local tmp = P.cache("ffmpeg", "download")
  local script
  if P.mac then
    script = "set -e; mkdir -p " .. P.quoted(bin) .. " " .. P.quoted(tmp) .. "; cd " .. P.quoted(tmp) .. "; "
    for i, f in ipairs(MAC) do
      local name = "part" .. i .. ".zip"
      script = script .. "curl -sSfL -o " .. name .. " " .. P.quoted(f.url) .. "; "
        .. "[ \"$(shasum -a 256 < " .. name .. " | cut -c1-64)\" = " .. f.sha256 .. " ] || { echo 'the download is not the file it should be' >&2; exit 9; }; "
        .. "unzip -o -q " .. name .. " -d " .. P.quoted(bin) .. "; "
    end
    script = script .. "chmod +x " .. P.quoted(bin) .. "/ffmpeg " .. P.quoted(bin) .. "/ffprobe; "
      .. "xattr -d com.apple.quarantine " .. P.quoted(bin) .. "/ffmpeg " .. P.quoted(bin) .. "/ffprobe 2>/dev/null || true; "
      .. "rm -rf " .. P.quoted(tmp)
  elseif P.windows then
    local zip = tmp .. "\\ffmpeg.zip"
    script = "$ErrorActionPreference = 'Stop'; "
      .. "New-Item -ItemType Directory -Force -Path " .. P.quoted(bin) .. ", " .. P.quoted(tmp) .. " | Out-Null; "
      .. "Invoke-WebRequest -UseBasicParsing -Uri " .. P.quoted(plan.url) .. " -OutFile " .. P.quoted(zip) .. "; "
      .. "if ((Get-FileHash -Algorithm SHA256 " .. P.quoted(zip) .. ").Hash.ToLower() -ne " .. P.quoted(plan.sha256) .. ") "
      .. "{ Write-Error 'the download is not the file it should be'; exit 9 }; "
      .. "Expand-Archive -Force -Path " .. P.quoted(zip) .. " -DestinationPath " .. P.quoted(tmp .. "\\x") .. "; "
      .. "Get-ChildItem -Recurse -Path " .. P.quoted(tmp .. "\\x") .. " -Include ffmpeg.exe,ffprobe.exe | "
      .. "Copy-Item -Destination " .. P.quoted(bin) .. "; "
      .. "Remove-Item -Recurse -Force " .. P.quoted(tmp)
  else
    script = "set -e; mkdir -p " .. P.quoted(bin) .. " " .. P.quoted(tmp) .. "; cd " .. P.quoted(tmp) .. "; "
      .. "curl -sSfL -o ffmpeg.tar.xz " .. P.quoted(plan.url) .. "; "
      .. "[ \"$(sha256sum < ffmpeg.tar.xz | cut -c1-64)\" = " .. plan.sha256 .. " ] || { echo 'the download is not the file it should be' >&2; exit 9; }; "
      .. "tar -xJf ffmpeg.tar.xz; "
      .. "for b in ffmpeg ffprobe; do f=$(find . -type f -path '*/bin/'$b | head -n 1); [ -n \"$f\" ] || { echo \"no $b in it\" >&2; exit 8; }; "
      .. "cp \"$f\" " .. P.quoted(bin) .. "/$b; chmod +x " .. P.quoted(bin) .. "/$b; done; "
      .. "cd /; rm -rf " .. P.quoted(tmp)
  end
  local job = bone.job.start(script, { name = "files: fetch ffmpeg", timeout = 30 * 60 * 1000, buffer = true,
    on_exit = function(r)
      if r and r.code == 0 then
        M.find(true)
        if M.find() then return done(true) end
        return done(nil, "it was fetched but does not run here")
      end
      done(nil, ((r and r.stderr) or "the fetch failed"):gsub("%s+$", ""))
    end })
  -- The download's size, read while it runs (the file it is written to).
  local file = P.mac and (tmp .. "/part1.zip") or P.windows and (tmp .. "\\ffmpeg.zip") or (tmp .. "/ffmpeg.tar.xz")
  local function tick()
    if not job or not job:running() then return end
    local f = io.open(file, "rb")
    if f then
      local n = f:seek("end")
      f:close()
      progress(n or 0)
    end
    bone.defer(400, tick)
  end
  bone.defer(400, tick)
  return job
end

--- Remove the plugin's own copy.
function M.forget()
  local bin = M.bin_dir()
  os.remove(bin .. (P.windows and "\\ffmpeg.exe" or "/ffmpeg"))
  os.remove(bin .. (P.windows and "\\ffprobe.exe" or "/ffprobe"))
  found = nil
end

-- ---- asking it things -------------------------------------------------------------

--- What the video at `path` is: { duration, width, height, codec, fps,
--- audio, size, format } (done(info)), or done(nil, why).
function M.probe(path, done)
  local ff = M.find()
  if not ff then return done(nil, "no ffmpeg") end
  local cmd = P.quoted(ff.ffprobe) .. " -v quiet -print_format json -show_format -show_streams " .. P.quoted(path)
  if P.windows then cmd = "& " .. cmd end
  bone.job.start(cmd, { name = "files: ffprobe", timeout = 15000, buffer = true,
    on_exit = function(r)
      if not r or r.code ~= 0 then return done(nil, "ffprobe could not read it") end
      local ok, doc = pcall(bone.json.decode, r.stdout or "")
      if not ok or type(doc) ~= "table" then return done(nil, "ffprobe's answer could not be read") end
      local info = { audio = false }
      for _, st in ipairs(doc.streams or {}) do
        if st.codec_type == "video" and not info.codec and (st.disposition or {}).attached_pic ~= 1 then
          info.codec = st.codec_name
          info.width, info.height = tonumber(st.width), tonumber(st.height)
          local a, b = tostring(st.avg_frame_rate or st.r_frame_rate or ""):match("^(%d+)/(%d+)$")
          if a and tonumber(b) > 0 then info.fps = tonumber(a) / tonumber(b) end
          info.frames = tonumber(st.nb_frames)
        elseif st.codec_type == "audio" then
          info.audio = st.codec_name or true
        end
      end
      local fmt = doc.format or {}
      info.duration = tonumber(fmt.duration)
      info.size = tonumber(fmt.size)
      info.format = fmt.format_long_name or fmt.format_name
      if not info.codec then return done(nil, "there is no picture in it") end
      done(info)
    end })
end

--- Run `ffmpeg` with `args` (already quoted), done(ok, stderr).
function M.run(args, done, timeout)
  local ff = M.find()
  if not ff then return done(false, "no ffmpeg") end
  local cmd = P.quoted(ff.ffmpeg) .. " -hide_banner -loglevel error -y " .. args
  if P.windows then cmd = "& " .. cmd end
  return bone.job.start(cmd, { name = "files: ffmpeg", timeout = timeout or 120000, buffer = true,
    on_exit = function(r) done(r and r.code == 0, r and r.stderr) end })
end

return M
