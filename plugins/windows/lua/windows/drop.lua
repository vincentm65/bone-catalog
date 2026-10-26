-- Shared drop geometry, in the frontend's units (cells or pixels).
local M = {}

-- The center swaps; the nearest edge in the outer fifth splits, unless
-- either half (after a separator) would be smaller than min. The rect is
-- the landing preview; gap defaults to zero for separator-free layouts.
function M.zone(id, r, x, y, min, gap)
  gap = gap or 0
  if not r or r.width < 1 or r.height < 1 then return end
  local rx, ry = x - r.x, y - r.y
  if rx < 0 or ry < 0 or rx >= r.width or ry >= r.height then return end
  local band = math.min(r.width, r.height) * 0.2
  local side
  if rx < band or rx >= r.width - band or ry < band or ry >= r.height - band then
    local best, dist
    for _, s in ipairs({ { "up", ry }, { "right", r.width - rx }, { "down", r.height - ry }, { "left", rx } }) do
      if not dist or s[2] < dist then best, dist = s[1], s[2] end
    end
    local along = (best == "left" or best == "right") and r.width or r.height
    if math.floor((along - gap) / 2) >= min then side = best end
  end
  local rect = { x = r.x, y = r.y, width = r.width, height = r.height }
  if side == "left" or side == "right" then
    rect.width = math.floor((r.width - gap) / 2)
    if side == "right" then rect.x = r.x + r.width - rect.width end
  elseif side == "up" or side == "down" then
    rect.height = math.floor((r.height - gap) / 2)
    if side == "down" then rect.y = r.y + r.height - rect.height end
  end
  return { id = id, side = side, rect = rect }
end

return M
