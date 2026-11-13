local help = require("trail.help")

local M = {}

local ns = vim.api.nvim_create_namespace("trail.diffview")
local CONTEXT = 3
local gutters = {}
local chosen_layout
local chosen_folding

local palettes = {
  dark = {
    TrailAdd = { fg = "#3fb950", bold = true },
    TrailAddText = { bg = "#2e6b40" },
    TrailDelete = { fg = "#f85149", bold = true },
    TrailDeleteText = { bg = "#7d2e36" },
    TrailFiller = { fg = "#3b3f48" },
  },
  light = {
    TrailAdd = { fg = "#1a7f37", bold = true },
    TrailAddText = { bg = "#abf2bc" },
    TrailDelete = { fg = "#cf222e", bold = true },
    TrailDeleteText = { bg = "#ffb3b0" },
    TrailFiller = { fg = "#d0d7de" },
  },
}

local function set_highlights()
  for name, spec in pairs(palettes[vim.o.background] or palettes.dark) do
    vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", spec, { default = true }))
  end
end
set_highlights()
vim.api.nvim_create_autocmd("ColorScheme", { callback = set_highlights })

local function layout()
  return chosen_layout or vim.g.trail_layout or "unified"
end

local function fold_unchanged()
  if chosen_folding ~= nil then
    return chosen_folding
  end
  return vim.g.trail_fold_unchanged ~= false
end

function M.statuscolumn()
  if vim.v.virtnum ~= 0 then
    return ""
  end
  local g = gutters[vim.api.nvim_win_get_buf(vim.g.statusline_winid)]
  local e = g and g.rows[vim.v.lnum]
  if not e then
    return g and g.unified and "            " or "       "
  end
  local mark = e.mark and string.format("%%#%s#%s%%*", e.mark == "+" and "TrailAdd" or "TrailDelete", e.mark) or " "
  if g.unified then
    return string.format("%4s %4s %s ", e.old or "", e.new or "", mark)
  end
  return string.format("%4d %s ", e.old or e.new, mark)
end

local function by_line(changes)
  local out = {}
  for _, c in ipairs(changes) do
    out[c.line] = c.spans
  end
  return out
end

