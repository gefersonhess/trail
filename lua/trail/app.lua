---What the trail app needs from the user's own Neovim: running it, and its colors.
local M = {}

---The command running the user's own Neovim with `args`: without $NVIM, so
---plugins don't hand files back to the review, and with their NVIM_APPNAME
---rather than the app's.
function M.user_nvim(args)
  local cmd = { "env", "-u", "NVIM" }
  local own = vim.env.TRAIL_USER_APPNAME
  vim.list_extend(cmd, own and own ~= "" and { "NVIM_APPNAME=" .. own } or { "-u", "NVIM_APPNAME" })
  table.insert(cmd, vim.v.progpath)
  return vim.list_extend(cmd, args)
end

---The user's colors: their Neovim is started headless, and once its config
---has run it writes out every highlight group. Nil if that fails or takes
---longer than `timeout` milliseconds.
---@return { name: string?, background: string, groups: table<string, table> }?
function M.user_theme(probe, timeout)
  local out = vim.fn.tempname()
  local done = vim.system(M.user_nvim({ "--headless", "-n", "-i", "NONE", "--cmd", "luafile " .. vim.fn.fnameescape(probe) }),
    { env = { TRAIL_THEME_OUT = out }, stdin = false }):wait(timeout)
  local ok, theme = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(out), "\n"))
  end)
  vim.fn.delete(out)
  if done.code ~= 0 or not ok or type(theme) ~= "table" or type(theme.groups) ~= "table" then
    return nil
  end
  return theme
end

---Replaces every highlight group with the user's.
function M.apply(theme)
  vim.cmd("highlight clear")
  vim.o.background = theme.background
  for name, spec in pairs(theme.groups) do
    pcall(vim.api.nvim_set_hl, 0, name, spec)
  end
  vim.g.colors_name = theme.name
end

return M
