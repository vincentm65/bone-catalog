-- 3D models, read in Lua: STL (text and binary), OBJ, PLY (text and binary
-- little-endian) and glTF (.gltf with its .bin beside it, or one .glb), as
-- triangles. `draw` turns a model and a view (two angles and a zoom) into
-- canvas shapes: each triangle lit by one light, the far ones first, the
-- ones facing away left out. A model with more triangles than a canvas can
-- draw is thinned to every n-th one for the picture.

local M = {}

local bit = require("bit")

M.DRAW_LIMIT = 18000 -- the most triangles drawn shaded (a canvas draws 20 000 shapes)
M.WIRE_LIMIT = 6000  -- and as lines, three each

local function f32(s, at)
  local b1, b2, b3, b4 = s:byte(at, at + 3)
  if not b4 then return 0 end
  local sign = b4 >= 128 and -1 or 1
  local exp = (b4 % 128) * 2 + math.floor(b3 / 128)
  local mant = ((b3 % 128) * 256 + b2) * 256 + b1
  if exp == 0 then
    if mant == 0 then return 0 end
    return sign * mant * 2 ^ -149
  elseif exp == 255 then
    return 0
  end
  return sign * (1 + mant / 8388608) * 2 ^ (exp - 127)
end

local function u32(s, at)
  local b1, b2, b3, b4 = s:byte(at, at + 3)
  return ((b4 * 256 + b3) * 256 + b2) * 256 + b1
end

local function u16(s, at)
  local b1, b2 = s:byte(at, at + 1)
  return b2 * 256 + b1
end

-- ---- the formats ------------------------------------------------------------------

