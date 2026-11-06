-- GIFs without anything installed: the file decoded in Lua (its LZW, its
-- palettes, its frames laid over each other as the format says) and each
-- frame written as a PNG the desktop can draw, with its delay. The PNGs are
-- compressed by a small DEFLATE of this file's own (fixed codes, LZ77
-- matches), so a frame of flat color costs little on disk.
--
-- M.decode(data) -> { width, height, frames = { { delay } }, loop } and a
-- step function: each call decodes one frame (so the panel stays responsive),
-- `frame_png(i)` gives frame i's PNG bytes while it is current.

local M = {}

local ok_ffi, ffi = pcall(require, "ffi")
local bit = require("bit")
local band, bor, bxor, rshift, lshift = bit.band, bit.bor, bit.bxor, bit.rshift, bit.lshift

M.MAX_FRAMES = 400
M.MAX_PIXELS = 4096 * 4096

local function bytes(n)
  if ok_ffi then return ffi.new("uint8_t[?]", n) end
  local t = {}
  for i = 0, n - 1 do t[i] = 0 end
  return t
end

local function copy(dst, src, n)
  if ok_ffi then ffi.copy(dst, src, n) return end
  for i = 0, n - 1 do dst[i] = src[i] end
end

-- ---- PNG ---------------------------------------------------------------------

local crc_table = {}
for n = 0, 255 do
  local c = n
  for _ = 1, 8 do
    if band(c, 1) == 1 then c = bxor(0xEDB88320, rshift(c, 1)) else c = rshift(c, 1) end
  end
  crc_table[n] = c
end

local function crc32(s)
  local c = 0xFFFFFFFF
  for i = 1, #s do c = bxor(crc_table[band(bxor(c, s:byte(i)), 0xFF)], rshift(c, 8)) end
  return bxor(c, 0xFFFFFFFF)
end

local function u32(n)
  n = n % 4294967296
  return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
end

local function chunk(kind, data)
  return u32(#data) .. kind .. data .. u32(crc32(kind .. data))
end

-- Fixed-code DEFLATE with greedy LZ77 matches (a 3-byte hash, its last place).
local LEN_BASE = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 }
local LEN_EXTRA = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 }
local DIST_BASE = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073,
  4097, 6145, 8193, 12289, 16385, 24577 }
local DIST_EXTRA = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 }

-- The length code (1..29) of each match length.
local len_code = {}
for l = 3, 258 do
  local i = 1
  while i < 29 and LEN_BASE[i + 1] <= l do i = i + 1 end
  if l == 258 then i = 29 end
  len_code[l] = i
end

local function reverse(code, n)
  local r = 0
  for _ = 1, n do r = bor(lshift(r, 1), band(code, 1)) code = rshift(code, 1) end
  return r
end

-- The fixed literal/length codes, bit-reversed for an LSB-first stream.
local fixed = {}
for v = 0, 287 do
  local code, n
  if v <= 143 then code, n = 0x30 + v, 8
  elseif v <= 255 then code, n = 0x190 + (v - 144), 9
  elseif v <= 279 then code, n = v - 256, 7
  else code, n = 0xC0 + (v - 280), 8 end
  fixed[v] = { reverse(code, n), n }
end
local fixed_dist = {}
for d = 0, 29 do fixed_dist[d] = reverse(d, 5) end

local function dist_index(d)
  local lo, hi = 1, 30
  while lo < hi do
    local mid = math.floor((lo + hi + 1) / 2)
    if DIST_BASE[mid] <= d then lo = mid else hi = mid - 1 end
  end
  return lo
end

--- `src` (n bytes, from 0) deflated, as a string.
local function deflate(src, n)
  local out, acc, nbits = {}, 0, 0
  local outn = 0
  local function put(v, k)
    acc = bor(acc, lshift(v, nbits))
    nbits = nbits + k
    while nbits >= 8 do
      outn = outn + 1
      out[outn] = string.char(band(acc, 0xFF))
      acc = rshift(acc, 8)
      nbits = nbits - 8
    end
  end
  put(1, 1) -- the last block
  put(1, 2) -- fixed codes
  local head = {}
  local i = 0
  while i < n do
    local best, bestd = 0, 0
    if i + 2 < n then
      local h = src[i] * 65536 + src[i + 1] * 256 + src[i + 2]
      local p = head[h]
      head[h] = i
      if p and i - p <= 32768 then
        local l = 0
        local max = math.min(258, n - i)
        while l < max and src[p + l] == src[i + l] do l = l + 1 end
        if l >= 3 then best, bestd = l, i - p end
      end
    end
    if best >= 3 then
      local li = len_code[best]
      local c = fixed[256 + li]
      put(c[1], c[2])
      if LEN_EXTRA[li] > 0 then put(best - LEN_BASE[li], LEN_EXTRA[li]) end
      local di = dist_index(bestd)
      put(fixed_dist[di - 1], 5)
      if DIST_EXTRA[di] > 0 then put(bestd - DIST_BASE[di], DIST_EXTRA[di]) end
      -- The places inside the match, so later ones can point at them.
      for k = i + 1, math.min(i + best - 1, n - 3) do
        head[src[k] * 65536 + src[k + 1] * 256 + src[k + 2]] = k
      end
      i = i + best
    else
      local c = fixed[src[i]]
      put(c[1], c[2])
      i = i + 1
    end
  end
  local c = fixed[256]
  put(c[1], c[2])
  if nbits > 0 then outn = outn + 1 out[outn] = string.char(band(acc, 0xFF)) end
  return table.concat(out)
