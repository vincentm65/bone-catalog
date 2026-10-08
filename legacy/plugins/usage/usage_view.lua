-- Declarative dashboard shared by terminal and desktop plugin pages.
local M = {}
local max, min, floor, ceil = math.max, math.min, math.floor, math.ceil
local titles = {"Today", "7 days", "4 weeks", "Yearly", "All time"}
local function span(text, fg, bold, click)
   return {text=tostring(text), fg=fg and "@"..fg, modifiers=bold and {"bold"} or nil, click=click}
end
local function line(...) return {spans={...}} end
local function panel(id, title, lines) return {id=id, title=title, lines=lines} end
local function split(axis, sizes, children) return {axis=axis,sizes=sizes,children=children} end
local function tokens(b) return (b.prompt_tokens or 0)+(b.completion_tokens or 0) end
local function compact(n)
   if n < 100000 then return string.format("%.0f",n) end
   local divisor, suffix = 1e9,"b"
   if n < 1e6 then divisor,suffix=1e3,"k" elseif n < 1e9 then divisor,suffix=1e6,"m" end
   return (string.format("%.1f",floor(n/divisor*10+0.5)/10):gsub("%.0$", ""))..suffix
end
local function pad(s, width, right)
   s = tostring(s)
   local spaces = string.rep(" ", max(width-(utf8.len(s) or #s),0))
   return right and spaces..s or s..spaces
end
local function trunc(s, width)
   if utf8.len(s) > width then s = s:sub(1,(utf8.offset(s,max(width,1)) or 1)-1)..(width>1 and "…" or s:sub(1,1)) end
   return pad(s,width)
end
local function heat(text, value, peak)
   if value <= 0 then return span(text,"subtle") end
   local s = span(text,nil,true)
   s.fg = "@heat_low|@heat_high|"..(min(max(ceil(value/max(peak,1)*15)-1,0),14)/14)
   return s
end
local function area(event, id)
   local rect = event.areas and event.areas[id]
   return rect and rect[3] or event.width, rect and rect[4] or 0
end
local function chart(event, s)
   local w,h = area(event,"chart")
   local rows, bars = max(h-2,0),max(w-31,6)
   local buckets, peak, lines = s.data.buckets,1,{}
   for _, b in ipairs(buckets) do peak = max(peak,tokens(b)) end
   local start = min(s.scroll,max(#buckets-rows,0))
   for i=#buckets-start,max(#buckets-start-rows+1,1),-1 do
      local b = buckets[i]
      local filled = floor(tokens(b)/peak*bars+0.5)
      lines[#lines+1] = line(span(pad(b.label,12,true).." ","muted"),span(string.rep("█",filled),"chart",true),
         span(string.rep("░",max(bars-filled,0)),"chart_empty"),span(" "..pad(compact(tokens(b)),8,true),"fg",true),
         span(" "..pad(compact(b.request_count),5,true).."r","muted"))
   end
   if #buckets == 0 then lines={line(span("No usage events yet.","muted"))} end
   return panel("chart",titles[s.mode].." usage",lines)
end
local function models(event,s)
   local w,h = area(event,"models")
   w = max(w-4,0)
   local namew = max(floor(w/2),12)
   local tokw = max(w-namew-12,4)
   local lines = {line(span(pad("provider / model",namew),"muted"),span(pad("req",5,true).." "..pad("tokens",tokw,true).." "..pad("cache",5,true),"muted"))}
   for i=1,min(#s.data.models,max(h-3,0)) do
      local m = s.data.models[i]
      local cache = m.prompt_tokens > 0 and floor(m.cached_tokens*100/m.prompt_tokens) or 0
      lines[#lines+1] = line(span(trunc(m.provider.." / "..m.model,namew),"fg"),span(pad(m.request_count,5,true).." ","accent"),
         span(pad(compact(tokens(m)),tokw,true).." ","fg",true),span(pad(cache,4,true).."%","accent"))
   end
   return panel("models","Provider / model",lines)
end
local function hourly(s)
   local hours, labels, spans, peak, peakidx, total, req = {},{}, {span("  ")},1,0,0,{}
   for _, b in ipairs(s.data.hourly) do hours[b.hour],req[b.hour] = tokens(b),b.request_count end
   for i=0,23 do
      local n = hours[i] or 0
      labels[#labels+1],total = string.format("%02d",i),total+n
      if n >= (hours[peakidx] or 0) then peakidx = i end
      peak = max(peak,n)
   end
   for i=0,23 do local n=hours[i] or 0; spans[#spans+1] = heat(n>0 and "█  " or "·  ",n,peak) end
   return panel("hourly",titles[s.mode].." by hour",{line(span("  "..table.concat(labels," "),"muted")),{spans=spans},
      line(span(total>0 and string.format("peak %02d:00 · %d req",peakidx,req[peakidx] or 0) or "no activity","fg"),span("   total "..compact(total),"muted"))})
end
local function weekday(date)
   if not date then return 0 end
   local y,m,d = date:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
   y,m,d=tonumber(y),tonumber(m),tonumber(d)
   if not y or m<1 or m>12 then return 0 end
   if m<3 then y=y-1 end
   return (y+floor(y/4)-floor(y/100)+floor(y/400)+({0,3,2,5,0,3,5,1,4,6,2,4})[m]+d+6)%7
end
local function activity(event,s)
   local w,h = area(event,"activity")
   w,h=max(w-2,0),max(h-2,0)
   local lines={}
   if w==0 or h<3 then return panel("activity","Daily activity",lines) end
   local stats = w>=54
   local cols = max(floor(max(w-4-(stats and 21 or 0),0)/2),1)
   local rows = min(h-(h>=9 and 1 or 0)-(h>=8 and 1 or 0),7)
   local all = s.data.activity
   local trailing = #all>0 and 6-weekday(all[#all].label) or 0
   local start = max(#all-max(cols*7-trailing,1)+1,1)
   local count = #all-start+1
   local first,last = all[start] and all[start].label or "none",all[#all] and all[#all].label or "none"
   local leading,cells,labels,peak,total,most=weekday(first),{},{},1,0,nil
   for i=start,#all do
      local b=all[i]
      local slot=leading+i-start
      local col=floor(slot/7)
      if col<cols then cells[slot]=tokens(b); labels[col]=labels[col] or b.label end
      peak,total=max(peak,tokens(b)),total+tokens(b)
      if not most or tokens(b)>=tokens(most) then most=b end
   end
   if h>=9 then
      local range=first.." → "..last
      if #range>w then range=count.." days → "..last end
      if #range>w then range=last end
      if #range+#"   less ■ ■ ■ more">w then lines[#lines+1]=line(span(trunc(range,w),"fg"))
      else lines[#lines+1]=line(span(range,"fg"),span("   less ","muted"),heat("■ ",0,peak),heat("■ ",floor(peak/2),peak),heat("■",peak,peak),span(" more","muted")) end
   end
   if h>=8 then
      local axis,nextcol={},0
      for i=1,cols*2 do axis[i]=" " end
      for col=0,cols-1 do
         if labels[col] and col>=nextcol then
            local m,d=labels[col]:match("%d%d%d%d%-(%d%d)%-(%d%d)")
            local label=m and tonumber(m).."/"..tonumber(d)
            if label and col*2+#label<=cols*2 then
               for i=1,#label do axis[col*2+i]=label:sub(i,i) end
               nextcol=col+ceil(#label/2)+1
            end
         end
      end
      lines[#lines+1]=line(span("    "),span(table.concat(axis),"muted"))
   end
   local weekdays={"Mon ","Tue ","Wed ","Thu ","Fri ","Sat ","Sun "}
   for row=0,rows-1 do
      local spans={span(weekdays[row+1],"muted")}
      for col=0,cols-1 do spans[#spans+1]=heat("■ ",cells[col*7+row] or 0,peak) end
      if stats then
         spans[#spans+1]=span(" ")
         local extra=({[0]=span("peak","muted"),[1]=span(most and most.label or "none","fg",true),
            [2]=span(compact(most and tokens(most) or 0),"accent",true),[4]=span(count.." days","muted"),
            [5]=span("total","muted"),[6]=span(compact(total),"fg",true)})[row]
         if extra then spans[#spans+1]=extra end
      end
      lines[#lines+1]={spans=spans}
   end
   return panel("activity","Daily activity",lines)
end
function M.draw(event,s)
   if not s.data then return {lines={line(span(s.error or "Loading usage…","muted"))}} end
   local d,buckets = s.data,s.data.buckets
   local first,last=buckets[1] and buckets[1].label or "",buckets[#buckets] and buckets[#buckets].label or ""
   if s.custom then first,last=s.custom.start,s.custom.finish end
   local range = first=="" and "no usage events yet" or first==last and first or first.." → "..last
   local tabs={}
   for i,title in ipairs(titles) do
      if i>1 then tabs[#tabs+1]=span("  ",s.custom and "muted" or "fg") end
      tabs[#tabs+1]=span((i==s.mode and "[" or " ")..i.." "..title..(i==s.mode and "]" or " "),s.custom and "muted" or "fg",false,tostring(i))
   end
   if s.custom then tabs[#tabs+1]=span("  [custom range]","muted") end
   tabs[#tabs+1]=span("  refreshed "..max(os.time()-(s.refreshed or os.time()),0).."s ago","muted")
   local header=panel("","Overview",{line(span(" Token stats ","fg",true),span("  "),span(range,"muted")),{spans=tabs}})
   local total={prompt_tokens=0,completion_tokens=0,cached_tokens=0,request_count=0}
   for _,b in ipairs(buckets) do for k,v in pairs(total) do total[k]=v+b[k] end end
   local values={compact(total.request_count),compact(total.prompt_tokens),compact(total.completion_tokens),compact(total.cached_tokens),compact(tokens(total)),
      (total.prompt_tokens>0 and floor(total.cached_tokens/total.prompt_tokens*100+0.5) or 0).."%"}
   local cards,sizes={},{}
   for i,title in ipairs({"Requests","Prompt","Completion","Cached","Total","Cache"}) do
      cards[i],sizes[i]=panel("",title,{line(span(values[i],"fg",true))}),{percent=16}
   end
   local body
   if event.width<110 then body=split("vertical",{{min=6},{length=5},{length=8},{min=10}}, {chart(event,s),hourly(s),models(event,s),activity(event,s)})
   else body=split("vertical",{{percent=53},{percent=47}}, {chart(event,s),split("horizontal",{{percent=52},{percent=48}},
      {models(event,s),split("vertical",{{length=6},{min=6}},{hourly(s),activity(event,s)})})}) end
   local footer={lines={line(span(" q/Esc ","fg",true,"Esc"),span("quit  ","muted",false,"Esc"),
      span(" 1-5 d/w/m/y/a ←→ ","fg",true,"Right"),span("view  ","muted",false,"Right"),
      span(" t ","fg",true,"t"),span("dates  ","muted",false,"t"),span(" r ","fg",true,"r"),span("refresh  ","muted",false,"r"),
      span(" ↑↓ PgUp/PgDn ","fg",true,"PageDown"),span("scroll","muted",false,"PageDown"))}}
   local root={children={split("vertical",{{length=4},{length=3},{min=12},{length=1}},{header,split("horizontal",sizes,cards),body,footer})}}
   if s.picker then
      local p=s.picker
      local function field(label,value,on)
         local l=line(span(pad(label,6),"muted"),span(pad(value,14),on and "chart" or "fg",on),span(on and "_" or " ",on and "chart" or nil))
         l.click=on and "" or "Tab"
         return l
      end
      root.children[#root.children+1]={rect={floor(max(event.width-44,0)/2),floor(max(event.height-9,0)/2),44,9},clear=true,
         title=" Custom date range (YYYY-MM-DD) ",border_fg="@chart",children={{rect={2,2,40,6},lines={"",field("start:",p.start,p.field==1),"",field("end:",p.finish,p.field==2),"",
         line(span(" Tab switch · Enter apply · Esc cancel","muted"))}}}}
   end
   if s.error then
      local text=" error: "..s.error.." "
      local width=min(utf8.len(text)+4,event.width)
      root.children[#root.children+1]={rect={floor((event.width-width)/2),max(event.height-4,0),width,3},clear=true,title="",border_fg="@error",center=true,lines={line(span(text,"error",true))}}
   end
   return root
end
return M
