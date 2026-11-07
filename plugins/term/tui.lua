local terminal = require("bone.ui.terminal")
local mux = require("term.mux")

-- Register eagerly as term, not lazily inside another plugin's open callback.
-- bone.ui.terminal stays the API other plugins open their own panels with;
-- /term and ctrl+] are the multiplexer: tabs and split panes in one panel.
terminal.setup()
local token = mux.setup(terminal)
-- This load's shutdowns: a late call after a reload must not stop the next.
local terminal_shutdown = terminal.shutdown
bone.plugin.on_shutdown(function()
  mux.shutdown(token)
  terminal_shutdown()
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
