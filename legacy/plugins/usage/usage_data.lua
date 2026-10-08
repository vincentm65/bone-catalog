-- The dashboard owns its read-only aggregation; the harness records raw events.
local M = {}
local sums = [[COALESCE(SUM(prompt_tokens),0) AS prompt_tokens,
 COALESCE(SUM(completion_tokens),0) AS completion_tokens,
 COALESCE(SUM(cached_tokens),0) AS cached_tokens, COUNT(*) AS request_count]]
local projection = [[COALESCE(u.prompt_tokens,0) AS prompt_tokens,
 COALESCE(u.completion_tokens,0) AS completion_tokens,
 COALESCE(u.cached_tokens,0) AS cached_tokens, COALESCE(u.request_count,0) AS request_count]]
local function series(ctx, start, finish, step, format, where, params)
   return ctx.db.query([[WITH RECURSIVE series(day) AS (
      SELECT ]] .. start .. [[ UNION ALL SELECT date(day, ']] .. step .. [[')
      FROM series WHERE date(day, ']] .. step .. [[') <= ]] .. finish .. [[
   ), usage AS (SELECT strftime(']] .. format .. [[',created_at,'localtime') AS label,]] .. sums .. [[
      FROM usage_events ]] .. where .. [[ GROUP BY label)
   SELECT strftime(']] .. format .. [[',series.day) AS label,]] .. projection .. [[
   FROM series LEFT JOIN usage u ON u.label=strftime(']] .. format .. [[',series.day)
   ORDER BY series.day]], params)
end
function M.load(ctx, mode, custom)
   local where, params = "", nil
   if custom then
      local valid = ctx.db.query([[SELECT date(?1,'+0 days') AS start, date(?2,'+0 days') AS finish,
         julianday(?2)-julianday(?1) AS days]], { custom.start, custom.finish })[1]
      if not valid or valid.start ~= custom.start or valid.finish ~= custom.finish
         or valid.days < 0 or valid.days > 36600 then
         error("Enter valid dates in order (at most 100 years).", 0)
      end
      where, params = "WHERE date(created_at,'localtime') BETWEEN ?1 AND ?2", {custom.start, custom.finish}
   elseif mode <= 3 then
      where = "WHERE date(created_at,'localtime') >= date('now','localtime','-" .. ({0,6,27})[mode] .. " days')"
   end
   local data = {}
   if custom then
      data.buckets = series(ctx, "date(?1)", "date(?2)", "+1 day", "%Y-%m-%d", where, params)
   elseif mode == 1 then
      data.buckets = ctx.db.query([[WITH RECURSIVE hours(hour) AS (VALUES(0)
         UNION ALL SELECT hour+1 FROM hours WHERE hour<23), usage AS (
         SELECT CAST(strftime('%H',created_at,'localtime') AS INTEGER) AS hour,]] .. sums .. [[
         FROM usage_events WHERE date(created_at,'localtime')=date('now','localtime') GROUP BY hour)
         SELECT printf('%02d:00',hours.hour) AS label,]] .. projection .. [[
         FROM hours LEFT JOIN usage u ON u.hour=hours.hour ORDER BY hours.hour]])
   elseif mode <= 3 then
      data.buckets = series(ctx, "date('now','localtime','-" .. (mode == 2 and 6 or 21) .. " days')",
         "date('now','localtime')", mode == 2 and "+1 day" or "+7 days",
         mode == 2 and "%Y-%m-%d" or "%Y-W%W", where)
   elseif mode == 4 then
      data.buckets = ctx.db.query("SELECT strftime('%Y',created_at,'localtime') AS label," .. sums .. " FROM usage_events GROUP BY label ORDER BY label")
   else
      data.buckets = series(ctx, "(SELECT COALESCE(date(MIN(created_at),'localtime','start of month'),date('now','localtime','start of month')) FROM usage_events)",
         "date('now','localtime','start of month')", "+1 month", "%Y-%m", "")
   end
   data.models = ctx.db.query("SELECT provider,model," .. sums .. " FROM usage_events " .. where ..
      " GROUP BY provider,model ORDER BY SUM(prompt_tokens)+SUM(completion_tokens) DESC", params)
   data.hourly = ctx.db.query("SELECT CAST(strftime('%H',created_at,'localtime') AS INTEGER) AS hour," .. sums ..
      " FROM usage_events " .. where .. " GROUP BY hour ORDER BY hour", params)
   data.activity = custom and data.buckets or series(ctx, "date('now','localtime','-729 days')",
      "date('now','localtime')", "+1 day", "%Y-%m-%d",
      "WHERE date(created_at,'localtime') >= date('now','localtime','-729 days')")
   return data
end
return M
