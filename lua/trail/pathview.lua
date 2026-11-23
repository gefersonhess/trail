local tree = require("trail.tree")
local pathmap = require("trail.map")
local help = require("trail.help")

local sizes = require("trail.sizes")

local M = {}

local ns = vim.api.nvim_create_namespace("trail.pathview")
local view

local function valid()
  return view and vim.api.nvim_win_is_valid(view.tree_win) and vim.api.nvim_win_get_buf(view.tree_win) == view.tree_buf
end

---Whether the tree sits on the left of the diff (`vim.g.trail_tree = "left"`)
---rather than above it. Side by side needs the width, so the tree goes on top.
local function tree_on_left()
  return vim.g.trail_tree == "left" and not require("trail.diffview").side_by_side()
end

---Whether the tree is hidden: in the app, side by side shows the call chain
---in the diff's winbar instead of the tree, giving its rows to the code.
local function tree_hidden()
  return vim.g.trail_tree == "left" and require("trail.diffview").side_by_side()
end

local TREE_WIDTH = 38

local function tree_height(lines)
  return math.max(1, math.min(lines, math.floor(vim.o.lines / 3)))
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

local details_ns = vim.api.nvim_create_namespace("trail.pathview.details")

---Shows the cursor row's details (step, interface, tests, package) at its end.
local function show_details()
  if not valid() then
    return
  end
  vim.api.nvim_buf_clear_namespace(view.tree_buf, details_ns, 0, -1)
  local row = vim.api.nvim_win_get_cursor(view.tree_win)[1]
  local it = view.item_of_row[row]
  if it and it.details and it.details ~= "" then
    vim.api.nvim_buf_set_extmark(view.tree_buf, details_ns, row - 1, 0,
      { virt_text = { { "   " .. it.details, "Comment" } }, virt_text_pos = "eol" })
  end
end

