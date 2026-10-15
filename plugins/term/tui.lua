local terminal = require("bone.ui.terminal")

-- Register eagerly as term, not lazily inside another plugin's open callback.
terminal.setup()
bone.plugin.on_shutdown(terminal.shutdown)

bone.cmd.create("term", function(c)
  local command = (c.args or ""):match("^%s*(.-)%s*$")
  if command == "close" then
    return terminal.close() or bone.notify("no terminal is open", "error")
  end
  return terminal.open(nil, { cmd = command ~= "" and command or nil })
end, {
  desc = "open a terminal panel; /term [command], /term close (ctrl+])",
  aliases = { "terminal" },
})

for _, key in ipairs({ "ctrl+]", "ctrl+5" }) do
  bone.keymap.set(key, function() return terminal.toggle() end, {
    desc = "open or focus a terminal; press again to return to the prompt",
  })
end
