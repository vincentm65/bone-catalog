-- Shared toolstrip options. The renderers live in tui.lua and gui.lua because
-- the terminal draws lines while the desktop draws nodes, but both sides use
-- the same names and defaults.
local function define(name, default, opts)
  if not pcall(bone.o.info, name) or not bone.o.info(name) then
    bone.o.define(name, default, opts)
  end
end

define("tool_strip", true, {
  desc = "show the tool timeline; history uses equal-width segments",
  on_change = function() bone.ui.refresh() end,
})
define("fold_turns", true, {
  desc = "fold earlier turns into one timeline row",
  on_change = function() bone.ui.refresh() end,
})

-- Keep the shared highlight names available to both renderers, as
-- defaults under the colorscheme: a scheme or config that sets them wins.
local colors = {
  ToolStripModel = { link = "Dim" },
  ToolStripRead = { fg = "#3b3b3a" },
  ToolStripCommand = { fg = "#6b6a68" },
  ToolStripEdit = { fg = "#60ae81" },
  ToolStripFail = { fg = "#db7369" },
  ToolStripLive = { fg = "#ffb46a" },
  ToolStripWait = { fg = "#7cc4ff" },
  ToolStripAnswer = { fg = "#cfcdc9" },
  ToolStripAgent = { fg = "#6b6a68" },
}
for name, spec in pairs(colors) do
  spec.default = true
  bone.hl.set(name, spec)
end
