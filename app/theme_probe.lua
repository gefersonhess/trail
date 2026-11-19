-- Run in the user's own Neovim by the trail app: once their config has run,
-- writes their colors to $TRAIL_THEME_OUT and quits.
vim.api.nvim_create_autocmd("VimEnter", {
  once = true,
  callback = function()
    vim.schedule(function()
      local f = io.open(vim.env.TRAIL_THEME_OUT, "w")
      if f then
        f:write(vim.json.encode({ name = vim.g.colors_name, background = vim.o.background, groups = vim.api.nvim_get_hl(0, {}) }))
        f:close()
      end
      vim.cmd("qa!")
    end)
  end,
})
