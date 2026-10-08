local data = require("usage_data")
local view = require("usage_view")
local page = require("ui.page")
local function open() return page.open("usage", "stats", {mode=2, scroll=0}) end
for _, name in ipairs({"stats", "usage"}) do
   bone.command.register(name, {description="open full-screen token stats dashboard", handler=open})
end
page.register("usage", "stats", function(event, ctx)
   local s = event.state
   if type(s) ~= "table" then s = {} end
   s.mode, s.scroll = s.mode or 2, s.scroll or 0
   local key = event.key
   local k = key and (key.code == "Char" and key.char or key.code)
   local reload, custom = not s.data, s.custom
   if s.picker then
      local p = s.picker
      local field = p.field == 1 and "start" or "finish"
      if k == "Esc" then s.picker, s.error = nil, nil
      elseif k == "Tab" or k == "BackTab" or k == "Up" or k == "Down" then p.field = 3-p.field
      elseif k == "Backspace" then p[field] = p[field]:sub(1,-2)
      elseif k == "Enter" then custom, reload = {start=p.start, finish=p.finish}, true
      elseif k and k:match("^[%d%-]$") and #p[field] < 10 then p[field] = p[field] .. k end
   elseif k == "q" or k == "Esc" then
      return {close=true}
   elseif k == "t" then
      local activity = s.data and s.data.activity or {}
      s.picker = {start=activity[1] and activity[1].label or "", finish=activity[#activity] and activity[#activity].label or "", field=1}
   elseif k == "r" then reload = true
   elseif k == "Down" or k == "j" then s.scroll = s.scroll+1
   elseif k == "Up" or k == "k" then s.scroll = math.max(s.scroll-1,0)
   elseif k == "PageDown" then s.scroll = s.scroll+8
   elseif k == "PageUp" then s.scroll = math.max(s.scroll-8,0)
   else
      local mode = ({d=1,w=2,m=3,y=4,a=5,["1"]=1,["2"]=2,["3"]=3,["4"]=4,["5"]=5})[k]
      if k == "Left" or k == "h" then mode = (s.mode+3)%5+1 end
      if k == "Right" or k == "l" then mode = s.mode%5+1 end
      if mode then s.mode,s.scroll,custom,reload = mode,0,nil,true end
   end
   if reload then
      local ok, result = pcall(data.load, ctx, s.mode, custom)
      if ok then
         s.data,s.custom,s.picker,s.error,s.refreshed = result,custom,nil,nil,os.time()
         s.scroll = 0
      else s.error = tostring(result) end
   end
   return {state=s,body=view.draw(event,s)}
end)
