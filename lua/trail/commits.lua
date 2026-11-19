---The Commits screen: a review's commits, oldest first, to narrow the review
---to one of them or to a run of them, or widen it back to all.
local help = require("trail.help")

local M = {}

local ns = vim.api.nvim_create_namespace("trail.commits")
local screen

---"commit 2 of 5", or "commits 2-4 of 5".
function M.label(first, last, total)
  if first == last then
    return string.format("commit %d of %d", first, total)
  end
  return string.format("commits %d-%d of %d", first, last, total)
end

local function render()
  local buf, ctx = screen.buf, screen.ctx
  local lines, hls, rows = {}, {}, {}
  local function add(text, hl)
    table.insert(lines, text)
    for _, h in ipairs(hl or {}) do
      table.insert(hls, { #lines - 1, h[1], h[2], h[3] })
    end
  end
  local list, picked = screen.list, ctx.picked()
  local title = "Commits of " .. ctx.title
  local showing = picked and M.label(picked.first, picked.last, #(list or {})) or "all"
  add(title .. "  ·  reviewing " .. showing, { { 0, #title, "Title" }, { #title, -1, "Comment" } })
  add("<CR> reviews the commit  ·  V and <CR> a run of them  ·  a all of them  ·  - back", { { 0, -1, "Comment" } })
  add("")
  if not list then
    add("Listing the commits…", { { 0, -1, "Comment" } })
  elseif screen.error then
    add("Couldn't list the commits: " .. screen.error, { { 0, -1, "ErrorMsg" } })
  end
  local width = 0
  for _, c in ipairs(list or {}) do
    width = math.max(width, vim.fn.strdisplaywidth(c.subject))
  end
  for i, c in ipairs(list or {}) do
    local inside = not picked or (i >= picked.first and i <= picked.last)
    local mark = inside and "▎" or " "
    local head = string.format("%s %2d  %s  %s", mark, i, c.short, c.subject)
    head = head .. string.rep(" ", width - vim.fn.strdisplaywidth(c.subject) + 3)
    local meta = c.author .. " · " .. c.date
    add(head .. meta, {
      { 0, #mark, "TrailAddText" },
      { #mark + 5, #mark + 5 + #c.short, "Identifier" },
      { #head, -1, "Comment" },
      not inside and { #mark, #head, "Comment" } or nil,
    })
    rows[#lines] = i
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, h in ipairs(hls) do
    local stop = h[3] >= 0 and h[3] or #lines[h[1] + 1]
    vim.api.nvim_buf_set_extmark(buf, ns, h[1], h[2], { end_col = stop, hl_group = h[4] })
  end
  screen.rows = rows
end

local function pick(from_row, to_row)
  local first, last
  for row = math.min(from_row, to_row), math.max(from_row, to_row) do
    local i = screen.rows[row]
    if i then
      first, last = first or i, i
    end
  end
  if first then
    screen.ctx.pick(screen.list, first, last)
  end
end

---Opens the screen in the review's window. `ctx`: title, window(), home(),
---list(cb) giving the commits, picked() giving { first, last } or nil, and
---pick(list, first, last), with nil for all of them.
function M.open(ctx)
  if not (screen and vim.api.nvim_buf_is_valid(screen.buf)) then
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.api.nvim_buf_set_name(buf, "trail://commits")
    vim.b[buf].trail_screen = "commits"
    screen = { buf = buf }
    local function map(mode, lhs, fn, desc)
      vim.keymap.set(mode, lhs, fn, { buffer = buf, desc = desc, nowait = true })
    end
    map("n", "<CR>", function()
      local row = vim.api.nvim_win_get_cursor(0)[1]
      pick(row, row)
    end, "Review this commit")
    map("x", "<CR>", function()
      local a, b = vim.fn.line("v"), vim.fn.line(".")
      vim.cmd.normal({ args = { "\27" }, bang = true })
      pick(a, b)
    end, "Review the selected commits")
    map("n", "a", function()
      if screen.list then
        screen.ctx.pick(screen.list, nil, nil)
      end
    end, "Review all the commits")
    map("n", "-", function()
      screen.ctx.home()
    end, "Back to the paths screen")
    map("n", "q", function()
      screen.ctx.home()
    end, "Back to the paths screen")
    map("n", "?", help.show, "Show keys")
  end
  screen.ctx = ctx
  vim.api.nvim_win_set_buf(ctx.window(), screen.buf)
  render()
  if not screen.list then
    ctx.list(function(err, list)
      if not (screen and vim.api.nvim_buf_is_valid(screen.buf)) then
        return
      end
      screen.list, screen.error = list or {}, err and err.message
      render()
    end)
  end
end

---Forgets the commits listed, for another review.
function M.reset()
  if screen then
    screen.list = nil
  end
end

return M
