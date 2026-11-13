local graph = require("trail.graph")
local help = require("trail.help")

local M = {}

local ns = vim.api.nvim_create_namespace("trail.pathview")
local view

local function valid()
  return view and vim.api.nvim_win_is_valid(view.graph_win) and vim.api.nvim_win_get_buf(view.graph_win) == view.graph_buf
end

local function graph_height(lines)
  return math.max(1, math.min(lines, math.floor(vim.o.lines / 3)))
end

local function render_graph()
  local ctx, path = view.ctx, view.path
  local lines, hls, step_of_row = graph.render(path, ctx.review(), { current = view.step, done = ctx.done_steps(path) })
  local header = string.format(" %s  ·  step %d of %d", path.title, view.step, #path.steps)
  table.insert(lines, 1, header)
  view.step_of_row = {}
  for row, step in pairs(step_of_row) do
    view.step_of_row[row + 1] = step
  end
  local buf = view.graph_buf
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, { end_col = #header, hl_group = "Title" })
  for _, h in ipairs(hls) do
    vim.api.nvim_buf_set_extmark(buf, ns, h[1] + 1, h[2], { end_col = h[3], hl_group = h[4] })
  end
  vim.api.nvim_win_set_height(view.graph_win, graph_height(#lines))
  for row, step in pairs(view.step_of_row) do
    if step == view.step then
      vim.api.nvim_win_set_cursor(view.graph_win, { row, 0 })
      break
    end
  end
end

local function show_step(i, focus_graph)
  local path = view.path
  i = math.max(1, math.min(i, #path.steps))
  view.step = i
  view.ctx.on_step(path, i)
  render_graph()
  local target = path.steps[i]
  view.ctx.show_target(target.node or target.hunk, target.node ~= nil, view.diff_win, view.keys, function()
    if focus_graph and vim.api.nvim_win_is_valid(view.graph_win) then
      vim.api.nvim_set_current_win(view.graph_win)
    end
  end)
end

function M.step(delta)
  if not valid() then
    return
  end
  local target = view.step + delta
  if target < 1 or target > #view.path.steps then
    vim.notify(delta > 0 and "trail: last step of this path" or "trail: first step of this path", vim.log.levels.INFO)
    return
  end
  show_step(target, vim.api.nvim_get_current_win() == view.graph_win)
end

---The path and step being shown, if the path view is open.
function M.current()
  if valid() then
    return view.path, view.step
  end
end

function M.refresh_graph()
  if valid() then
    render_graph()
  end
end

---Opens `path` at `step` in the review window: the call graph on top, the diff below.
---@param ctx table callbacks from the plugin: review, show_target, home, window, switch_path, done_steps, on_step
function M.open(ctx, path, step)
  if valid() then
    vim.api.nvim_set_current_tabpage(view.tab)
  else
    local diff_win = ctx.window()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    vim.api.nvim_buf_set_name(buf, "trail://graph")
    vim.cmd("aboveleft split")
    local graph_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(graph_win, buf)
    local wo = vim.wo[graph_win][0]
    wo.winfixheight, wo.number, wo.relativenumber, wo.wrap, wo.cursorline = true, false, false, false, false
    wo.signcolumn, wo.foldcolumn, wo.statuscolumn = "no", "0", ""
    view = { tab = vim.api.nvim_get_current_tabpage(), graph_win = graph_win, graph_buf = buf, diff_win = diff_win }

    local function map(lhs, fn, desc)
      vim.keymap.set("n", lhs, fn, { buffer = buf, desc = desc, nowait = true })
    end
    map("<CR>", function()
      local step = view.step_of_row[vim.api.nvim_win_get_cursor(0)[1]]
      if step then
        show_step(step, true)
      end
    end, "Show this step")
    map("n", function()
      M.step(1)
    end, "Next step")
    map("p", function()
      M.step(-1)
    end, "Previous step")
    map("-", function()
      view.ctx.home()
    end, "Back to the paths screen")
    map("q", function()
      view.ctx.home()
    end, "Back to the paths screen")
    map("gp", function()
      view.ctx.switch_path()
    end, "Switch path")
    map("?", help.show, "Show keys")
  end
  view.ctx = ctx
  view.path = path
  view.keys = {
    { "]s", function()
      M.step(1)
    end, "Next step" },
    { "[s", function()
      M.step(-1)
    end, "Previous step" },
    { "gp", ctx.switch_path, "Switch path" },
  }
  show_step(step or 1, false)
end

return M
