---The trail app's side pane: one window beside the review that shows a thread
---or the comment box being written. Writing a comment holds the pane, so a
---thread can't replace a draft.
local M = {}

local win, holder, restore

---The pane's window, if it is open.
function M.win()
  if win and vim.api.nvim_win_is_valid(win) then
    return win
  end
end

---Whether a comment box holds the pane.
function M.held()
  return M.win() ~= nil and holder ~= nil and vim.api.nvim_win_get_buf(win) == holder
end

---Moves the pane to the right of a unified diff, or across the bottom of a
---side-by-side one, which needs the width.
function M.place()
  if not M.win() then
    return
  end
  local below = require("trail.diffview").side_by_side()
  vim.api.nvim_win_call(win, function()
    vim.cmd.wincmd(below and "J" or "L")
  end)
  local wo = vim.wo[win]
  wo.winfixwidth, wo.winfixheight = not below, below
  if below then
    vim.api.nvim_win_set_height(win, 10)
  else
    vim.api.nvim_win_set_width(win, math.min(46, math.floor(vim.o.columns * 0.3)))
  end
end

---Shows `buf` in the pane, opening it if needed, and leaves the focus in the pane.
---`again` shows the same content anew, for when a comment box is done with the pane.
function M.show(buf, again)
  if not M.win() then
    vim.cmd("botright vsplit")
    win = vim.api.nvim_get_current_win()
    local wo = vim.wo[win][0]
    wo.number, wo.relativenumber, wo.signcolumn, wo.statuscolumn = false, false, "no", ""
    wo.wrap, wo.linebreak, wo.cursorline = true, true, false
    M.place()
    restore = nil
  else
    vim.api.nvim_set_current_win(win)
  end
  vim.api.nvim_win_set_buf(win, buf)
  holder = nil
  restore = again or restore
  return win
end

---Shows a comment box's buffer in the pane and holds it until `release`.
function M.hold(buf)
  local had = M.win() and restore
  M.show(buf)
  holder = buf
  restore = had or nil
end

---Gives the pane back after a comment box: it shows again what it showed
---before, or closes if it was opened for the box.
function M.release()
  holder = nil
  if not M.win() then
    return
  end
  if restore then
    local back = vim.api.nvim_get_current_win()
    restore()
    if vim.api.nvim_win_is_valid(back) then
      vim.api.nvim_set_current_win(back)
    end
  else
    vim.api.nvim_win_close(win, true)
  end
end

return M
