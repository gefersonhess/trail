-- Run in the user's own Neovim by the trail app: once their config has run
-- and their colorscheme has settled, writes their colors to $TRAIL_THEME_OUT
-- and quits.
local function dump()
  local f = io.open(vim.env.TRAIL_THEME_OUT, "w")
  if f then
    f:write(vim.json.encode({ name = vim.g.colors_name, background = vim.o.background, groups = vim.api.nvim_get_hl(0, {}) }))
    f:close()
  end
  vim.cmd("qa!")
end

vim.api.nvim_create_autocmd("VimEnter", {
  once = true,
  callback = function()
    vim.schedule(function()
      -- Without a screen UIEnter never comes, and configs wait for it to set
      -- their colorscheme (LazyVim's VeryLazy).
      vim.api.nvim_exec_autocmds("UIEnter", {})
      -- Configs also set it a moment later (vim.defer_fn), so the colors are
      -- read once no colorscheme has been applied for a while.
      local quiet = assert(vim.uv.new_timer())
      local function wait()
        quiet:start(150, 0, vim.schedule_wrap(dump))
      end
      vim.api.nvim_create_autocmd("ColorScheme", { callback = wait })
      wait()
    end)
  end,
})
