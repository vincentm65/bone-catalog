-- Which system the panel runs on, and the commands that differ between
-- them: hashing a file, opening it with the desktop's app, the Trash, the
-- package manager that installs a tool, and where the plugin keeps what it
-- makes. Linux is what this is tried on; macOS takes the BSD tools and its
-- own `open`; Windows runs jobs in PowerShell, so a job there is a PowerShell
-- line.

local M = {}

local os_name = (jit and jit.os) or "Linux"
local arch = (jit and jit.arch) or "x64"

M.linux = os_name == "Linux"
M.mac = os_name == "OSX"
M.windows = os_name == "Windows"
M.arch = arch -- "x64" or "arm64"
M.name = M.mac and "macOS" or M.windows and "Windows" or "Linux"

--- A single quote around a value, for the shell (PowerShell on Windows).
function M.quoted(value)
  value = tostring(value)
  if M.windows then return "'" .. value:gsub("'", "''") .. "'" end
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

--- Where the plugin keeps what it makes and fetches.
function M.cache(...)
  local base
  if M.windows then
    base = (os.getenv("LOCALAPPDATA") or os.getenv("TEMP") or "C:\\Temp") .. "\\bone\\files"
  elseif M.mac then
    base = (os.getenv("HOME") or "/tmp") .. "/Library/Caches/bone/files"
  else
    base = (os.getenv("XDG_CACHE_HOME") or ((os.getenv("HOME") or "/tmp") .. "/.cache")) .. "/bone/files"
  end
  local sep = M.windows and "\\" or "/"
  for _, part in ipairs({ ... }) do base = base .. sep .. part end
  return base
end

--- The shell that prints the SHA-256 of the file in $f (its first 64 hex).
function M.sha256_of_f()
  if M.mac then return "shasum -a 256 < \"$f\" | cut -c1-64" end
  return "sha256sum < \"$f\" | cut -c1-64"
end

--- Opening `path` with the desktop's own app, as a job's command.
function M.open_cmd(path)
  if M.mac then return "open " .. M.quoted(path) end
  if M.windows then return "Start-Process " .. M.quoted(path) end
  return "xdg-open " .. M.quoted(path) .. " >/dev/null 2>&1 &"
end

--- The package manager here, and the line that installs `what` with it
--- (a terminal runs it: it may ask for a password). nil when none is known.
function M.install_line(what)
  local function has(cmd)
    local p = io.popen("command -v " .. cmd .. " 2>/dev/null")
    local out = p and p:read("*a") or ""
    if p then p:close() end
    return out:match("%S") ~= nil
  end
  if M.windows then return "winget install --id Gyan.FFmpeg -e" end
  if M.mac then
    if has("brew") then return "brew install " .. what end
    if has("port") then return "sudo port install " .. what end
    return nil
  end
  if has("pacman") then return "sudo pacman -S --needed " .. what end
  if has("apt-get") then return "sudo apt-get install -y " .. what end
  if has("dnf") then return "sudo dnf install -y " .. what end
  if has("zypper") then return "sudo zypper install -y " .. what end
  if has("apk") then return "sudo apk add " .. what end
  if has("xbps-install") then return "sudo xbps-install -y " .. what end
  if has("emerge") then return "sudo emerge media-video/" .. what end
  if has("nix-env") then return "nix-env -iA nixpkgs." .. what end
  if has("brew") then return "brew install " .. what end
  return nil
end

return M
