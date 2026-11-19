local tree = require("trail.tree")
local route = require("trail.route")
local help = require("trail.help")

local sizes = require("trail.sizes")

local M = {}

local ns = vim.api.nvim_create_namespace("trail.pathview")
local view

local function valid()
  return view and vim.api.nvim_win_is_valid(view.tree_win) and vim.api.nvim_win_get_buf(view.tree_win) == view.tree_buf
end

---Whether `path` shows as a route line rather than a tree: impact paths do,
---unless `vim.g.trail_graph = "tree"` (`gt` switches).
local function routed(path)
  return vim.g.trail_graph ~= "tree" and path ~= nil and path.impact ~= nil
end

---Whether the tree sits on the left of the diff (`vim.g.trail_tree = "left"`)
---rather than above it. Side by side needs the width, so the tree goes on top,
---and so does a route line.
local function tree_on_left(path)
  return vim.g.trail_tree == "left" and not require("trail.diffview").side_by_side() and not routed(path)
end

local TREE_WIDTH = 38

local function tree_height(lines)
  local most = vim.g.trail_tree == "left" and 8 or math.floor(vim.o.lines / 3)
  return math.max(1, math.min(lines, most))
end

---A path with no impact tree (a test file, or hunks in no path) as a list of its steps.
local function list_lines(path, current, done)
  local lines, hls, item_of_row = {}, {}, {}
  for i, step in ipairs(path.steps) do
    local label
    if step.node then
      label = step.node.id:gsub("^%w+:", "")
    else
      local h = step.hunk
      local side = h.new.len > 0 and h.new or h.old
      label = string.format("%s:%d-%d", h.file, side.start, side.start + math.max(side.len, 1) - 1)
    end
    local marker = i == current and "▶ " or (done[i] and "✓ " or "  ")
    local line = marker .. label
    table.insert(lines, line)
    if i == current then
      table.insert(hls, { #lines - 1, 0, #line, "TrailCurrentStep" })
    end
    item_of_row[#lines] = { step = i }
  end
  return lines, hls, item_of_row
end

---Folds the user opened, and whether the path shows every function, per
---path, kept while the review is open.
local expanded_by_path = {}
local all_by_path = {}

local function step_of_node(path, id)
  for i, step in ipairs(path.steps) do
    if step.node and step.node.id == id then
      return i
    end
  end
end

local function count(n, word)
  return n .. " " .. word .. (n == 1 and "" or "s")
end

---The route through the function shown: the stations from an entry point to
---the last change below, the one shown highlighted, and under it how many
---other callers and callees it has.
local function render_route()
  local path = view.path
  local g = route.graph(path.impact)
  local here = view.station
  if not (here and (g.step_of[here] or vim.tbl_contains(g.entries, here))) then
    local node = path.steps[view.step].node
    here = node and node.id or g.entries[1]
  end
  view.station = here
  local ids, index = route.through(g, here, route.prefer(path.id))
  view.route, view.route_index = ids, index
  local done = view.ctx.done_steps(path)
  local width = vim.api.nvim_win_get_width(view.tree_win)
  local line, hls, cols = route.draw(g, ids, {
    current = here,
    anchor = index,
    width = width - 2,
    done = function(id)
      local i = step_of_node(path, id)
      return i ~= nil and done[i] == true
    end,
  })
  line = " " .. line
  local hints = {}
  local callers, callees = #(g.parents[here] or {}), #(g.children[here] or {})
  if callers > 1 then
    table.insert(hints, "k " .. count(callers - 1, "more caller"))
  end
  if callees > 1 then
    table.insert(hints, "j " .. count(callees - 1, "more callee"))
  end
  local hint = table.concat(hints, " · ")
  local step = string.format("step %d of %d", view.step, #path.steps)
  if vim.fn.strdisplaywidth(hint .. step) + 4 > width then
    step = ""
  end
  local at = vim.fn.strdisplaywidth(line:sub(1, cols[index] + 1))
  local room = width - vim.fn.strdisplaywidth(step) - 2
  at = math.max(0, math.min(at, room - vim.fn.strdisplaywidth(hint) - 2))
  local second = string.rep(" ", at) .. hint
  second = second .. string.rep(" ", math.max(2, width - vim.fn.strdisplaywidth(second .. step) - 1)) .. step
  local buf = view.tree_buf
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line, second })
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, h in ipairs(hls) do
    vim.api.nvim_buf_set_extmark(buf, ns, 0, h[1] + 1, { end_col = h[2] + 1, hl_group = h[3] })
  end
  vim.api.nvim_buf_set_extmark(buf, ns, 1, 0, { end_col = #second, hl_group = "Comment" })
  view.item_of_row = {}
  vim.api.nvim_win_set_height(view.tree_win, 2)
  vim.api.nvim_win_set_cursor(view.tree_win, { 1, cols[index] + 1 })
end

local function render_tree(keep_cursor)
  local ctx, path = view.ctx, view.path
  vim.wo[view.tree_win].cursorline = not routed(path)
  if routed(path) then
    return render_route()
  end
  local expanded = expanded_by_path[path.id] or {}
  local lines, hls, item_of_row
  if path.impact then
    lines, hls, item_of_row = tree.render(path.impact, {
      expanded = expanded,
      all = all_by_path[path.id],
      current = view.step,
      done = ctx.done_steps(path),
    })
  else
    lines, hls, item_of_row = list_lines(path, view.step, ctx.done_steps(path))
  end
  local header = string.format(" %s  ·  step %d of %d", path.title, view.step, #path.steps)
  if path.impact then
    local functions = #vim.tbl_filter(function(n)
      return not n.is_test
    end, path.impact.nodes)
    header = header .. string.format("  ·  %d functions", functions)
  end
  table.insert(lines, 1, header)
  view.item_of_row = {}
  for row, item in pairs(item_of_row) do
    view.item_of_row[row + 1] = item
  end
  local cursor = keep_cursor and vim.api.nvim_win_get_cursor(view.tree_win)
  local buf = view.tree_buf
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, { end_col = #header, hl_group = "Title" })
  for _, h in ipairs(hls) do
    vim.api.nvim_buf_set_extmark(buf, ns, h[1] + 1, h[2], { end_col = h[3], hl_group = h[4] })
  end
  if not tree_on_left(path) then
    sizes.apply(view.tree_win, "tree.top", "height", tree_height(#lines))
  end
  if cursor then
    pcall(vim.api.nvim_win_set_cursor, view.tree_win, cursor)
    return
  end
  for row, item in pairs(view.item_of_row) do
    if item.step == view.step then
      vim.api.nvim_win_set_cursor(view.tree_win, { row, 0 })
      break
    end
  end
end

local function show_step(i, focus_tree, hunk)
  local path = view.path
  i = math.max(1, math.min(i, #path.steps))
  view.step = i
  view.station = path.steps[i].node and path.steps[i].node.id or nil
  view.ctx.on_step(path, i)
  render_tree()
  local target = path.steps[i]
  local shown = hunk and vim.tbl_extend("force", hunk, { at_start = true }) or target.node or target.hunk
  -- Moving to a line of the step's file keeps the step's function in focus.
  local node = target.node
  if hunk and node and hunk.file == node.file then
    shown.focus = { old = node.old, new = node.new }
  end
  view.ctx.show_target(shown, hunk == nil and target.node ~= nil, view.diff_win, view.keys, function()
    if focus_tree and vim.api.nvim_win_is_valid(view.tree_win) then
      vim.api.nvim_set_current_win(view.tree_win)
    end
  end)
end

---Shows an unchanged function from the tree in the diff window, in its file.
local function show_function(node, stay)
  view.station = node.id
  render_tree(true)
  view.ctx.show_target({ file = node.file, new = { start = node.line, len = 1 } }, true, view.diff_win, view.keys,
    function()
      if not stay and vim.api.nvim_win_is_valid(view.tree_win) then
        vim.api.nvim_set_current_win(view.tree_win)
      end
    end)
end

---Shows the station `id` of the route: its step, or its function when it is
---an unchanged entry point.
local function show_station(id, stay)
  local i = step_of_node(view.path, id)
  if i then
    show_step(i, not stay)
  else
    show_function(route.graph(view.path.impact).nodes[id], stay)
  end
end

---Moves along the route: to the caller above (-1) or the callee below (1).
---From the diff (`stay`), focus stays there.
function M.move(delta, stay)
  if not valid() or not view.route then
    return
  end
  local id = view.route[view.route_index + delta]
  if not id then
    vim.notify(delta > 0 and "trail: last change on this route" or "trail: entry point of this route", vim.log.levels.INFO)
    return
  end
  show_station(id, stay)
end

---Lists the other callers (`"up"`) or callees (`"down"`) of the station
---shown. Picking a caller changes the route above it; picking a callee
---moves to it.
function M.branch(dir)
  if not valid() or not view.route then
    return
  end
  local path = view.path
  local g = route.graph(path.impact)
  local here = view.station
  local ids = (dir == "up" and g.parents or g.children)[here]
  if not ids then
    vim.notify(dir == "up" and "trail: nothing above reaches this" or "trail: no change below this", vim.log.levels.INFO)
    return
  end
  local done = view.ctx.done_steps(path)
  local on_route = view.route[view.route_index + (dir == "up" and -1 or 1)]
  view.ctx.pick(ids, {
    prompt = dir == "up" and "Reached from" or "Calls",
    current = on_route,
    format = function(id)
      local i = step_of_node(path, id)
      local mark = i and (done[i] and "● " or "○ ") or "  "
      return mark .. g.nodes[id].short
    end,
  }, function(id)
    if not id or not valid() then
      return
    end
    local prefer = route.prefer(path.id)
    if dir == "up" then
      prefer.up[here] = id
      render_tree()
    else
      prefer.down[here] = id
      show_station(id)
    end
  end)
end

vim.api.nvim_create_autocmd("WinResized", {
  callback = function()
    if valid() and routed(view.path) and view.step and vim.tbl_contains(vim.v.event.windows, view.tree_win) then
      render_tree()
    end
  end,
})

function M.step(delta)
  if not valid() then
    return
  end
  local target = view.step + delta
  if target < 1 or target > #view.path.steps then
    vim.notify(delta > 0 and "trail: last step of this path" or "trail: first step of this path", vim.log.levels.INFO)
    return
  end
  show_step(target, vim.api.nvim_get_current_win() == view.tree_win)
end

---Moves to the next change of the path (dir 1) or the previous one (dir -1):
---the hunks of its steps only, continuing into the next step when this one
---has none left.
function M.change(dir)
  if not valid() then
    return
  end
  local ctx, steps = view.ctx, view.path.steps
  local hunks = ctx.hunks_of(steps[view.step])
  local found = ctx.next_hunk(hunks, dir)
  if found == false then
    return show_step(view.step, false, dir > 0 and hunks[1] or hunks[#hunks])
  end
  if found then
    return ctx.focus_hunk(found)
  end
  local target = view.step + dir
  if target < 1 or target > #steps then
    vim.notify(dir > 0 and "trail: last change of this path" or "trail: first change of this path", vim.log.levels.INFO)
    return
  end
  local next_hunks = ctx.hunks_of(steps[target])
  show_step(target, false, dir > 0 and next_hunks[1] or next_hunks[#next_hunks])
end

---Moves to the next review thread of the path (dir 1) or the previous one.
function M.thread(dir)
  if not valid() then
    return
  end
  local found = view.ctx.next_thread(view.path, view.step, dir)
  if not found then
    vim.notify(dir > 0 and "trail: no more threads in this path" or "trail: no threads before this in the path", vim.log.levels.INFO)
  elseif found.here then
    view.ctx.focus_line(found.side, found.line)
  else
    show_step(found.step, false, found.target)
  end
end

---Shows `line` of `file` as part of step `step`: the step's own function, or
---a function of the path reached from it. Without a line, the step's start.
function M.go(step, file, line)
  if not valid() then
    return
  end
  show_step(step, false, line and { file = file, new = { start = line, len = 1 }, old = { start = 0, len = 0 } } or nil)
end

---The path and step being shown, if the path view is open.
function M.current()
  if valid() then
    return view.path, view.step
  end
end

---Moves the tree to where the layout wants it: the left of a unified diff,
---or across the top of a side-by-side one.
function M.place()
  if not valid() or (vim.g.trail_tree ~= "left" and not routed(view.path)) then
    return
  end
  local left = tree_on_left(view.path)
  vim.api.nvim_win_call(view.tree_win, function()
    vim.cmd.wincmd(left and "H" or "K")
  end)
  local wo = vim.wo[view.tree_win]
  wo.winfixwidth, wo.winfixheight = left, not left
  if left then
    sizes.apply(view.tree_win, "tree.left", "width", TREE_WIDTH)
  elseif routed(view.path) then
    vim.api.nvim_win_set_height(view.tree_win, 2)
  else
    local lines = vim.api.nvim_buf_line_count(view.tree_buf)
    sizes.apply(view.tree_win, "tree.top", "height", tree_height(lines))
    if lines <= vim.api.nvim_win_get_height(view.tree_win) then
      vim.api.nvim_win_call(view.tree_win, function()
        vim.fn.winrestview({ topline = 1 })
      end)
    end
  end
end

function M.refresh_graph()
  if valid() then
    render_tree(true)
  end
end

---Opens `path` at `step` in the review window: the path's tree on top (or on
---the left), the diff beside it.
---@param ctx table callbacks from the plugin: show_target, peek_node, home, window, switch_path, done_steps, on_step, toggle_reviewed
function M.open(ctx, path, step, target)
  if valid() then
    vim.api.nvim_set_current_tabpage(view.tab)
  else
    local diff_win = ctx.window()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    vim.api.nvim_buf_set_name(buf, "trail://path")
    vim.cmd(tree_on_left(path) and "topleft vsplit" or "aboveleft split")
    local tree_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(tree_win, buf)
    local wo = vim.wo[tree_win][0]
    if tree_on_left(path) then
      sizes.apply(tree_win, "tree.left", "width", TREE_WIDTH)
      wo.winfixwidth = true
    else
      wo.winfixheight = true
    end
    wo.number, wo.relativenumber, wo.wrap, wo.cursorline = false, false, false, true
    wo.signcolumn, wo.foldcolumn, wo.statuscolumn = "no", "0", ""
    view = { tab = vim.api.nvim_get_current_tabpage(), tree_win = tree_win, tree_buf = buf, diff_win = diff_win }

    local function map(lhs, fn, desc)
      vim.keymap.set("n", lhs, fn, { buffer = buf, desc = desc, nowait = true })
    end
    ---A key that moves along the route, and is Vim's own in the tree.
    local function route_map(lhs, fn, desc)
      map(lhs, function()
        if routed(view.path) then
          fn()
        else
          vim.cmd.normal({ args = { vim.v.count1 .. lhs }, bang = true })
        end
      end, desc)
    end
    route_map("h", function()
      M.move(-1)
    end, "Caller above on the route")
    route_map("l", function()
      M.move(1)
    end, "Callee below on the route")
    route_map("k", function()
      M.branch("up")
    end, "Other callers: pick the route above")
    route_map("j", function()
      M.branch("down")
    end, "Other callees: move to one")
    map("gt", function()
      vim.g.trail_graph = routed(view.path) and "tree" or "route"
      M.place()
      render_tree()
    end, "Switch between the route and the tree")
    map("<C-p>", function()
      view.ctx.find()
    end, "Find a changed function")
    local function item()
      return view.item_of_row[vim.api.nvim_win_get_cursor(0)[1]] or {}
    end
    map("<CR>", function()
      local it = item()
      if it.fold then
        local expanded = expanded_by_path[view.path.id] or {}
        expanded[it.fold] = true
        expanded_by_path[view.path.id] = expanded
        render_tree(true)
      elseif it.step then
        show_step(it.step, true)
      elseif it.node then
        show_function(it.node)
      end
    end, "Open the fold, or show this function below")
    map("c", function()
      expanded_by_path[view.path.id] = nil
      all_by_path[view.path.id] = nil
      render_tree()
    end, "Fold back to the changes")
    map("a", function()
      all_by_path[view.path.id] = not all_by_path[view.path.id] or nil
      render_tree()
    end, "Show every function on the way, or only the changes")
    map("K", function()
      local it = item()
      if it.node then
        view.ctx.peek_node(it.node)
      end
    end, "Show this function's code")
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
    map("mr", function()
      view.ctx.toggle_reviewed(view.path)
    end, "Mark the path as reviewed, or unmark it")
    map("]t", function()
      M.thread(1)
    end, "Next review thread in this path")
    map("[t", function()
      M.thread(-1)
    end, "Previous review thread in this path")
    map("]c", function()
      M.change(1)
    end, "Next change in this path")
    map("[c", function()
      M.change(-1)
    end, "Previous change in this path")
    map("?", help.show, "Show keys")

  end
  view.ctx = ctx
  if view.path ~= path then
    view.station = nil
  end
  view.path = path
  M.place()
  view.keys = {
    { "]s", function()
      M.step(1)
    end, "Next step" },
    { "[s", function()
      M.step(-1)
    end, "Previous step" },
    { "gp", ctx.switch_path, "Switch path" },
    { "<C-p>", ctx.find, "Find a changed function" },
    { "]r", function()
      M.move(1, true)
    end, "Callee below on the route" },
    { "[r", function()
      M.move(-1, true)
    end, "Caller above on the route" },
    { "mr", function()
      ctx.toggle_reviewed(view.path)
    end, "Mark the path as reviewed, or unmark it" },
    { "]c", function()
      M.change(1)
    end, "Next change in this path" },
    { "]t", function()
      M.thread(1)
    end, "Next review thread in this path" },
    { "[t", function()
      M.thread(-1)
    end, "Previous review thread in this path" },
    { "[c", function()
      M.change(-1)
    end, "Previous change in this path" },
  }
  show_step(step or 1, false, target)
end

return M
