-- HTML for the panel. `to_text` is the page as plain text. `parse` reads a
-- page the way a browser would forgive it (tags left open, attributes
-- unquoted) into blocks the panel draws itself — headings, paragraphs, lists,
-- quotes, code, tables, pictures, rules — each paragraph a run of spans with
-- what styles them (bold, italic, code, a link…). No CSS, no scripts: what a
-- page is, not how it is laid out. `to_markdown` is the same for a terminal.

local M = {}

local ENTITIES = {
  ["&amp;"] = "&", ["&lt;"] = "<", ["&gt;"] = ">", ["&quot;"] = '"',
  ["&apos;"] = "'", ["&nbsp;"] = " ", ["&hellip;"] = "…",
  ["&mdash;"] = "—", ["&ndash;"] = "–", ["&rsquo;"] = "’",
  ["&lsquo;"] = "‘", ["&ldquo;"] = "“", ["&rdquo;"] = "”",
  ["&middot;"] = "·", ["&bull;"] = "•",
}

-- The tags that end a line.
local BLOCKS = {
  "p", "div", "section", "article", "header", "footer", "main", "aside",
  "nav", "ul", "ol", "li", "dl", "dt", "dd", "table", "thead", "tbody",
  "tr", "h1", "h2", "h3", "h4", "h5", "h6", "pre", "blockquote", "form",
  "figure", "figcaption", "hr",
}

--- `html` as text: the markup gone, the words left, in paragraphs.
function M.to_text(html)
  local text = tostring(html or "")
  -- What is not text at all.
  text = text:gsub("<!%-%-.-%-%->", " ")
  text = text:gsub("<%s*[sS][cC][rR][iI][pP][tT].-</%s*[sS][cC][rR][iI][pP][tT]%s*>", " ")
  text = text:gsub("<%s*[sS][tT][yY][lL][eE].-</%s*[sS][tT][yY][lL][eE]%s*>", " ")
  -- A line break is a line.
  text = text:gsub("<%s*[bB][rR]%s*/?>", "\n")
  -- The block tags end their line.
  for _, tag in ipairs(BLOCKS) do
    text = text:gsub("<%s*" .. tag .. "[^>]*>", "\n")
    text = text:gsub("</%s*" .. tag .. "%s*>", "\n")
  end
  -- What is left of the tags goes.
  text = text:gsub("<[^>]*>", "")
  -- The entities that show up in prose.
  for entity, char in pairs(ENTITIES) do
    text = text:gsub(entity, char)
  end
  text = text:gsub("&#(%d+);", function(n)
    return string.char(tonumber(n) or 32)
  end)
  -- The whitespace the layout left behind.
  text = text:gsub("[ \t]+", " ")
  text = text:gsub("\n[ \t]+", "\n")
  text = text:gsub("\n%s*\n%s*\n+", "\n\n")
  text = text:gsub("^%s+", "")
  text = text:gsub("%s+$", "")
  return text
end


-- ---- reading a page ---------------------------------------------------------------

local NAMED = {
  amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = "\194\160", hellip = "…", mdash = "—",
  ndash = "–", rsquo = "’", lsquo = "‘", ldquo = "“", rdquo = "”", middot = "·", bull = "•", copy = "©",
  reg = "®", trade = "™", deg = "°", times = "×", divide = "÷", plusmn = "±", larr = "←", rarr = "→",
  uarr = "↑", darr = "↓", harr = "↔", laquo = "«", raquo = "»", euro = "€", pound = "£", yen = "¥",
  cent = "¢", sect = "§", para = "¶", frac12 = "½", frac14 = "¼", frac34 = "¾", check = "✓", hearts = "♥",
  zwj = "", zwnj = "", shy = "", ensp = " ", emsp = " ", thinsp = " ", minus = "−", le = "≤", ge = "≥",
  ne = "≠", infin = "∞", alpha = "α", beta = "β", pi = "π", mu = "μ", lambda = "λ", sum = "∑",
}

local function utf8_char(n)
  if n < 0x80 then return string.char(n) end
  if n < 0x800 then return string.char(0xC0 + math.floor(n / 64), 0x80 + n % 64) end
  if n < 0x10000 then
    return string.char(0xE0 + math.floor(n / 4096), 0x80 + math.floor(n / 64) % 64, 0x80 + n % 64)
  end
  return string.char(0xF0 + math.floor(n / 262144), 0x80 + math.floor(n / 4096) % 64,
    0x80 + math.floor(n / 64) % 64, 0x80 + n % 64)
