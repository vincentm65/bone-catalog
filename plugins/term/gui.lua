-- The desktop app's /term and ctrl+]: the multiplexer (tabs and split panes in
-- one panel), drawn as nodes. bone's runtime terminal (require("bone.terminal"))
-- stays as it is for other plugins' own terminal panels; this only takes over
-- the command and the key, and puts them back when it unloads.
local ok, terminal = pcall(require, "bone.terminal")
if not ok or type(terminal) ~= "table" then return end
local mux = require("term.mux")
local token = mux.setup(terminal)
bone.plugin.on_shutdown(function()
  mux.shutdown(token)
  -- bone's own /term and ctrl+] again, as runtime/lua/bone/gui.lua set them.
  bone.defer(0, function()
    pcall(bone.cmd.create, "term", function(c)
      local command = (c.args or ""):match("^%s*(.-)%s*$")
      if command == "close" then return terminal.close() or bone.notify("no terminal is open", "error") end
      return terminal.open(nil, { cmd = command ~= "" and command or nil })
    end, { desc = "open a terminal panel; /term [command], /term close (ctrl+])", aliases = { "terminal" } })
    for _, key in ipairs({ "ctrl+]", "ctrl+5" }) do
      pcall(bone.keymap.set, key, function() return terminal.toggle() end,
        { desc = "open or focus a terminal; press again to return to the prompt" })
    end
  end)
end)

bone.cmd.create("term", function(c)
  local command = (c.args or ""):match("^%s*(.-)%s*$")
  if command == "close" then return mux.close_all() end
  return mux.open(command ~= "" and command or nil)
end, {
  desc = "terminal tabs and splits; /term [command] a new tab, /term close (ctrl+])",
  aliases = { "terminal" },
})

for _, key in ipairs({ "ctrl+]", "ctrl+5" }) do
  bone.keymap.set(key, function() return mux.toggle() end, {
    desc = "open or focus the terminal; press again to return to the prompt",
  })
end