local function render_tree(keep_cursor)
  local ctx, path = view.ctx, view.path
  vim.wo[view.tree_win].cursorline = true
  local expanded = expanded_by_path[path.id] or {}
  local lines, hls, item_of_row
  if path.impact then
    lines, hls, item_of_row = tree.render(path.impact, {
      expanded = expanded,
      all = all_by_path[path.id],
      current = view.step,
      station = view.station,
      done = ctx.done_steps(path),
      threads = function(id)
        return ctx.threads(path)[id] or 0
      end,
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
  local cursor = keep_cursor and vim.api.nvim_win_get_cursor(view.tree_win)
  local before = cursor and view.item_of_row and view.item_of_row[cursor[1]]
  view.item_of_row = {}
  for row, item in pairs(item_of_row) do
    view.item_of_row[row + 1] = item
  end
  -- The cursor stays on the row it was on, wherever opening a fold moved it.
  if before and before.node then
    for row = 1, #lines do
      local item = view.item_of_row[row]
      if item and item.node and item.node.id == before.node.id and item.again == before.again then
        cursor = { row, 0 }
        break
      end
    end
  end
  local buf = view.tree_buf
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, { end_col = #header, hl_group = "Title" })
  for _, h in ipairs(hls) do
    vim.api.nvim_buf_set_extmark(buf, ns, h[1] + 1, h[2], { end_col = h[3], hl_group = h[4] })
  end
  if vim.g.trail_tree ~= "left" then
    sizes.apply(view.tree_win, "tree.top", "height", tree_height(#lines))
  end
  if cursor then
    pcall(vim.api.nvim_win_set_cursor, view.tree_win, cursor)
  else
    for row, item in pairs(view.item_of_row) do
      if item.step == view.step then
        vim.api.nvim_win_set_cursor(view.tree_win, { row, 0 })
        break
      end
    end
  end
  show_details()
end

---The step's first change: its first hunk, on the side the function is on,
---from the function's first line when the hunk starts above it (a new file,
---a changed doc comment).
local function first_change(step)
  local h = view.ctx.hunks_of(step)[1]
  local node = step.node
  if not (h and node) then
    return h
  end
  local function inside(side)
    local r, own = h[side], node[side]
    if not own or r.len == 0 or r.start >= own.start + own.len or own.start >= r.start + r.len then
      return nil
    end
    local start = math.max(r.start, own.start)
    return { start = start, len = r.len - (start - r.start) }
  end
  local old = inside("old")
  if old then
    return vim.tbl_extend("force", h, { old = old })
  end
  local new = inside("new")
  if new then
    return vim.tbl_extend("force", h, { old = { start = h.old.start, len = 0 }, new = new })
  end
  return h
end

---The diff's winbar for function `id`: the route to it from an entry point,
---and how many other functions of the path call it.
local function header(id)
  local impact = view.path.impact
  if not (impact and id) then
    return nil
  end
  local nodes = pathmap.graph(impact).nodes
  local route, others = tree.chain(impact, id)
  local names = vim.tbl_map(function(n)
    return (nodes[n] and nodes[n].short or n:gsub("^%w+:", "")):gsub("%%", "%%%%")
  end, route)
  names[#names] = "%#TrailChainCurrent#▶" .. names[#names] .. "%*"
  local bar = "%#TrailChain#%<" .. table.concat(names, "%#TrailChain# › ")
  if others > 0 then
    bar = bar .. "%#Comment#  +" .. others .. (others == 1 and " caller" or " callers") .. "%*"
  end
  return bar
end

local function show_step(i, focus_tree, hunk)
  local path = view.path
  i = math.max(1, math.min(i, #path.steps))
  view.step = i
  view.station = path.steps[i].node and path.steps[i].node.id or nil
  view.ctx.on_step(path, i)
  render_tree()
  local target = path.steps[i]
  hunk = hunk or (target.node and first_change(target))
  local shown = hunk and vim.tbl_extend("force", hunk, { at_start = true }) or target.node or target.hunk
  -- Moving to a line of the step's file keeps the step's function in focus.
  local node = target.node
  if hunk and node and hunk.file == node.file then
    shown.focus = { old = node.old, new = node.new }
  end
  shown = vim.tbl_extend("force", shown, { header = header(view.station) })
  view.ctx.show_target(shown, hunk == nil and target.node ~= nil, view.diff_win, view.keys, function()
    if focus_tree and not tree_hidden() and vim.api.nvim_win_is_valid(view.tree_win) then
      vim.api.nvim_set_current_win(view.tree_win)
    end
  end)
end

---Shows an unchanged function from the tree in the diff window, in its file,
---at `line` or its first line.
local function show_function(node, line)
  view.station = node.id
  render_tree(true)
  view.ctx.show_target({ file = node.file, new = { start = line or node.line, len = 1 }, header = header(node.id) }, true,
    view.diff_win, view.keys, function()
      if not tree_hidden() and vim.api.nvim_win_is_valid(view.tree_win) then
        vim.api.nvim_set_current_win(view.tree_win)
      end
    end)
end

---Shows the change `id` of the path: its step, or its function when it is
---an unchanged entry point; at `line` of its file, or its first change.
local function show_change(id, focus_tree, line)
  local i = step_of_node(view.path, id)
  local node = pathmap.graph(view.path.impact).nodes[id]
  if i then
    show_step(i, focus_tree, line and { file = node.file, new = { start = line, len = 1 }, old = { start = 0, len = 0 } })
  else
    show_function(node, line)
  end
end

---The first line where `from` calls `to`, if it calls it by name.
local function call_line(from, to)
  local first
  for _, e in ipairs(view.path.impact.edges) do
    if e.from == from and e.to == to then
      for _, l in ipairs(e.lines or {}) do
        first = math.min(first or l, l)
      end
    end
  end
  return first
end

---Opens the review's map: every path through the packages it reaches, this
---one in colour, with the function shown marked.
function M.map()
  if not valid() or not view.path.impact then
    return
  end
  local ctx = view.ctx
  local paths = ctx.paths()
  local selected
  for i, p in ipairs(paths) do
    if p.id == view.path.id then
      selected = i
    end
  end
  if not selected then
    return
  end
  local node = view.path.steps[view.step].node
  pathmap.open(paths, {
    selected = selected,
    current = view.station or (node and node.id),
    done = function(i)
      return vim.tbl_count(vim.tbl_filter(function(d)
        return d
      end, ctx.done_steps(paths[i])))
    end,
    pick = function(i, package)
      if not valid() then
        return
      end
      if i == selected and package and not pathmap.step_in(view.path, package) then
        return
      end
      ctx.enter(paths[i], package and pathmap.step_in(paths[i], package) or nil)
    end,
  })
end

---Moves to the next or previous step. Going forward follows the tree: on the
---way from one branch to the next, the walk stops first at the row they hang
---from, on the line calling the next one, then goes into it. A branch it
---doesn't call by name (a type it uses) follows the one before directly,
---unless the walk is climbing out of a deeper branch.
function M.step(delta)
  if not valid() then
    return
  end
  local path = view.path
  local function last()
    vim.notify(delta > 0 and "trail: last step of this path" or "trail: first step of this path", vim.log.levels.INFO)
  end
  local focus_tree = vim.api.nvim_get_current_win() == view.tree_win
  local order = delta > 0 and path.impact and tree.walk(path.impact) or {}
  local index = {}
  for k, r in ipairs(order) do
    index[r.id] = index[r.id] or k
  end
  local from = index[view.station]
  if not from then
    local target = view.step + delta
    if target < 1 or target > #path.steps then
      return last()
    end
    return show_step(target, focus_tree)
  end
  local pending = view.pending
  view.pending = nil
  if pending and pending.path == path and pending.at == view.station then
    return show_change(pending.to, focus_tree)
  end
  local to
  for k = from + 1, #order do
    if step_of_node(path, order[k].id) then
      to = k
      break
    end
  end
  if not to then
    return last()
  end
  local function chain(k)
    local out = {}
    while k do
      out[k] = true
      k = order[k].parent
    end
    return out
  end
  local above_to = chain(to)
  local shared = from
  while shared and not above_to[shared] do
    shared = order[shared].parent
  end
  -- With no row in common, the branch just finished is the whole tree.
  local stop = shared
  if not stop then
    stop = from
    while order[stop].parent do
      stop = order[stop].parent
    end
  end
  local line = shared and call_line(order[shared].id, order[to].call)
  if stop ~= from and (order[from].parent ~= stop or line) then
    view.pending = { path = path, at = order[stop].id, to = order[to].id }
    return show_change(order[stop].id, focus_tree, line)
  end
  show_change(order[to].id, focus_tree)
end

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

---Moves the tree to where the layout wants it in the app: the left of a
---unified diff, or hidden beside a side-by-side one.
function M.place()
  if not valid() or vim.g.trail_tree ~= "left" then
    return
  end
  local floating = vim.api.nvim_win_get_config(view.tree_win).relative ~= ""
  if tree_hidden() then
    if not floating then
      sizes.forget(view.tree_win)
      vim.api.nvim_win_set_config(view.tree_win,
        { relative = "editor", row = 0, col = 0, width = 1, height = 1, hide = true, focusable = false })
    end
    return
  end
  if floating then
    vim.api.nvim_win_set_config(view.tree_win, { split = "left", win = -1 })
  end
  vim.api.nvim_win_call(view.tree_win, function()
    vim.cmd.wincmd("H")
  end)
  local wo = vim.wo[view.tree_win]
  wo.winfixwidth, wo.winfixheight = true, false
  sizes.apply(view.tree_win, "tree.left", "width", TREE_WIDTH)
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
    vim.cmd(tree_on_left() and "topleft vsplit" or "aboveleft split")
    local tree_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(tree_win, buf)
    local wo = vim.wo[tree_win][0]
    if tree_on_left() then
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
    map("gm", M.map, "Map of the review's paths")
    map("<C-p>", function()
      view.ctx.find()
    end, "Find a changed function")
    local function item()
      return view.item_of_row[vim.api.nvim_win_get_cursor(0)[1]] or {}
    end
    local function open_fold(key)
      local expanded = expanded_by_path[view.path.id] or {}
      expanded[key] = not expanded[key] or nil
      expanded_by_path[view.path.id] = expanded
      render_tree(true)
    end
    map("<CR>", function()
      local it = item()
      if it.fold then
        open_fold(it.fold)
      elseif it.step then
        show_step(it.step, true)
      elseif it.node then
        show_change(it.node.id, true)
      end
    end, "Open the fold, or show this function below")
    map("za", function()
      local it = item()
      if it.fold or it.toggle then
        open_fold(it.fold or it.toggle)
      end
    end, "Open or close what this row folds")
    map("zR", function()
      expanded_by_path[view.path.id] = { ["*"] = true }
      render_tree(true)
    end, "Open everything")
    vim.api.nvim_create_autocmd("CursorMoved", { buffer = buf, callback = show_details })
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
    map("]s", function()
      M.step(1)
    end, "Next step")
    map("[s", function()
      M.step(-1)
    end, "Previous step")
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
    { "gm", M.map, "Map of the review's paths" },
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
