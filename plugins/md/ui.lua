local browser = require("md_browser")

bone.cmd.create("md", function(c)
  return browser.open(c.args)
end, { desc = "browse project Markdown in a popup; /md [relative path]" })

bone.plugin.on_shutdown(function()
  browser.close()
end)