end

local function adler32(src, n)
  local a, b = 1, 0
  for i = 0, n - 1 do
    a = (a + src[i]) % 65521
    b = (b + a) % 65521
  end
  return b * 65536 + a
end

--- An RGBA picture (w*h*4 bytes, from 0) as PNG bytes.
function M.png(rgba, w, h)
  local stride = w * 4
  local raw = bytes((stride + 1) * h)
  for y = 0, h - 1 do
    local row = y * (stride + 1)
    raw[row] = 0 -- no filter
    if ok_ffi then
      ffi.copy(raw + row + 1, rgba + y * stride, stride)
    else
      for x = 0, stride - 1 do raw[row + 1 + x] = rgba[y * stride + x] end
    end
  end
  local n = (stride + 1) * h
  local z = "\120\1" .. deflate(raw, n) .. u32(adler32(raw, n))
  local ihdr = u32(w) .. u32(h) .. "\8\6\0\0\0"
  return "\137PNG\r\n\26\n" .. chunk("IHDR", ihdr) .. chunk("IDAT", z) .. chunk("IEND", "")
end

-- ---- GIF ---------------------------------------------------------------------

--- The codes of an image's LZW data, as palette indices (count of them).
local function lzw(data, min_size, count)
  local out = bytes(count)
  local clear = lshift(1, min_size)
  local stop = clear + 1
  local size = min_size + 1
  local next_code = clear + 2
  local prefix, suffix, first = {}, {}, {}
  for c = 0, clear - 1 do suffix[c] = c first[c] = c end
  local pos, acc, nbits = 1, 0, 0
  local outn = 0
  local prev = -1
  local stack = {}
  while outn < count do
    while nbits < size do
      local b = data:byte(pos)
      if not b then return out, outn end
      acc = bor(acc, lshift(b, nbits))
      nbits = nbits + 8
      pos = pos + 1
    end
    local code = band(acc, lshift(1, size) - 1)
    acc = rshift(acc, size)
    nbits = nbits - size
    if code == clear then
      size = min_size + 1
      next_code = clear + 2
      prev = -1
    elseif code == stop then
      break
    else
      local cur = code
      local sp = 0
      if code >= next_code then
        -- The code being made: the last one, then its own first index.
        if prev < 0 then break end
        sp = sp + 1
        stack[sp] = first[prev]
        cur = prev
      end
      while cur >= clear do
        sp = sp + 1
        stack[sp] = suffix[cur]
        cur = prefix[cur]
        if not cur then break end
      end
      if not cur then break end
      sp = sp + 1
      stack[sp] = cur
      local head_index = cur
      for k = sp, 1, -1 do
        if outn >= count then break end
        out[outn] = stack[k]
        outn = outn + 1
      end
      if prev >= 0 and next_code < 4096 then
        prefix[next_code] = prev
        suffix[next_code] = head_index
        first[next_code] = first[prev]
        next_code = next_code + 1
        if next_code == lshift(1, size) and size < 12 then size = size + 1 end
      end
      prev = code
    end
  end
  return out, outn
end

local function u16(s, at) return s:byte(at) + s:byte(at + 1) * 256 end

local function palette(s, at, n)
  local p = {}
  for i = 0, n - 1 do
    p[i] = { s:byte(at + i * 3), s:byte(at + i * 3 + 1), s:byte(at + i * 3 + 2) }
  end
  return p
end

