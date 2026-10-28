-- The standard GUI already has the full node-based tracker. This plugin half
-- turns on the same shared options so the local plugin owns the feature in
-- both frontends; the GUI keeps its native hover, tooltip, glow and click
-- renderer while the TUI uses its terminal renderer.
local function enable(name)
  local ok, info = pcall(bone.o.info, name)
  if ok and info then
    bone.o[name] = true
  end
end

enable("tool_strip")
enable("fold_turns")