end

--- `s` with its character references made characters.
function M.decode(s)
  return (s:gsub("&(#?[xX]?)(%w+);?", function(kind, name)
    if kind == "#" then
      local n = tonumber(name)
      return n and utf8_char(n) or nil
    elseif kind == "#x" or kind == "#X" then
      local n = tonumber(name, 16)
      return n and utf8_char(n) or nil
    end
    return NAMED[name] or NAMED[name:lower()]
  end))
end

local VOID = { area = true, base = true, br = true, col = true, embed = true, hr = true, img = true, input = true,
  link = true, meta = true, param = true, source = true, track = true, wbr = true }
local RAW = { script = true, style = true, textarea = true, title = true, noscript = true, template = true, svg = true }
local BLOCK = { address = true, article = true, aside = true, blockquote = true, details = true, dialog = true,
  dd = true, div = true, dl = true, dt = true, fieldset = true, figcaption = true, figure = true, footer = true,
  form = true, h1 = true, h2 = true, h3 = true, h4 = true, h5 = true, h6 = true, header = true, hgroup = true,
  hr = true, li = true, main = true, nav = true, ol = true, p = true, pre = true, section = true, table = true,
  ul = true, summary = true, tr = true, td = true, th = true, thead = true, tbody = true, tfoot = true,
  caption = true, body = true, html = true, center = true }

-- A start tag that ends an open element of these names (as the HTML parser
-- would close them).
local CLOSES = {
  li = { li = true }, dt = { dt = true, dd = true }, dd = { dt = true, dd = true },
  tr = { tr = true, td = true, th = true }, td = { td = true, th = true }, th = { td = true, th = true },
  thead = { tbody = true, tfoot = true }, tbody = { thead = true, tbody = true, tfoot = true },
  tfoot = { thead = true, tbody = true }, option = { option = true },
}

local function attributes(s)
  local out = {}
  for name, rest in s:gmatch("([%w_:%-]+)%s*(=?)") do out[name:lower()] = true end
  for name, q, v in s:gmatch('([%w_:%-]+)%s*=%s*(["\'])(.-)%2') do out[name:lower()] = M.decode(v) end
  for name, v in s:gmatch("([%w_:%-]+)%s*=%s*([^%s\"'>][^%s>]*)") do
    if out[name:lower()] == true then out[name:lower()] = M.decode(v) end
  end
  return out
end