---@param view { lines: string[], gutter: table[], spans: table[], fillers: integer[] }
local function make_buf(name, path, view, unified)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, name)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, view.lines)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false
  if path then
    vim.bo[buf].filetype = vim.filetype.match({ filename = path, buf = buf }) or ""
  end
  gutters[buf] = { rows = view.gutter, unified = unified }
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    callback = function()
      gutters[buf] = nil
    end,
  })
  for _, row in ipairs(view.fillers) do
    vim.api.nvim_buf_set_extmark(buf, ns, row - 1, 0, {
      virt_text = { { string.rep("╱", 400), "TrailFiller" } },
      virt_text_pos = "overlay",
    })
  end
  for _, s in ipairs(view.spans) do
    vim.api.nvim_buf_set_extmark(buf, ns, s.row - 1, s.from, {
      end_col = math.min(s.to, #view.lines[s.row]),
      hl_group = s.hl,
      priority = 200,
    })
  end
  return buf
end

local function add_spans(view, row, spans, hl)
  for _, s in ipairs(spans or {}) do
    table.insert(view.spans, { row = row, from = s[1], to = s[2], hl = hl })
  end
end

local function empty_view()
  return { lines = {}, gutter = {}, spans = {}, fillers = {} }
end

local function side_by_side_views(diff, old_ch, new_ch)
  local left, right, changed = empty_view(), empty_view(), {}
  for i, r in ipairs(diff.rows) do
    local o, n = r[1], r[2]
    left.lines[i] = o and diff.old_lines[o] or ""
    right.lines[i] = n and diff.new_lines[n] or ""
    if o then
      left.gutter[i] = { old = o, mark = old_ch[o] and "-" or nil }
      add_spans(left, i, old_ch[o], "TrailDeleteText")
    else
      table.insert(left.fillers, i)
    end
    if n then
      right.gutter[i] = { new = n, mark = new_ch[n] and "+" or nil }
      add_spans(right, i, new_ch[n], "TrailAddText")
    else
      table.insert(right.fillers, i)
    end
    changed[i] = not o or not n or old_ch[o] ~= nil or new_ch[n] ~= nil
  end
  return left, right, changed
end

local function unified_view(diff, old_ch, new_ch)
  local view, changed = empty_view(), {}
  local function add(text, entry, spans, hl)
    table.insert(view.lines, text)
    local row = #view.lines
    view.gutter[row] = entry
    changed[row] = hl ~= nil
    add_spans(view, row, spans, hl)
  end
  local function real(r)
    return (r[1] and old_ch[r[1]] ~= nil) or (r[2] and new_ch[r[2]] ~= nil) or false
  end
  local function context(r)
    return r[1] and r[2] and not real(r)
  end
  local i = 1
  while i <= #diff.rows do
    local r = diff.rows[i]
    if context(r) then
      add(diff.new_lines[r[2]], { old = r[1], new = r[2] })
      i = i + 1
    else
      local j, any_real = i, real(r)
      while j < #diff.rows and not context(diff.rows[j + 1]) do
        j = j + 1
        any_real = any_real or real(diff.rows[j])
      end
      if not any_real then
        for k = i, j do
          local n = diff.rows[k][2]
          if n then
            add(diff.new_lines[n], { old = diff.rows[k][1], new = n })
          end
        end
      else
        for k = i, j do
          local o = diff.rows[k][1]
          if o then
            add(diff.old_lines[o], { old = o, mark = old_ch[o] and "-" or nil }, old_ch[o], "TrailDeleteText")
          end
        end
        for k = i, j do
          local n = diff.rows[k][2]
          if n then
            add(diff.new_lines[n], { new = n, mark = new_ch[n] and "+" or nil }, new_ch[n], "TrailAddText")
          end
        end
      end
      i = j + 1
    end
  end
  return view, changed
end

local function folds_and_starts(changed, total)
  local folds, starts, run_start = {}, {}, nil
  for row = 1, total + 1 do
    if row <= total and changed[row] and not changed[row - 1] then
      table.insert(starts, row)
    end
    if row <= total and not changed[row] then
      run_start = run_start or row
    elseif run_start then
      local first = run_start == 1 and 1 or run_start + CONTEXT
      local last = row - 1 == total and total or row - 1 - CONTEXT
      if last - first >= 1 then
        table.insert(folds, { first, last })
      end
      run_start = nil
    end
  end
  return folds, starts
end

local function apply_folds(win, folds)
  vim.api.nvim_win_call(win, function()
    vim.cmd("normal! zE")
    if fold_unchanged() then
      for _, f in ipairs(folds) do
        vim.cmd(string.format("%d,%dfold", f[1], f[2]))
      end
    end
  end)
end

local function setup_window(win, title, folds, unified, bind)
  local wo = vim.wo[win][0]
  wo.wrap, wo.number, wo.relativenumber, wo.list = false, false, false, false
  wo.signcolumn, wo.foldcolumn = "no", "0"
  wo.statuscolumn = "%!v:lua.require'trail.diffview'.statuscolumn()"
  wo.winbar = title:gsub("%%", "%%%%") .. "%=%#Comment#? keys %*"
  wo.scrollbind, wo.cursorbind = bind, bind
  wo.foldmethod, wo.foldenable, wo.foldlevel = "manual", true, 0
  apply_folds(win, folds)
end

local function row_for(view, side, line)
  local best
  for row, e in pairs(view.gutter) do
    local n = e[side]
    if n == line then
      return row
    end
    if n and n < line and (not best or n > view.gutter[best][side]) then
      best = row
    end
  end
  return best or 1
end

---Shows `diff` (a file_diff result) in the current tab, replacing what is there.
---`t` switches between the unified and side-by-side layouts.
---@return { focus: fun(side: "old"|"new", line: integer) }
function M.show(diff, opts)
  local old_ch, new_ch = by_line(diff.old_changes), by_line(diff.new_changes)
  local old_name = opts.old_path or "(added)"
  local new_name = opts.new_path or "(deleted)"
  local first_win = opts.win or vim.api.nvim_get_current_win()
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(first_win))) do
    if w ~= first_win and vim.w[w].trail_pane then
      vim.api.nvim_win_close(w, true)
    end
  end
  vim.api.nvim_set_current_win(first_win)
  vim.w[first_win].trail_pane = true
  local placeholder = vim.api.nvim_create_buf(false, true)
  vim.bo[placeholder].bufhidden = "wipe"
  vim.api.nvim_win_set_buf(first_win, placeholder)

  local panes
  if layout() == "unified" then
    local view, changed = unified_view(diff, old_ch, new_ch)
    local buf = make_buf("trail://diff/" .. new_name, opts.new_path or opts.old_path, view, true)
    vim.api.nvim_win_set_buf(first_win, buf)
    local folds, starts = folds_and_starts(changed, #view.lines)
    setup_window(first_win, new_name .. "  ·  " .. diff.engine, folds, true, false)
    panes = { { win = first_win, buf = buf, view = view, starts = starts, folds = folds } }
  else
    local left, right, changed = side_by_side_views(diff, old_ch, new_ch)
    local left_buf = make_buf("trail://base/" .. old_name, opts.old_path, left, false)
    local right_buf = make_buf("trail://head/" .. new_name, opts.new_path, right, false)
    vim.api.nvim_win_set_buf(first_win, left_buf)
    vim.cmd("rightbelow vsplit")
    local right_win = vim.api.nvim_get_current_win()
    vim.w[right_win].trail_pane = true
    vim.api.nvim_win_set_buf(right_win, right_buf)
    local folds, starts = folds_and_starts(changed, #diff.rows)
    setup_window(first_win, "base  " .. old_name, folds, false, true)
    setup_window(right_win, "head  " .. new_name .. "  ·  " .. diff.engine, folds, false, true)
    panes = {
      { win = first_win, buf = left_buf, view = left, starts = starts, folds = folds },
      { win = right_win, buf = right_buf, view = right, starts = starts, folds = folds },
    }
  end
  if vim.api.nvim_buf_is_valid(placeholder) and vim.fn.bufwinid(placeholder) == -1 then
    pcall(vim.api.nvim_buf_delete, placeholder, { force = true })
  end

  local function pane_of(win)
    for _, p in ipairs(panes) do
      if p.win == win then
        return p
      end
    end
    return panes[1]
  end

  local function position()
    local p = pane_of(vim.api.nvim_get_current_win())
    local row = vim.api.nvim_win_get_cursor(p.win)[1]
    local other = panes[1] == p and panes[2] or panes[1]
    for _, q in ipairs({ p, other }) do
      local e = q.view.gutter[row]
      if e and e.new then
        return "new", e.new
      elseif e and e.old then
        return "old", e.old
      end
    end
    return "new", 1
  end

  local hunk_ends = {}
  for _, p in ipairs(panes) do
    for _, h in ipairs(opts.hunks or {}) do
      local last
      for row, e in pairs(p.view.gutter) do
        local in_old = e.old and h.old.len > 0 and e.old >= h.old.start and e.old < h.old.start + h.old.len
        local in_new = e.new and h.new.len > 0 and e.new >= h.new.start and e.new < h.new.start + h.new.len
        if (in_old or in_new) and (not last or row > last) then
          last = row
        end
      end
      if last then
        table.insert(hunk_ends, { pane = p, id = h.id, row = last })
      end
    end
  end

  ---Reports hunks whose last line is on screen, so the caller can count them as seen.
  local function report_seen()
    if not opts.on_seen then
      return
    end
    local seen = {}
    for _, he in ipairs(hunk_ends) do
      local win = he.pane.win
      if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == he.pane.buf
        and vim.api.nvim_win_get_tabpage(win) == vim.api.nvim_get_current_tabpage() then
        local top, bottom = vim.fn.line("w0", win), vim.fn.line("w$", win)
        if he.row >= top and he.row <= bottom then
          table.insert(seen, he.id)
        end
      end
    end
    if #seen > 0 then
      opts.on_seen(seen)
    end
  end
  for _, p in ipairs(panes) do
    vim.api.nvim_create_autocmd({ "CursorMoved", "WinScrolled" }, {
      buffer = p.buf,
      callback = function()
        report_seen()
      end,
    })
  end

  local view = {}
  function view.focus(side, line)
    local p = panes[1]
    if #panes == 2 and side == "new" then
      p = panes[2]
    end
    vim.api.nvim_set_current_win(p.win)
    vim.api.nvim_win_set_cursor(p.win, { row_for(p.view, side, line), 0 })
    vim.cmd("normal! zvzz")
    report_seen()
  end

  local function jump(dir)
    local p = pane_of(vim.api.nvim_get_current_win())
    local cur = vim.api.nvim_win_get_cursor(p.win)[1]
    local first, last = 1, #p.starts
    if dir < 0 then
      first, last = last, first
    end
    for i = first, last, dir do
      local row = p.starts[i]
      if (dir > 0 and row > cur) or (dir < 0 and row < cur) then
        vim.api.nvim_win_set_cursor(p.win, { row, 0 })
        vim.cmd("normal! zvzz")
        return
      end
    end
  end

  local function toggle()
    local side, line = position()
    chosen_layout = layout() == "unified" and "side_by_side" or "unified"
    M.show(diff, vim.tbl_extend("force", opts, { win = panes[1].win })).focus(side, line)
  end

  local function side_at_cursor()
    local p = pane_of(vim.api.nvim_get_current_win())
    if #panes == 2 then
      return p == panes[1] and "old" or "new"
    end
    local e = p.view.gutter[vim.api.nvim_win_get_cursor(p.win)[1]]
    return e and e.mark == "-" and "old" or "new"
  end

  local function toggle_folds()
    chosen_folding = not fold_unchanged()
    for _, p in ipairs(panes) do
      apply_folds(p.win, p.folds)
    end
    vim.cmd("normal! zz")
  end

  for _, p in ipairs(panes) do
    local function map(key, fn, desc)
      vim.keymap.set("n", key, fn, { buffer = p.buf, desc = desc })
    end
    map("]h", function()
      jump(1)
    end, "Next change")
    map("[h", function()
      jump(-1)
    end, "Previous change")
    map("t", toggle, "Toggle unified and side-by-side")
    map("o", toggle_folds, "Show or fold unchanged code")
    map("?", help.show, "Show keys")
    map("K", function()
      opts.on_peek(side_at_cursor())
    end, "Peek the function under the cursor")
    map("gd", function()
      opts.on_definition(side_at_cursor())
    end, "Open the function under the cursor as a buffer")
    map("-", opts.on_back, "Back to the paths screen")
    map("q", opts.on_back, "Back to the paths screen")
    for _, k in ipairs(opts.keys or {}) do
      map(k[1], k[2], k[3])
    end
  end
  return view
end

return M
