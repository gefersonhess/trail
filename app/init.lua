-- The trail app: Neovim with trail's own config, started by `trail`.
-- The user's config and plugins stay out, so nothing else reaches the review.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)

vim.g.trail_app = true
vim.g.trail_tree = "left"

vim.o.termguicolors = true
vim.o.background = "dark"
vim.cmd.colorscheme("default")
vim.o.laststatus = 3
vim.o.showtabline = 2
vim.o.showmode = false
vim.o.ruler = false
vim.o.mouse = "a"
vim.o.swapfile = false
vim.o.tabline = "%!v:lua.require'trail'.tabline()"
vim.o.statusline = "%!v:lua.require'trail'.statusline()"

-- Trail's own colors, for when the user's Neovim can't be asked for theirs.
local function own_theme()
  local set = vim.api.nvim_set_hl
  set(0, "Normal", { fg = "#c9d1d9", bg = "#0e1116" })
  set(0, "NormalFloat", { fg = "#c9d1d9", bg = "#161b22" })
  set(0, "WinSeparator", { fg = "#30363d" })
  set(0, "WinBar", { fg = "#8b949e", bg = "#0e1116" })
  set(0, "WinBarNC", { fg = "#6e7681", bg = "#0e1116" })
  set(0, "CursorLine", { bg = "#1f2630" })
  set(0, "TabLine", { fg = "#8b949e", bg = "#161b22" })
  set(0, "TabLineSel", { fg = "#ffffff", bg = "#0e1116", bold = true })
  set(0, "TabLineFill", { bg = "#161b22" })
  set(0, "StatusLine", { fg = "#c9d1d9", bg = "#30363d" })
  set(0, "TrailTabBrand", { fg = "#58a6ff", bg = "#161b22", bold = true })
  set(0, "TrailModeNORMAL", { fg = "#0e1116", bg = "#58a6ff", bold = true })
  set(0, "TrailModeINSERT", { fg = "#0e1116", bg = "#3fb950", bold = true })
  set(0, "TrailModeVISUAL", { fg = "#0e1116", bg = "#bc8cff", bold = true })
  set(0, "TrailModeVLINE", { fg = "#0e1116", bg = "#bc8cff", bold = true })
  set(0, "TrailModeVBLOCK", { fg = "#0e1116", bg = "#bc8cff", bold = true })
  set(0, "TrailModeCOMMAND", { fg = "#0e1116", bg = "#d29922", bold = true })
  set(0, "TrailModeREPLACE", { fg = "#0e1116", bg = "#f85149", bold = true })
  set(0, "TrailModeTERMINAL", { fg = "#0e1116", bg = "#8b949e", bold = true })
end

-- The tab brand and the mode in the status line, in the user's colors.
local function derived()
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  -- The first of the groups with a color of its own, since themes leave some plain.
  local function fg(groups)
    for _, group in ipairs(groups) do
      local color = vim.api.nvim_get_hl(0, { name = group, link = false }).fg
      if color and color ~= normal.fg and color ~= normal.bg then
        return color
      end
    end
    return normal.fg
  end
  local accent = fg({ "Function", "Identifier", "Directory", "Title", "Special" })
  local fill = vim.api.nvim_get_hl(0, { name = "TabLineFill", link = false }).bg
  vim.api.nvim_set_hl(0, "TrailTabBrand", { fg = accent, bg = fill, bold = true })
  local visual = fg({ "Statement", "Keyword", "Type", "Special" })
  local modes = {
    NORMAL = accent, INSERT = fg({ "String", "DiagnosticOk", "Added" }), VISUAL = visual, VLINE = visual, VBLOCK = visual,
    COMMAND = fg({ "Constant", "DiagnosticWarn", "WarningMsg" }), REPLACE = fg({ "DiagnosticError", "Error", "ErrorMsg" }),
    TERMINAL = fg({ "Comment" }),
  }
  for mode, color in pairs(modes) do
    vim.api.nvim_set_hl(0, "TrailMode" .. mode, { fg = normal.bg, bg = color, bold = true })
  end
end

local app = require("trail.app")
local theme, why = app.user_theme(root .. "/app/theme_probe.lua", 3000)
if theme then
  app.apply(theme)
  derived()
else
  own_theme()
  vim.notify("trail: using its own colors, " .. why, vim.log.levels.WARN)
end

vim.cmd.runtime("plugin/trail.lua")

local group = vim.api.nvim_create_augroup("trail.app", {})
vim.api.nvim_create_autocmd("ModeChanged", { group = group, command = "redrawstatus" })
vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter", "CursorMoved" }, {
  group = group,
  callback = function()
    vim.cmd.redrawtabline()
  end,
})
vim.api.nvim_create_autocmd("CursorMoved", {
  group = group,
  pattern = { "trail://diff/*", "trail://base/*", "trail://head/*" },
  callback = function()
    require("trail").follow_thread()
  end,
})
vim.api.nvim_create_autocmd("VimEnter", {
  group = group,
  once = true,
  callback = function()
    require("trail").open(vim.env.TRAIL_ARGS or "")
  end,
})
