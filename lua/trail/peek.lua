local M = {}

---Shows a peek match in a hover-style floating window. Pressing the same key
---again focuses it so it can be scrolled; moving the cursor closes it.
---@param match { path: string, start: integer, lines: string[] }
---@param info { filetype: string, total: integer, changed: boolean, on_open: fun() }
function M.show(match, info)
  local title = string.format(" %s:%d ", match.path, match.start)
  if info.changed then
    title = title .. "· changed in this review "
  end
  if info.total > 1 then
    title = title .. string.format("· 1 of %d ", info.total)
  end
  local buf, win = vim.lsp.util.open_floating_preview(match.lines, info.filetype, {
    border = "rounded",
    title = title,
    title_pos = "left",
    focus_id = "trail_peek",
    max_width = math.floor(vim.o.columns * 0.8),
    max_height = math.floor(vim.o.lines * 0.5),
  })
  vim.bo[buf].filetype = info.filetype
  vim.keymap.set("n", "<CR>", function()
    vim.api.nvim_win_close(win, true)
    info.on_open()
  end, { buffer = buf, desc = "Open as a buffer" })
  return win
end

local function large_window(buf, title)
  local width = math.floor(vim.o.columns * 0.9)
  local height = math.floor(vim.o.lines * 0.85)
  return vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    border = "rounded",
    title = title,
    title_pos = "left",
  })
end

local function at_line(win, line)
  vim.api.nvim_win_set_cursor(win, { math.min(line, vim.api.nvim_buf_line_count(0)), 0 })
  vim.cmd("normal! zvzt")
end

local definitions_tab
local back_tab
local left_tab

local function definitions_open()
  return definitions_tab ~= nil and vim.api.nvim_tabpage_is_valid(definitions_tab)
end

---Opens a real file at `line` in the definitions tab, as a normal buffer so
---language servers and other plugins attach, and jumps from it (gr, quickfix)
---stay in that tab instead of replacing the review. Every definition reuses
---the same tab, and `<C-o>` goes back through them. Closing the tab returns
---to `review_tab`.
function M.open_file(path, line, review_tab)
  back_tab = review_tab
  if definitions_open() then
    vim.api.nvim_set_current_tabpage(definitions_tab)
    vim.cmd("normal! m'")
    local ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape(path))
    if not ok then
      vim.notify("trail: " .. err, vim.log.levels.ERROR)
      return
    end
  else
    vim.cmd.tabedit(vim.fn.fnameescape(path))
    definitions_tab = vim.api.nvim_get_current_tabpage()
    local group = vim.api.nvim_create_augroup("trail.definitions", { clear = true })
    vim.api.nvim_create_autocmd("TabLeave", {
      group = group,
      callback = function()
        left_tab = vim.api.nvim_get_current_tabpage()
      end,
    })
    vim.api.nvim_create_autocmd("TabClosed", {
      group = group,
      callback = function()
        if definitions_open() then
          return
        end
        local was_current = left_tab == definitions_tab
        definitions_tab = nil
        vim.schedule(function()
          if was_current and back_tab and vim.api.nvim_tabpage_is_valid(back_tab) then
            vim.api.nvim_set_current_tabpage(back_tab)
          end
        end)
        return true
      end,
    })
  end
  local win = vim.api.nvim_get_current_win()
  at_line(win, line)
  return win
end

function M.close_definitions()
  if definitions_open() then
    local tab = definitions_tab
    definitions_tab = nil
    vim.cmd.tabclose(vim.api.nvim_tabpage_get_number(tab))
  end
end

---Opens a match's own lines read-only in a large floating window.
function M.open_lines(match, filetype, title)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, match.lines)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = filetype
  local win = large_window(buf, title)
  vim.wo[win][0].number = true
  return win
end

---The word under the cursor and the plain name written right before it with
---`.` or `::`, like `auth` in `auth.VerifyHash`.
function M.word_at_cursor()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1
  if not line:sub(col, col):match("[%w_]") then
    return nil
  end
  local first, last = col, col
  while first > 1 and line:sub(first - 1, first - 1):match("[%w_]") do
    first = first - 1
  end
  while line:sub(last + 1, last + 1):match("[%w_]") do
    last = last + 1
  end
  local before = line:sub(1, first - 1)
  local qualifier = before:match("([%w_]+)%.$") or before:match("([%w_]+)::$")
  return line:sub(first, last), qualifier
end

return M