--- What the GIF is, and a stepper that lays one frame at a time over the
--- picture. nil and why when it is not one.
function M.open(data)
  if data:sub(1, 3) ~= "GIF" then return nil, "not a GIF" end
  local W, H = u16(data, 7), u16(data, 9)
  if W <= 0 or H <= 0 or W * H > M.MAX_PIXELS then return nil, "a GIF this size is not drawn here" end
  local packed = data:byte(11)
  local pos = 14
  local global
  if band(packed, 0x80) ~= 0 then
    local n = lshift(1, band(packed, 7) + 1)
    global = palette(data, pos, n)
    pos = pos + n * 3
  end
  local canvas = bytes(W * H * 4)
  local saved = nil
  local gce = { delay = 10, disposal = 0, transparent = nil }
  local last_disposal, last_rect = 0, nil
  local g = { width = W, height = H, frames = 0, loop = true, done = false }

  --- The next frame: true and its delay (ms) when one was laid; false at the end.
  function g.step()
    while true do
      local b = data:byte(pos)
      if not b or b == 0x3B then g.done = true return false end
      if b == 0x21 then
        local label = data:byte(pos + 1)
        pos = pos + 2
        if label == 0xF9 and data:byte(pos) == 4 then
          local p = data:byte(pos + 1)
          gce.disposal = band(rshift(p, 2), 7)
          gce.delay = u16(data, pos + 2) * 10
          gce.transparent = band(p, 1) == 1 and data:byte(pos + 4) or nil
        end
        -- Skip the sub-blocks.
        while true do
          local n = data:byte(pos)
          if not n or n == 0 then pos = pos + 1 break end
          pos = pos + 1 + n
        end
      elseif b == 0x2C then
        -- What the frame before asked to be done once it had been shown.
        if last_disposal == 2 and last_rect then
          local x0, y0, w0, h0 = last_rect[1], last_rect[2], last_rect[3], last_rect[4]
          for y = y0, math.min(H, y0 + h0) - 1 do
            for x = x0, math.min(W, x0 + w0) - 1 do
              local o = (y * W + x) * 4
              canvas[o], canvas[o + 1], canvas[o + 2], canvas[o + 3] = 0, 0, 0, 0
            end
          end
        elseif last_disposal == 3 and saved then
          copy(canvas, saved, W * H * 4)
        end
        local x0, y0, w, h = u16(data, pos + 1), u16(data, pos + 3), u16(data, pos + 5), u16(data, pos + 7)
        local ip = data:byte(pos + 9)
        pos = pos + 10
        local pal = global
        if band(ip, 0x80) ~= 0 then
          local n = lshift(1, band(ip, 7) + 1)
          pal = palette(data, pos, n)
          pos = pos + n * 3
        end
        local interlaced = band(ip, 0x40) ~= 0
        local min_size = data:byte(pos)
        pos = pos + 1
        local parts = {}
        while true do
          local n = data:byte(pos)
          if not n or n == 0 then pos = pos + 1 break end
          parts[#parts + 1] = data:sub(pos + 1, pos + n)
          pos = pos + 1 + n
        end
        if gce.disposal == 3 then
          saved = saved or bytes(W * H * 4)
          copy(saved, canvas, W * H * 4)
        end
        local idx = lzw(table.concat(parts), min_size, w * h)
        -- Interlaced rows come in four passes.
        local rows = {}
        if interlaced then
          for _, pass in ipairs({ { 0, 8 }, { 4, 8 }, { 2, 4 }, { 1, 2 } }) do
            for r = pass[1], h - 1, pass[2] do rows[#rows + 1] = r end
          end
        end
        local tr = gce.transparent
        pal = pal or {}
        for r = 0, h - 1 do
          local y = y0 + (interlaced and rows[r + 1] or r)
          if y < H then
            for x = 0, w - 1 do
              local X = x0 + x
              if X < W then
                local v = idx[r * w + x]
                if v ~= tr then
                  local c = pal[v]
                  if c then
                    local o = (y * W + X) * 4
                    canvas[o], canvas[o + 1], canvas[o + 2], canvas[o + 3] = c[1], c[2], c[3], 255
                  end
                end
              end
            end
          end
        end
        last_disposal, last_rect = gce.disposal, { x0, y0, w, h }
        local delay = gce.delay
        -- A delay of 0 or 10 ms plays at 100 ms, as browsers do.
        if delay <= 10 then delay = 100 end
        gce = { delay = 10, disposal = 0, transparent = nil }
        g.frames = g.frames + 1
        if g.frames >= M.MAX_FRAMES then g.done = true end
        return true, delay
      else
        g.done = true
        return false
      end
    end
  end

  --- The picture as it stands, as a PNG.
  function g.png() return M.png(canvas, W, H) end
  return g
end

return M
