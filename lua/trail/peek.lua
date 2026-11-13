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

---Opens `path` at `line` in a separate Neovim inside a large floating
---terminal. It runs with the user's own config and knows nothing about the
---review, so LSP, pickers and their jumps behave as in any session and stay
---inside it. Quitting that Neovim closes the window.
function M.open_editor(path, line, title)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local win = large_window(buf, title)
  -- Without $NVIM, plugins that hand files back to a parent Neovim keep them in
  -- this one. -n skips swap files, since the review's Neovim may have the file open.
  local cmd = { "env", "-u", "NVIM", vim.v.progpath, "-n", "+" .. line, path }
  local opts = {
    on_exit = function()
      -- A startinsert still pending would otherwise land in the review window.
      vim.cmd.stopinsert()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end,
  }
  if vim.fn.has("nvim-0.11") == 1 then
    opts.term = true
    vim.fn.jobstart(cmd, opts)
  else
    vim.fn.termopen(cmd, opts)
  end
  pcall(vim.api.nvim_buf_set_name, buf, "trail://editor/" .. vim.fn.fnamemodify(path, ":t"))
  -- A global <Esc> mapping that leaves terminal mode would keep <Esc> from the editor inside.
  vim.keymap.set("t", "<Esc>", "<Esc>", { buffer = buf })
  vim.cmd.startinsert()
  return win
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
