-- A picture's own size, from the few bytes its header is. PNG, JPEG and the
-- three WebP bitstreams say it; a header that does not is simply no size, and
-- so is a file that cannot be read. The desktop draws the picture either way;
-- a terminal can only name it, and the size is what it names.

local M = {}

--- The pixels of the picture at `path`: `width, height`, or nothing.
function M.size(path)
  local file = io.open(path, "rb")
  if not file then return nil end
  local head = file:read(8192) or ""
  file:close()

  local function be(at, n) -- big-endian, the order PNG and JPEG write in
    local v = 0
    for i = 0, n - 1 do v = v * 256 + (head:byte(at + i) or 0) end
    return v
  end
  local function le(at, n) -- little-endian, the order WebP writes in
    local v = 0
    for i = 0, n - 1 do v = v * 256 + (head:byte(at + n - 1 - i) or 0) end
    return v
  end

  if head:sub(1, 8) == "\137PNG\r\n\026\n" then return be(17, 4), be(21, 4) end

  -- JPEG: walk the markers to a start-of-frame one (not the arithmetic,
  -- differential or tables-only ones), which carries height then width.
  if head:sub(1, 2) == "\255\216" then
    for i = 3, #head - 7 do
      local mark = head:byte(i)
      if head:byte(i - 1) == 255 and mark >= 192 and mark <= 207
        and mark ~= 196 and mark ~= 200 and mark ~= 204 then
        return be(i + 6, 2), be(i + 4, 2)
      end
    end
    return nil
  end

  if head:sub(1, 4) == "RIFF" and head:sub(9, 12) == "WEBP" then
    local fourcc = head:sub(13, 16)
    -- Extended: a canvas, one less than what is written, three bytes each.
    if fourcc == "VP8X" then return le(25, 3) + 1, le(28, 3) + 1 end
    -- The plain bitstream says its size seven bytes in: three bytes of
    -- frame, the 157 1 42 marker, then 14-bit width and height.
    if fourcc == "VP8 " and head:sub(24, 26) == "\157\1\42" then
      return le(27, 2) % 16384, le(29, 2) % 16384
    end
    -- Lossless: one run of bits, sizes written one less than they are.
    if fourcc == "VP8L" and head:byte(21) == 47 then
      local bits = le(22, 4)
      return bits % 16384 + 1, math.floor(bits / 16384) % 16384 + 1
    end
  end
  return nil
end

--- Whether the picture can be see-through: a PNG with an alpha channel or a
--- tRNS chunk before its pixels, a WebP that says it has alpha (or is
--- lossless, which may). A JPEG never is.
function M.alpha(path)
  local file = io.open(path, "rb")
  if not file then return false end
  local head = file:read(65536) or ""
  file:close()
  if head:sub(1, 8) == "\137PNG\r\n\026\n" then
    local kind = head:byte(26)
    if kind == 4 or kind == 6 then return true end
    local idat = head:find("IDAT", 1, true) or #head
    local trns = head:find("tRNS", 1, true)
    return trns ~= nil and trns < idat
  end
  if head:sub(1, 4) == "RIFF" and head:sub(9, 12) == "WEBP" then
    local fourcc = head:sub(13, 16)
    if fourcc == "VP8X" then return math.floor((head:byte(21) or 0) / 16) % 2 == 1 end
    return fourcc == "VP8L"
  end
  return false
end

return M
