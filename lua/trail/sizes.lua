---Sizes the user gives the trail app's tree and pane, kept when the app lays
---its windows out again. A window whose size is no longer the one trail set
---was resized by the user. That is checked only once a layout settles
---(WinResized), never while trail is moving windows, and not when the terminal
---itself was resized; the size is kept for the place the window had (tree on
---the left, pane at the bottom, ...) and used whenever a window is there again.
local M = {}

local wanted, applied = {}, {}

local function size(win, dim)
  return dim == "width" and vim.api.nvim_win_get_width(win) or vim.api.nvim_win_get_height(win)
end

local function note(win)
  local a = applied[win]
  if a and vim.api.nvim_win_is_valid(win) and size(win, a.dim) ~= a.value then
    a.value = size(win, a.dim)
    wanted[a.place] = a.value
  end
end

---Sets the width or height (`dim`) of `win`, in `place`: the size the user
---last gave it there, or `default`.
function M.apply(win, place, dim, default)
  local value = wanted[place] or default
  if dim == "width" then
    vim.api.nvim_win_set_width(win, value)
  else
    vim.api.nvim_win_set_height(win, value)
  end
  applied[win] = { place = place, dim = dim, value = size(win, dim) }
end

local screen = vim.o.columns .. "x" .. vim.o.lines

vim.api.nvim_create_autocmd("WinResized", {
  callback = function()
    local now = vim.o.columns .. "x" .. vim.o.lines
    for win, a in pairs(applied) do
      if now == screen then
        note(win)
      elseif vim.api.nvim_win_is_valid(win) then
        a.value = size(win, a.dim)
      end
    end
    screen = now
  end,
})
vim.api.nvim_create_autocmd("WinClosed", {
  callback = function(args)
    applied[tonumber(args.match)] = nil
  end,
})

return M
