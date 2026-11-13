local M = {}

local ns = vim.api.nvim_create_namespace("trail.sidebyside")
local CONTEXT = 3
local line_numbers = {}

local palettes = {
  dark = {
    TrailAdd = { bg = "#1d3324" },
    TrailAddText = { bg = "#2e6b40" },
    TrailDelete = { bg = "#3d2326" },
    TrailDeleteText = { bg = "#7d2e36" },
    TrailFiller = { fg = "#3b3f48" },
  },
  light = {
    TrailAdd = { bg = "#e6ffec" },
    TrailAddText = { bg = "#abf2bc" },
    TrailDelete = { bg = "#ffebe9" },
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

function M.statuscolumn()
  if vim.v.virtnum ~= 0 then
    return ""
  end
  local map = line_numbers[vim.api.nvim_win_get_buf(vim.g.statusline_winid)]
  local n = map and map[vim.v.lnum]
  return n and string.format("%4d ", n) or "     "
end

local function by_line(changes)
  local out = {}
  for _, c in ipairs(changes) do
    out[c.line] = c.spans
  end
  return out
end

local function make_buf(name, path, lines, nums, changes, hl)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, name)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false
  if path then
    vim.bo[buf].filetype = vim.filetype.match({ filename = path, buf = buf }) or ""
  end
  line_numbers[buf] = nums
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    callback = function()
      line_numbers[buf] = nil
    end,
  })
  for row = 1, #lines do
    local n = nums[row]
    if not n then
      vim.api.nvim_buf_set_extmark(buf, ns, row - 1, 0, {
        virt_text = { { string.rep("╱", 400), "TrailFiller" } },
        virt_text_pos = "overlay",
      })
    elseif changes[n] then
      vim.api.nvim_buf_set_extmark(buf, ns, row - 1, 0, {
        end_row = row,
        end_col = 0,
        hl_group = hl.line,
        hl_eol = true,
        priority = 100,
      })
      for _, span in ipairs(changes[n]) do
        vim.api.nvim_buf_set_extmark(buf, ns, row - 1, span[1], {
          end_col = math.min(span[2], #lines[row]),
          hl_group = hl.text,
          priority = 200,
        })
      end
    end
  end
  return buf
end

local function unchanged_runs(changed, total)
  local runs, start = {}, nil
  for row = 1, total + 1 do
    if row <= total and not changed[row] then
      start = start or row
    elseif start then
      table.insert(runs, { start, row - 1 })
      start = nil
    end
  end
  return runs
end

---Shows `diff` (a file_diff result) side by side in the current tab.
---@return { focus: fun(side: "old"|"new", line: integer) }
function M.show(diff, opts)
  local old_changes, new_changes = by_line(diff.old_changes), by_line(diff.new_changes)
  local left, right, left_nums, right_nums, changed = {}, {}, {}, {}, {}
  local row_of = { old = {}, new = {} }
  for i, r in ipairs(diff.rows) do
    local o, n = r[1], r[2]
    left[i] = o and diff.old_lines[o] or ""
    right[i] = n and diff.new_lines[n] or ""
    left_nums[i], right_nums[i] = o, n
    if o then
      row_of.old[o] = i
    end
    if n then
      row_of.new[n] = i
    end
    changed[i] = not o or not n or old_changes[o] ~= nil or new_changes[n] ~= nil
  end

  local left_buf = make_buf("trail://base/" .. (opts.old_path or "(added)"), opts.old_path, left, left_nums,
    old_changes, { line = "TrailDelete", text = "TrailDeleteText" })
  local right_buf = make_buf("trail://head/" .. (opts.new_path or "(deleted)"), opts.new_path, right, right_nums,
    new_changes, { line = "TrailAdd", text = "TrailAddText" })

  local placeholder = vim.api.nvim_get_current_buf()
  local left_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(left_win, left_buf)
  if placeholder ~= left_buf and vim.api.nvim_buf_is_valid(placeholder) then
    vim.api.nvim_buf_delete(placeholder, { force = true })
  end
  vim.cmd("rightbelow vsplit")
  local right_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(right_win, right_buf)

  local starts = {}
  for row = 1, #diff.rows do
    if changed[row] and not changed[row - 1] then
      table.insert(starts, row)
    end
  end
  local folds = {}
  for _, run in ipairs(unchanged_runs(changed, #diff.rows)) do
    local first = run[1] == 1 and 1 or run[1] + CONTEXT
    local last = run[2] == #diff.rows and run[2] or run[2] - CONTEXT
    if last - first >= 1 then
      table.insert(folds, { first, last })
    end
  end

  local titles = {
    [left_win] = "base  " .. (opts.old_path or "(added)"),
    [right_win] = "head  " .. (opts.new_path or "(deleted)") .. "  ·  " .. diff.engine,
  }
  for _, win in ipairs({ left_win, right_win }) do
    local wo = vim.wo[win]
    wo.wrap, wo.number, wo.relativenumber, wo.list = false, false, false, false
    wo.signcolumn, wo.foldcolumn = "no", "0"
    wo.statuscolumn = "%!v:lua.require'trail.sidebyside'.statuscolumn()"
    wo.winbar = (titles[win]:gsub("%%", "%%%%"))
    wo.scrollbind, wo.cursorbind = true, true
    wo.foldmethod, wo.foldenable, wo.foldlevel = "manual", true, 0
    vim.api.nvim_win_call(win, function()
      vim.cmd("normal! zE")
      for _, f in ipairs(folds) do
        vim.cmd(string.format("%d,%dfold", f[1], f[2]))
      end
    end)
  end

  local function jump(dir)
    local cur = vim.api.nvim_win_get_cursor(0)[1]
    local target
    for i = dir > 0 and 1 or #starts, dir > 0 and #starts or 1, dir do
      if (dir > 0 and starts[i] > cur) or (dir < 0 and starts[i] < cur) then
        target = starts[i]
        break
      end
    end
    if target then
      vim.api.nvim_win_set_cursor(0, { target, 0 })
      vim.cmd("normal! zz")
    end
  end
  for _, buf in ipairs({ left_buf, right_buf }) do
    vim.keymap.set("n", "]h", function()
      jump(1)
    end, { buffer = buf, desc = "Next change" })
    vim.keymap.set("n", "[h", function()
      jump(-1)
    end, { buffer = buf, desc = "Previous change" })
    for _, key in ipairs({ "-", "q" }) do
      vim.keymap.set("n", key, opts.on_back, { buffer = buf, desc = "Back to trail list" })
    end
  end

  return {
    focus = function(side, line)
      local win = side == "old" and left_win or right_win
      local row = row_of[side][line] or 1
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_win_set_cursor(win, { row, 0 })
      vim.cmd("normal! zvzz")
    end,
  }
end

return M