--- The page as a tree: { tag, attrs, children } with text as strings.
function M.tree(html)
  html = tostring(html or "")
  local root = { tag = "#root", attrs = {}, children = {} }
  local stack = { root }
  local function top() return stack[#stack] end
  local function close(tag)
    for i = #stack, 2, -1 do
      if stack[i].tag == tag then
        for _ = #stack, i, -1 do table.remove(stack) end
        return
      end
    end
  end
  local pos, n = 1, #html
  while pos <= n do
    local lt = html:find("<", pos, true)
    if not lt then
      local t = top()
      t.children[#t.children + 1] = html:sub(pos)
      break
    end
    if lt > pos then
      local t = top()
      t.children[#t.children + 1] = html:sub(pos, lt - 1)
    end
    if html:sub(lt, lt + 3) == "<!--" then
      local e = html:find("-->", lt + 4, true)
      pos = e and e + 3 or n + 1
    elseif html:sub(lt + 1, lt + 1) == "!" or html:sub(lt + 1, lt + 1) == "?" then
      local e = html:find(">", lt, true)
      pos = e and e + 1 or n + 1
    elseif html:sub(lt + 1, lt + 1) == "/" then
      local name, e = html:match("^</%s*([%w:%-]+)[^>]*>()", lt)
      if name then
        name = name:lower()
        -- </p> with no <p> open is a paragraph of its own, as a browser has it.
        close(name)
        pos = e
      else
        local t = top()
        t.children[#t.children + 1] = "<"
        pos = lt + 1
      end
    else
      local name, rest, e = html:match("^<([%a][%w:%-]*)(.-)>()", lt)
      if not name then
        local t = top()
        t.children[#t.children + 1] = "<"
        pos = lt + 1
      else
        name = name:lower()
        -- What this one closes, as a browser would: another item, a
        -- paragraph before a block, a cell before a cell.
        if CLOSES[name] then
          for i = #stack, 2, -1 do
            local open = stack[i].tag
            if CLOSES[name][open] then
              for _ = #stack, i, -1 do table.remove(stack) end
              break
            end
            if open == "ul" or open == "ol" or open == "table" or open == "dl" then break end
          end
        end
        if BLOCK[name] then
          for i = #stack, 2, -1 do
            if stack[i].tag == "p" then
              for _ = #stack, i, -1 do table.remove(stack) end
              break
            end
          end
        end
        local el = { tag = name, attrs = attributes(rest), children = {} }
        local t = top()
        t.children[#t.children + 1] = el
        pos = e
        if RAW[name] then
          local s2, e2 = html:find("</%s*" .. name .. "%s*>", pos)
          if not s2 then
            local lower = html:lower()
            s2, e2 = lower:find("</%s*" .. name .. "%s*>", pos)
          end
          el.children[1] = html:sub(pos, (s2 or n + 1) - 1)
          pos = e2 and e2 + 1 or n + 1
        elseif not VOID[name] and not rest:match("/%s*$") then
          stack[#stack + 1] = el
        end
      end
    end
  end
  return root
end

-- ---- the page as blocks -------------------------------------------------------------

local HEADING = { h1 = 1, h2 = 2, h3 = 3, h4 = 4, h5 = 5, h6 = 6 }

local function text_of(el)
  if type(el) == "string" then return M.decode(el) end
  local out = {}
  for _, c in ipairs(el.children or {}) do out[#out + 1] = text_of(c) end
  return table.concat(out)
end

--- The page: { title, blocks } — each block one of
---   { kind = "heading", level, spans, id }   { kind = "para", spans, id }
---   { kind = "list", ordered, start, items = { { blocks } } }
---   { kind = "quote", blocks }   { kind = "code", text }   { kind = "rule" }
---   { kind = "table", rows = { { cells = { { spans, head } } } }, caption }
---   { kind = "image", src, alt, width, height, title }
--- and a span { text, bold, italic, code, link, strike, underline, mark, small }.
function M.parse(html)
  local root = M.tree(html)
  local doc = { title = nil, blocks = {} }

  local function find(el, tag)
    if type(el) ~= "table" then return nil end
    if el.tag == tag then return el end
    for _, c in ipairs(el.children) do
      local f = find(c, tag)
      if f then return f end
    end
  end
  local title = find(root, "title")
  if title then doc.title = text_of(title):gsub("%s+", " "):match("^%s*(.-)%s*$") end

  local function walk(children, out, style)
    local para = nil
    local function flush()
      if not para then return end
      -- Spaces at the edges of a paragraph go; inside, runs are one.
      local spans = para.spans
      while spans[1] and not spans[1].image and spans[1].text:match("^%s*$") do table.remove(spans, 1) end
      while spans[#spans] and not spans[#spans].image and spans[#spans].text:match("^%s*$") do table.remove(spans) end
      if spans[1] then spans[1].text = spans[1].text:gsub("^%s+", "") end
      if spans[#spans] then spans[#spans].text = spans[#spans].text:gsub("%s+$", "") end
      if #spans > 0 then out[#out + 1] = para end
      para = nil
    end
    local function add_text(t, st)
      if not st.pre then t = t:gsub("[ \t\r\n\f]+", " ") end
      if t == "" then return end
      para = para or { kind = "para", spans = {}, id = style.id }
      local last = para.spans[#para.spans]
      -- A space after a space is nothing.
      if not st.pre and last and last.text:match(" $") then t = t:gsub("^ ", "") end
      if not st.pre and not last and t:match("^ ") then t = t:gsub("^ ", "") end
      if t == "" then return end
      if last and not last.image and last.bold == st.bold and last.italic == st.italic and last.code == st.code
        and last.link == st.link and last.strike == st.strike and last.underline == st.underline and last.mark == st.mark
        and last.small == st.small and last.kbd == st.kbd then
        last.text = last.text .. t
      else
        para.spans[#para.spans + 1] = { text = t, bold = st.bold, italic = st.italic, code = st.code, link = st.link,
          strike = st.strike, underline = st.underline, mark = st.mark, small = st.small, kbd = st.kbd }
      end
    end
    local function inline(el, st)
      if type(el) == "string" then return add_text(M.decode(el), st) end
      local tag = el.tag
      if RAW[tag] and tag ~= "svg" then return end
      if tag == "br" then
        para = para or { kind = "para", spans = {}, id = style.id }
        para.spans[#para.spans + 1] = { text = "\n" }
        return
      end
      if tag == "img" then
        local w, h = tonumber(el.attrs.width), tonumber(el.attrs.height)
        local alt = el.attrs.alt ~= true and el.attrs.alt or nil
        -- A small one (an icon, a badge) stays in the line.
        if (w and w <= 96) or (h and h <= 48) then
          para = para or { kind = "para", spans = {}, id = style.id }
          para.spans[#para.spans + 1] = { text = "", image = { src = el.attrs.src, alt = alt, width = w, height = h },
            link = st.link }
          return
        end
        flush()
        out[#out + 1] = { kind = "image", src = el.attrs.src, alt = alt, width = w, height = h, title = el.attrs.title,
          link = st.link }
        return
      end
      if tag == "video" or tag == "audio" or tag == "iframe" or tag == "embed" or tag == "object" then
        flush()
        local src = el.attrs.src ~= true and el.attrs.src or el.attrs.data
        if not src or src == true then
          for _, c in ipairs(el.children) do
            if type(c) == "table" and c.tag == "source" and type(c.attrs.src) == "string" then src = c.attrs.src break end
          end
        end
        out[#out + 1] = { kind = "embed", tag = tag, src = src ~= true and src or nil,
          title = el.attrs.title ~= true and el.attrs.title or nil, poster = el.attrs.poster ~= true and el.attrs.poster or nil }
        return
      end
      if tag == "svg" then return add_text("[picture]", st) end
      local s2 = setmetatable({}, { __index = st })
      if tag == "b" or tag == "strong" then s2.bold = true
      elseif tag == "i" or tag == "em" or tag == "cite" or tag == "var" or tag == "dfn" then s2.italic = true
      elseif tag == "kbd" then s2.kbd = true s2.code = true
      elseif tag == "code" or tag == "samp" or tag == "tt" then s2.code = true
      elseif tag == "a" then s2.link = el.attrs.href ~= true and el.attrs.href or nil
      elseif tag == "s" or tag == "del" or tag == "strike" then s2.strike = true
      elseif tag == "u" or tag == "ins" then s2.underline = true
      elseif tag == "mark" then s2.mark = true
      elseif tag == "small" or tag == "sub" or tag == "sup" then s2.small = true end
      -- A copy of the style, not a link to its parent's: a table, so the
      -- spans' fields compare.
      local flat = { pre = st.pre }
      for _, k in ipairs({ "bold", "italic", "code", "link", "strike", "underline", "mark", "small", "kbd" }) do flat[k] = s2[k] end
      for _, c in ipairs(el.children) do
        if type(c) == "table" and (BLOCK[c.tag] or c.tag == "img" and false) then
          flush()
          walk({ c }, out, style)
        else
          inline(c, flat)
        end
      end
    end
    for _, c in ipairs(children) do
      if type(c) == "string" then
        inline(c, { pre = style.pre })
      else
        local tag = c.tag
        if RAW[tag] or tag == "head" or tag == "button" or tag == "select" or tag == "input" then
          -- nothing to read
        elseif HEADING[tag] then
          flush()
          local tmp = {}
          walk(c.children, tmp, { id = c.attrs.id })
          local spans = {}
          for _, b in ipairs(tmp) do for _, sp in ipairs(b.spans or {}) do spans[#spans + 1] = sp end end
          if #spans > 0 then out[#out + 1] = { kind = "heading", level = HEADING[tag], spans = spans, id = c.attrs.id } end
        elseif tag == "figcaption" then
          flush()
          local tmp = {}
          walk(c.children, tmp, {})
          for _, b in ipairs(tmp) do
            if b.kind == "para" then b.caption = true end
            out[#out + 1] = b
          end
        elseif tag == "p" or tag == "div" or tag == "section" or tag == "article" or tag == "main" or tag == "header"
          or tag == "footer" or tag == "nav" or tag == "aside" or tag == "figure" or tag == "body"
          or tag == "html" or tag == "center" or tag == "address" or tag == "form" or tag == "fieldset" or tag == "hgroup"
          or tag == "details" or tag == "dialog" or tag == "caption" then
          flush()
          walk(c.children, out, { id = c.attrs.id, pre = style.pre })
        elseif tag == "summary" or tag == "dt" or tag == "legend" then
          flush()
          local tmp = {}
          walk(c.children, tmp, {})
          for _, b in ipairs(tmp) do
            if b.spans then for _, sp in ipairs(b.spans) do sp.bold = true end end
            out[#out + 1] = b
          end
        elseif tag == "dd" then
          flush()
          local inner = {}
          walk(c.children, inner, {})
          out[#out + 1] = { kind = "quote", blocks = inner, plain = true }
        elseif tag == "ul" or tag == "ol" or tag == "menu" or tag == "dl" then
          flush()
          if tag == "dl" then
            walk(c.children, out, {})
          else
            local list = { kind = "list", ordered = tag == "ol", start = tonumber(c.attrs.start) or 1, items = {} }
            for _, li in ipairs(c.children) do
              if type(li) == "table" and li.tag == "li" then
                local inner = {}
                walk(li.children, inner, {})
                list.items[#list.items + 1] = { blocks = inner }
              elseif type(li) == "table" then
                local inner = {}
                walk({ li }, inner, {})
                if #inner > 0 then list.items[#list.items + 1] = { blocks = inner } end
              end
            end
            if #list.items > 0 then out[#out + 1] = list end
          end
        elseif tag == "li" then
          flush()
          local inner = {}
          walk(c.children, inner, {})
          out[#out + 1] = { kind = "list", ordered = false, start = 1, items = { { blocks = inner } } }
        elseif tag == "blockquote" then
          flush()
          local inner = {}
          walk(c.children, inner, {})
          out[#out + 1] = { kind = "quote", blocks = inner }
        elseif tag == "pre" then
          flush()
          local t = text_of(c):gsub("^\n", ""):gsub("%s+$", "")
          -- The language a highlighter was told: class="language-lua" on the
          -- <pre> or the <code> in it.
          local lang
          local function class_lang(el2)
            local cls = type(el2.attrs.class) == "string" and el2.attrs.class or ""
            return cls:match("language%-([%w_+#-]+)") or cls:match("lang%-([%w_+#-]+)")
          end
          lang = class_lang(c)
          for _, k in ipairs(c.children) do
            if not lang and type(k) == "table" and k.tag == "code" then lang = class_lang(k) end
          end
          out[#out + 1] = { kind = "code", text = t, lang = lang }
        elseif tag == "hr" then
          flush()
          out[#out + 1] = { kind = "rule" }
        elseif tag == "table" then
          flush()
          local tbl = { kind = "table", rows = {} }
          local function rows_in(el)
            for _, r in ipairs(el.children) do
              if type(r) == "table" then
                if r.tag == "tr" then
                  local row = { cells = {} }
                  for _, cell in ipairs(r.children) do
                    if type(cell) == "table" and (cell.tag == "td" or cell.tag == "th") then
                      local inner = {}
                      walk(cell.children, inner, {})
                      local spans = {}
                      for bi, b in ipairs(inner) do
                        if bi > 1 then spans[#spans + 1] = { text = " " } end
                        for _, sp in ipairs(b.spans or {}) do spans[#spans + 1] = sp end
                        if b.kind == "image" then spans[#spans + 1] = { text = "[" .. (b.alt or "picture") .. "]" } end
                      end
                      local align = cell.attrs.align ~= true and cell.attrs.align or nil
                      local style_attr = type(cell.attrs.style) == "string" and cell.attrs.style or ""
                      align = align or style_attr:match("text%-align%s*:%s*(%a+)")
                      row.cells[#row.cells + 1] = { spans = spans, head = cell.tag == "th" or r.head, align = align }
                    end
                  end
                  if #row.cells > 0 then tbl.rows[#tbl.rows + 1] = row end
                elseif r.tag == "thead" or r.tag == "tbody" or r.tag == "tfoot" then
                  if r.tag == "thead" then for _, tr in ipairs(r.children) do if type(tr) == "table" then tr.head = true end end end
                  rows_in(r)
                elseif r.tag == "caption" then
                  tbl.caption = text_of(r):gsub("%s+", " "):match("^%s*(.-)%s*$")
                end
              end
            end
          end
          rows_in(c)
          if #tbl.rows > 0 then out[#out + 1] = tbl end
        elseif tag == "img" then
          flush()
          inline(c, {})
        elseif BLOCK[tag] then
          flush()
          walk(c.children, out, {})
        else
          inline(c, { pre = style.pre })
        end
      end
    end
    flush()
  end

  walk(root.children, doc.blocks, {})
  return doc
end

-- ---- for a terminal ---------------------------------------------------------------

local function md_spans(spans)
  local out = {}
  for _, s in ipairs(spans or {}) do
    local t = s.text
    if s.image then t = "[" .. (s.image.alt or "picture") .. "]" end
    if s.code then t = "`" .. t .. "`"
    else
      if s.bold then t = "**" .. t .. "**" end
      if s.italic then t = "*" .. t .. "*" end
      if s.strike then t = "~~" .. t .. "~~" end
    end
    if s.link then t = "[" .. t .. "](" .. s.link .. ")" end
    out[#out + 1] = t
  end
  return table.concat(out):gsub("\n", "  \n")
end

--- The page as Markdown, for a terminal's markdown element.
function M.to_markdown(doc)
  local out = {}
  if doc.title and doc.title ~= "" then out[#out + 1] = "# " .. doc.title end
  local function emit(blocks, indent)
    local pad = string.rep("  ", indent)
    for _, b in ipairs(blocks) do
      if b.kind == "heading" then out[#out + 1] = pad .. string.rep("#", math.min(6, b.level + 1)) .. " " .. md_spans(b.spans)
      elseif b.kind == "para" then out[#out + 1] = pad .. md_spans(b.spans)
      elseif b.kind == "code" then out[#out + 1] = "```\n" .. b.text .. "\n```"
      elseif b.kind == "rule" then out[#out + 1] = "---"
      elseif b.kind == "image" then out[#out + 1] = pad .. "[picture: " .. (b.alt or b.src or "") .. "]"
      elseif b.kind == "embed" then out[#out + 1] = pad .. "[" .. b.tag .. ": " .. (b.title or b.src or "") .. "]"
      elseif b.kind == "quote" then
        local inner = {}
        local saved = out
        out = inner
        emit(b.blocks, 0)
        out = saved
        for _, l in ipairs(inner) do out[#out + 1] = pad .. "> " .. l:gsub("\n", "\n" .. pad .. "> ") end
      elseif b.kind == "list" then
        -- One block, its items line after line, a nested list indented.
        local lines = {}
        for i, item in ipairs(b.items) do
          local mark = b.ordered and ((b.start + i - 1) .. ".") or "-"
          local inner = {}
          local saved = out
          out = inner
          emit(item.blocks, 0)
          out = saved
          lines[#lines + 1] = pad .. mark .. " " .. (inner[1] or ""):gsub("\n", "\n" .. pad .. "   ")
          for k = 2, #inner do lines[#lines + 1] = pad .. "   " .. inner[k]:gsub("\n", "\n" .. pad .. "   ") end
        end
        out[#out + 1] = table.concat(lines, "\n")
      elseif b.kind == "table" then
        local lines = {}
        if b.caption and b.caption ~= "" then out[#out + 1] = "*" .. b.caption .. "*" end
        for ri, row in ipairs(b.rows) do
          local cells = {}
          for _, c in ipairs(row.cells) do cells[#cells + 1] = (md_spans(c.spans):gsub("|", "\\|")) end
          lines[#lines + 1] = "| " .. table.concat(cells, " | ") .. " |"
          if ri == 1 then
            local sep = {}
            for k = 1, #row.cells do sep[k] = "---" end
            lines[#lines + 1] = "|" .. table.concat(sep, "|") .. "|"
          end
        end
        out[#out + 1] = table.concat(lines, "\n")
      end
    end
  end
  emit(doc.blocks, 0)
  return table.concat(out, "\n\n")
end

return M