local function stl(data)
  local tris = {}
  -- Binary: 80 bytes, a count, then 50 bytes a triangle. A text STL starts
  -- "solid" but so may a binary one: the size decides.
  if #data >= 84 then
    local n = u32(data, 81)
    if 84 + n * 50 == #data then
      for i = 0, n - 1 do
        local at = 85 + i * 50 + 12
        tris[#tris + 1] = {
          f32(data, at), f32(data, at + 4), f32(data, at + 8),
          f32(data, at + 12), f32(data, at + 16), f32(data, at + 20),
          f32(data, at + 24), f32(data, at + 28), f32(data, at + 32),
        }
      end
      return tris
    end
  end
  local v = {}
  for x, y, z in data:gmatch("vertex%s+(%S+)%s+(%S+)%s+(%S+)") do
    v[#v + 1] = tonumber(x) or 0
    v[#v + 1] = tonumber(y) or 0
    v[#v + 1] = tonumber(z) or 0
    if #v == 9 then tris[#tris + 1] = v v = {} end
  end
  return tris
end

local function obj(data)
  local vs, tris = {}, {}
  for line in data:gmatch("[^\r\n]+") do
    local kind, rest = line:match("^%s*(%S+)%s+(.*)$")
    if kind == "v" then
      local x, y, z = rest:match("(%S+)%s+(%S+)%s+(%S+)")
      vs[#vs + 1] = { tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0 }
    elseif kind == "f" then
      local ids = {}
      for ref in rest:gmatch("%S+") do
        local i = tonumber(ref:match("^(-?%d+)"))
        if i then
          if i < 0 then i = #vs + 1 + i end
          ids[#ids + 1] = vs[i]
        end
      end
      -- A polygon as a fan of triangles.
      for k = 2, #ids - 1 do
        local a, b, c = ids[1], ids[k], ids[k + 1]
        if a and b and c then
          tris[#tris + 1] = { a[1], a[2], a[3], b[1], b[2], b[3], c[1], c[2], c[3] }
        end
      end
    end
  end
  return tris
end

local function ply(data)
  local head_end = data:find("end_header", 1, true)
  if not head_end then return nil, "not a PLY file" end
  local header = data:sub(1, head_end)
  local body_at = data:find("\n", head_end, true) + 1
  local format = header:match("format%s+(%S+)") or "ascii"
  local elements, current = {}, nil
  for line in header:gmatch("[^\r\n]+") do
    local name, count = line:match("^element%s+(%S+)%s+(%d+)")
    if name then
      current = { name = name, count = tonumber(count), props = {} }
      elements[#elements + 1] = current
    else
      local list_count, list_item, pname = line:match("^property%s+list%s+(%S+)%s+(%S+)%s+(%S+)")
      if list_count and current then
        current.props[#current.props + 1] = { name = pname, list = true, count_type = list_count, item_type = list_item }
      else
        local ptype, pname2 = line:match("^property%s+(%S+)%s+(%S+)")
        if ptype and current then current.props[#current.props + 1] = { name = pname2, type = ptype } end
      end
    end
  end
  local size = { char = 1, uchar = 1, int8 = 1, uint8 = 1, short = 2, ushort = 2, int16 = 2, uint16 = 2,
    int = 4, uint = 4, int32 = 4, uint32 = 4, float = 4, float32 = 4, double = 8, float64 = 8 }
  local vs, tris = {}, {}
  if format == "ascii" then
    local nums = {}
    for n in data:sub(body_at):gmatch("%S+") do nums[#nums + 1] = tonumber(n) or 0 end
    local at = 1
    for _, el in ipairs(elements) do
      for _ = 1, el.count do
        local rec = {}
        for _, p in ipairs(el.props) do
          if p.list then
            local n = nums[at] at = at + 1
            local list = {}
            for k = 1, n do list[k] = nums[at] at = at + 1 end
            rec[p.name] = list
          else
            rec[p.name] = nums[at] at = at + 1
          end
        end
        if el.name == "vertex" then vs[#vs + 1] = { rec.x or 0, rec.y or 0, rec.z or 0 }
        elseif el.name == "face" then
          local ids = rec.vertex_indices or rec.vertex_index or {}
          for k = 2, #ids - 1 do
            local a, b, c = vs[ids[1] + 1], vs[ids[k] + 1], vs[ids[k + 1] + 1]
            if a and b and c then tris[#tris + 1] = { a[1], a[2], a[3], b[1], b[2], b[3], c[1], c[2], c[3] } end
          end
        end
      end
    end
    return tris
  end
  if format ~= "binary_little_endian" then return nil, "a big-endian PLY is not read here" end
  local at = body_at
  local function read(t)
    local n = size[t] or 4
    local v
    if t == "float" or t == "float32" then v = f32(data, at)
    elseif t == "double" or t == "float64" then v = 0
    elseif n == 1 then v = data:byte(at)
    elseif n == 2 then v = u16(data, at)
    else v = u32(data, at) end
    at = at + n
    return v
  end
  for _, el in ipairs(elements) do
    for _ = 1, el.count do
      local rec = {}
      for _, p in ipairs(el.props) do
        if p.list then
          local n = read(p.count_type)
          local list = {}
          for k = 1, n do list[k] = read(p.item_type) end
          rec[p.name] = list
        else
          rec[p.name] = read(p.type)
        end
      end
      if el.name == "vertex" then vs[#vs + 1] = { rec.x or 0, rec.y or 0, rec.z or 0 }
      elseif el.name == "face" then
        local ids = rec.vertex_indices or rec.vertex_index or {}
        for k = 2, #ids - 1 do
          local a, b, c = vs[ids[1] + 1], vs[ids[k] + 1], vs[ids[k + 1] + 1]
          if a and b and c then tris[#tris + 1] = { a[1], a[2], a[3], b[1], b[2], b[3], c[1], c[2], c[3] } end
        end
      end
    end
  end
  return tris
end

--- glTF 2.0: the triangles of every mesh's primitives, placed by the nodes
--- that hold them (translation, rotation, scale or a matrix).
local function gltf(json, bin, dir)
  local ok, doc = pcall(bone.json.decode, json)
  if not ok or type(doc) ~= "table" then return nil, "not a glTF file" end
  local buffers = {}
  for i, b in ipairs(doc.buffers or {}) do
    if b.uri == nil then
      buffers[i - 1] = bin
    elseif type(b.uri) == "string" and not b.uri:match("^data:") then
      local f = io.open(dir .. "/" .. b.uri, "rb")
      if f then buffers[i - 1] = f:read("*a") f:close() end
    end
  end
  local function accessor(index)
    local a = doc.accessors and doc.accessors[index + 1]
    if not a then return nil end
    local view = doc.bufferViews[(a.bufferView or 0) + 1]
    local buf = view and buffers[view.buffer or 0]
    if not buf then return nil end
    local base = (view.byteOffset or 0) + (a.byteOffset or 0) + 1
    local comps = ({ SCALAR = 1, VEC2 = 2, VEC3 = 3, VEC4 = 4 })[a.type] or 1
    local csize = ({ [5120] = 1, [5121] = 1, [5122] = 2, [5123] = 2, [5125] = 4, [5126] = 4 })[a.componentType] or 4
    local stride = view.byteStride or comps * csize
    local out = {}
    for i = 0, a.count - 1 do
      for c = 0, comps - 1 do
        local at = base + i * stride + c * csize
        local v
        if a.componentType == 5126 then v = f32(buf, at)
        elseif csize == 1 then v = buf:byte(at)
        elseif csize == 2 then v = u16(buf, at)
        else v = u32(buf, at) end
        out[#out + 1] = v
      end
    end
    return out, comps
  end
  local function mul(a, b)
    local r = {}
    for i = 0, 3 do
      for j = 0, 3 do
        local sum = 0
        for k = 0, 3 do sum = sum + a[k * 4 + i + 1] * b[j * 4 + k + 1] end
        r[j * 4 + i + 1] = sum
      end
    end
    return r
  end
  local function local_matrix(n)
    if n.matrix then return n.matrix end
    local t = n.translation or { 0, 0, 0 }
    local q = n.rotation or { 0, 0, 0, 1 }
    local s = n.scale or { 1, 1, 1 }
    local x, y, z, w = q[1], q[2], q[3], q[4]
    return {
      (1 - 2 * (y * y + z * z)) * s[1], (2 * (x * y + z * w)) * s[1], (2 * (x * z - y * w)) * s[1], 0,
      (2 * (x * y - z * w)) * s[2], (1 - 2 * (x * x + z * z)) * s[2], (2 * (y * z + x * w)) * s[2], 0,
      (2 * (x * z + y * w)) * s[3], (2 * (y * z - x * w)) * s[3], (1 - 2 * (x * x + y * y)) * s[3], 0,
      t[1], t[2], t[3], 1,
    }
  end
  local tris = {}
  local function emit(mesh, m)
    for _, prim in ipairs(mesh.primitives or {}) do
      if (prim.mode or 4) == 4 and prim.attributes and prim.attributes.POSITION then
        local pos = accessor(prim.attributes.POSITION)
        if pos then
          local function p(i)
            local x, y, z = pos[i * 3 + 1], pos[i * 3 + 2], pos[i * 3 + 3]
            return m[1] * x + m[5] * y + m[9] * z + m[13], m[2] * x + m[6] * y + m[10] * z + m[14],
              m[3] * x + m[7] * y + m[11] * z + m[15]
          end
          local idx = prim.indices and accessor(prim.indices)
          local count = idx and #idx or (#pos / 3)
          for k = 0, count - 3, 3 do
            local a, b, c
            if idx then a, b, c = idx[k + 1], idx[k + 2], idx[k + 3] else a, b, c = k, k + 1, k + 2 end
            local ax, ay, az = p(a)
            local bx, by, bz = p(b)
            local cx, cy, cz = p(c)
            tris[#tris + 1] = { ax, ay, az, bx, by, bz, cx, cy, cz }
          end
        end
      end
    end
  end
  local I = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
  local function walk(index, parent, depth)
    local n = doc.nodes and doc.nodes[index + 1]
    if not n or depth > 64 then return end
    local m = mul(parent, local_matrix(n))
    if n.mesh and doc.meshes and doc.meshes[n.mesh + 1] then emit(doc.meshes[n.mesh + 1], m) end
    for _, c in ipairs(n.children or {}) do walk(c, m, depth + 1) end
  end
  local scene = doc.scenes and doc.scenes[(doc.scene or 0) + 1]
  if scene and scene.nodes then
    for _, n in ipairs(scene.nodes) do walk(n, I, 0) end
  else
    for _, mesh in ipairs(doc.meshes or {}) do emit(mesh, I) end
  end
  return tris
end

M.EXTENSIONS = { stl = true, obj = true, ply = true, glb = true, gltf = true }

--- The model at `path`: { tris, count, size = { x, y, z } } or nil and why.
function M.load(path)
  local ext = (path:match("%.(%w+)$") or ""):lower()
  local f, err = io.open(path, "rb")
  if not f then return nil, tostring(err) end
  local data = f:read("*a")
  f:close()
  local tris, why
  if ext == "stl" then tris = stl(data)
  elseif ext == "obj" then tris = obj(data)
  elseif ext == "ply" then tris, why = ply(data)
  elseif ext == "glb" then
    if data:sub(1, 4) ~= "glTF" then return nil, "not a GLB file" end
    local json, bin
    local at = 13
    while at + 8 <= #data do
      local len, kind = u32(data, at), data:sub(at + 4, at + 7)
      if kind == "JSON" then json = data:sub(at + 8, at + 7 + len)
      elseif kind == "BIN\0" then bin = data:sub(at + 8, at + 7 + len) end
      at = at + 8 + len
    end
    if not json then return nil, "not a GLB file" end
    tris, why = gltf(json, bin, path:match("^(.*)/") or ".")
  elseif ext == "gltf" then
    tris, why = gltf(data, nil, path:match("^(.*)/") or ".")
  else
    return nil, "not a model this reads"
  end
  if not tris then return nil, why end
  if #tris == 0 then return nil, "there are no triangles in it" end
  -- Centred at the origin, the longest side 2 long.
  local lo, hi = { math.huge, math.huge, math.huge }, { -math.huge, -math.huge, -math.huge }
  for _, t in ipairs(tris) do
    for k = 0, 2 do
      for a = 1, 3 do
        local v = t[k * 3 + a]
        if v < lo[a] then lo[a] = v end
        if v > hi[a] then hi[a] = v end
      end
    end
  end
  local size = { hi[1] - lo[1], hi[2] - lo[2], hi[3] - lo[3] }
  local scale = 2 / math.max(size[1], size[2], size[3], 1e-9)
  local cx, cy, cz = (lo[1] + hi[1]) / 2, (lo[2] + hi[2]) / 2, (lo[3] + hi[3]) / 2
  -- Too many to draw: the corners that share a cell of a grid (fine enough to
  -- keep the shape) become one, where they are on average, and the
  -- triangles that fold to nothing go. The surface stays closed, which
  -- dropping triangles would not keep.
  local function placed(t)
    return {
      (t[1] - cx) * scale, (t[2] - cy) * scale, (t[3] - cz) * scale,
      (t[4] - cx) * scale, (t[5] - cy) * scale, (t[6] - cz) * scale,
      (t[7] - cx) * scale, (t[8] - cy) * scale, (t[9] - cz) * scale,
    }
  end
  local shown = {}
  if #tris <= M.DRAW_LIMIT then
    for i, t in ipairs(tris) do shown[i] = placed(t) end
  else
    local placed_all = {}
    for i, t in ipairs(tris) do placed_all[i] = placed(t) end
    local cells = 256
    while cells >= 8 do
      local q = cells / 2
      -- Each cell's corner is where its corners are on average.
      local sum = {}
      local function key(x, y, z)
        return math.floor(x * q + 0.5) .. "," .. math.floor(y * q + 0.5) .. "," .. math.floor(z * q + 0.5)
      end
      for _, p in ipairs(placed_all) do
        for k = 0, 2 do
          local x, y, z = p[k * 3 + 1], p[k * 3 + 2], p[k * 3 + 3]
          local id = key(x, y, z)
          local c = sum[id]
          if not c then c = { 0, 0, 0, 0 } sum[id] = c end
          c[1], c[2], c[3], c[4] = c[1] + x, c[2] + y, c[3] + z, c[4] + 1
        end
      end
      shown = {}
      local seen = {}
      for _, p in ipairs(placed_all) do
        local a = key(p[1], p[2], p[3])
        local b = key(p[4], p[5], p[6])
        local c = key(p[7], p[8], p[9])
        if a ~= b and b ~= c and a ~= c then
          -- The same triangle twice (from neighbours that met) once.
          local k = a < b and (a < c and (a .. b .. c) or (c .. a .. b)) or (b < c and (b .. c .. a) or (c .. a .. b))
          if not seen[k] then
            seen[k] = true
            local A, B, C = sum[a], sum[b], sum[c]
            shown[#shown + 1] = { A[1] / A[4], A[2] / A[4], A[3] / A[4], B[1] / B[4], B[2] / B[4], B[3] / B[4],
              C[1] / C[4], C[2] / C[4], C[3] / C[4] }
          end
        end
        if #shown > M.DRAW_LIMIT then break end
      end
      if #shown <= M.DRAW_LIMIT then break end
      cells = math.floor(cells * 0.8)
    end
  end
  -- Models with Z up (most STL and OBJ from CAD) stand upright: the tallest
  -- side is taken as up when it is Z.
  local zup = (ext == "stl" or ext == "obj" or ext == "ply") and size[3] >= size[2]
  return { tris = shown, count = #tris, size = size, thinned = #shown < #tris, zup = zup }
end

--- The model drawn into a w×h canvas from angles `yaw` and `pitch` (radians),
--- `zoom` (1 fills it), in `color` (r, g, b 0..255) over `bg`.
function M.draw(model, w, h, yaw, pitch, zoom, color, wire)
  local d = bone.gui.draw
  local cy_, sy = math.cos(yaw), math.sin(yaw)
  local cp, sp = math.cos(pitch), math.sin(pitch)
  local scale = math.min(w, h) * 0.42 * (zoom or 1)
  local ox, oy = w / 2, h / 2
  local lx, ly, lz = -0.4, 0.55, 0.75 -- the light, toward the viewer, up and left
  local ll = math.sqrt(lx * lx + ly * ly + lz * lz)
  lx, ly, lz = lx / ll, ly / ll, lz / ll
  local zup = model.zup
  local faces = {}
  -- As lines the drawing takes three shapes a triangle: past WIRE_LIMIT,
  -- every n-th.
  local every = wire and math.max(1, math.ceil(#model.tris / M.WIRE_LIMIT)) or 1
  for ti = 1, #model.tris, every do
    local t = model.tris[ti]
    local p = {}
    for k = 0, 2 do
      local x, y, z = t[k * 3 + 1], t[k * 3 + 2], t[k * 3 + 3]
      if zup then y, z = z, -y end
      -- Turn about the up axis, then tip toward the viewer.
      local x1 = x * cy_ + z * sy
      local z1 = -x * sy + z * cy_
      local y1 = y * cp - z1 * sp
      local z2 = y * sp + z1 * cp
      p[k * 3 + 1], p[k * 3 + 2], p[k * 3 + 3] = x1, y1, z2
    end
    -- The face's normal, in view space.
    local ux, uy, uz = p[4] - p[1], p[5] - p[2], p[6] - p[3]
    local vx, vy, vz = p[7] - p[1], p[8] - p[2], p[9] - p[3]
    local nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
    local nl = math.sqrt(nx * nx + ny * ny + nz * nz)
    if nl > 0 then
      nx, ny, nz = nx / nl, ny / nl, nz / nl
      -- Facing away: drawn only when the model has no inside to hide it
      -- (both sides lit, as thin parts often are).
      local facing = nz
      local light = math.abs(nx * lx + ny * ly + nz * lz)
      faces[#faces + 1] = { depth = (p[3] + p[6] + p[9]) / 3, p = p, light = light, back = facing < 0 }
    end
  end
  table.sort(faces, function(a, b) return a.depth < b.depth end)
  local out = {}
  local r, g, b = color[1], color[2], color[3]
  for _, f in ipairs(faces) do
    local k = 0.28 + 0.72 * f.light
    if f.back then k = k * 0.75 end
    local fill = string.format("#%02x%02x%02x", math.min(255, math.floor(r * k)), math.min(255, math.floor(g * k)),
      math.min(255, math.floor(b * k)))
    local p = f.p
    local ax, ay = ox + p[1] * scale, oy - p[2] * scale
    local bx, by = ox + p[4] * scale, oy - p[5] * scale
    local cx, cy = ox + p[7] * scale, oy - p[8] * scale
    -- A sliver is left out: the soft edge drawn around a filled shape runs
    -- out to a point at a corner that sharp.
    local area = math.abs((bx - ax) * (cy - ay) - (cx - ax) * (by - ay))
    local e1 = (bx - ax) ^ 2 + (by - ay) ^ 2
    local e2 = (cx - bx) ^ 2 + (cy - by) ^ 2
    local e3 = (ax - cx) ^ 2 + (ay - cy) ^ 2
    local longest = math.max(e1, e2, e3)
    if wire then
      -- Lines, not a closed outline: a line has no corner to run long.
      out[#out + 1] = d.line({ x1 = ax, y1 = ay, x2 = bx, y2 = by, color = fill, width = 0.8 })
      out[#out + 1] = d.line({ x1 = bx, y1 = by, x2 = cx, y2 = cy, color = fill, width = 0.8 })
      out[#out + 1] = d.line({ x1 = cx, y1 = cy, x2 = ax, y2 = ay, color = fill, width = 0.8 })
    elseif area > 0.05 and area > 0.02 * longest then
      out[#out + 1] = d.polyline({ points = { { ax, ay }, { bx, by }, { cx, cy } }, closed = true, fill = fill,
        color = "#00000000", width = 0 })
    end
  end
  return out
end

return M
