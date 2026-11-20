---A path's changes drawn as boxes in a floating window, callers above what
---they call, for seeing a path's shape at once. The function shown and the
---ones it calls or is called by stand out; the rest is dimmed.
local M = {}

local ns = vim.api.nvim_create_namespace("trail.map")

local graphs = setmetatable({}, { __mode = "k" })

---The stations of an impact path (its entry points and steps) and which
---reaches which, in the order the trees show them.
function M.graph(impact)
  if graphs[impact] then
    return graphs[impact]
  end
  local nodes, step_of = {}, {}
  for _, n in ipairs(impact.nodes) do
    nodes[n.id] = n
  end
  for i, id in ipairs(impact.steps) do
    step_of[id] = i
  end
  local parents, children, linked = {}, {}, {}
  local function link(from, to)
    local key = from .. "\0" .. to
    if from == to or linked[key] then
      return
    end
    linked[key] = true
    parents[to] = parents[to] or {}
    children[from] = children[from] or {}
    table.insert(parents[to], from)
    table.insert(children[from], to)
  end
  local entries = {}
  for _, tree in ipairs(impact.trees) do
    local above = {}
    for k, row in ipairs(tree.rows) do
      for d = #above, row.depth + 1, -1 do
        above[d] = nil
      end
      local station = k == 1 or step_of[row.id] ~= nil
      if k == 1 then
        table.insert(entries, row.id)
      elseif station then
        for d = row.depth, 1, -1 do
          if above[d] and above[d].station then
            link(above[d].id, row.id)
            break
          end
        end
      end
      above[row.depth + 1] = { id = row.id, station = station and not row.join }
    end
  end
  local g = { nodes = nodes, step_of = step_of, parents = parents, children = children, entries = entries }
  g.roots, g.kids = M.spanning(g)
  graphs[impact] = g
  return g
end

---Each change once, under the first caller to reach it depth first: the
---roots and each station's children. An entry point reaching only changes
---already placed is not a root.
function M.spanning(g)
  local visited, kids, roots = {}, {}, {}
  local function visit(id)
    kids[id] = {}
    for _, c in ipairs(g.children[id] or {}) do
      if not visited[c] then
        visited[c] = true
        table.insert(kids[id], c)
        visit(c)
      end
    end
  end
  for _, entry in ipairs(g.entries) do
    if not visited[entry] then
      local own = g.step_of[entry] ~= nil or vim.iter(g.children[entry] or {}):any(function(c)
        return not visited[c]
      end)
      if own then
        visited[entry] = true
        table.insert(roots, entry)
        visit(entry)
      end
    end
  end
  return roots, kids
end
local GAP = 3

---Lays the spanning tree out as boxes: each subtree as wide as its widest
---level, its children side by side under it and centred below it, levels
---four rows apart.
local function layout(g, label)
  local width = {}
  local function measure(id)
    local box = vim.fn.strdisplaywidth(label(id)) + 4
    local below = 0
    for i, c in ipairs(g.kids[id] or {}) do
      below = below + measure(c) + (i > 1 and GAP or 0)
    end
    width[id] = math.max(box, below)
    return width[id]
  end
  local boxes, x = {}, 0
  local function place(id, left, level)
    local box = vim.fn.strdisplaywidth(label(id)) + 4
    local kids = g.kids[id] or {}
    local below = -GAP
    for _, c in ipairs(kids) do
      below = below + width[c] + GAP
    end
    local cx = left + math.floor((width[id] - below) / 2)
    for _, c in ipairs(kids) do
      place(c, cx, level + 1)
      cx = cx + width[c] + GAP
    end
    local center = left + math.floor(width[id] / 2)
    if #kids > 0 then
      center = math.floor((boxes[kids[1]].center + boxes[kids[#kids]].center) / 2)
    end
    local at = math.max(left, math.min(center - math.floor(box / 2), left + width[id] - box))
    boxes[id] = { x = at, y = level * 4, w = box, center = at + math.floor(box / 2) }
  end
  for _, root in ipairs(g.roots) do
    measure(root)
    place(root, x, 0)
    x = x + width[root] + GAP
  end
  return boxes, math.max(0, x - GAP)
end

---Draws the map of `g` in a float. `opts.current` is the function shown;
---`<CR>` on a box calls `opts.pick` with its id.
---@param opts { current: string|nil, done: fun(id): boolean, pick: fun(id), title: string }
function M.open(g, opts)
  local function mark(id)
    if id == opts.current then
      return "▶ "
    elseif not g.step_of[id] then
      return ""
    end
    return opts.done(id) and "● " or "○ "
  end
  local function label(id)
    return mark(id) .. g.nodes[id].short
  end
  local boxes, width = layout(g, label)
  local near = { [opts.current or ""] = true }
  for _, p in ipairs(g.parents[opts.current] or {}) do
    near[p] = true
  end
  for _, c in ipairs(g.children[opts.current] or {}) do
    near[c] = true
  end
  local function group(id)
    if id == opts.current then
      return "TrailCurrentStep"
    end
    return near[id] and "Normal" or "Comment"
  end

  local height = 0
  for _, b in pairs(boxes) do
    height = math.max(height, b.y + 3)
  end
  local grid = {}
  for r = 1, height do
    grid[r] = {}
    for c = 1, width do
      grid[r][c] = { " " }
    end
  end
  local function put(r, c, text, hl)
    local i = 0
    for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
      if grid[r + 1] and grid[r + 1][c + i + 1] then
        grid[r + 1][c + i + 1] = { ch, hl }
      end
      i = i + 1
    end
  end
  for id, b in pairs(boxes) do
    local hl = group(id)
    put(b.y, b.x, "┌" .. string.rep("─", b.w - 2) .. "┐", hl)
    put(b.y + 1, b.x, "│ " .. label(id) .. " │", hl)
    put(b.y + 2, b.x, "└" .. string.rep("─", b.w - 2) .. "┘", hl)
    local kids = g.kids[id] or {}
    if #kids > 0 then
      put(b.y + 2, b.center, "┬", hl)
      local lo, hi = b.center, b.center
      for _, c in ipairs(kids) do
        lo, hi = math.min(lo, boxes[c].center), math.max(hi, boxes[c].center)
      end
      for c = lo, hi do
        put(b.y + 3, c, "─", "Comment")
      end
      local function corner(at, left, right, middle)
        return at == lo and at ~= hi and left or (at == hi and at ~= lo and right or middle)
      end
      for _, c in ipairs(kids) do
        local edge = (id == opts.current or c == opts.current) and "Normal" or "Comment"
        put(b.y + 3, boxes[c].center, corner(boxes[c].center, "╭", "╮", "┬"), edge)
      end
      put(b.y + 3, b.center, lo == hi and "│" or corner(b.center, "╰", "╯", "┴"), "Comment")
    end
  end

  local lines, marks = {}, {}
  for r, cells in ipairs(grid) do
    local line = ""
    for _, cell in ipairs(cells) do
      if cell[2] then
        table.insert(marks, { r - 1, #line, #line + #cell[1], cell[2] })
      end
      line = line .. cell[1]
    end
    lines[r] = (line:gsub("%s+$", ""))
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  for _, m in ipairs(marks) do
    if m[2] < #lines[m[1] + 1] then
      vim.api.nvim_buf_set_extmark(buf, ns, m[1], m[2], { end_col = math.min(m[3], #lines[m[1] + 1]), hl_group = m[4] })
    end
  end
  local footer = " hjkl move  ⏎ open  q close "
  local cols = math.min(math.max(width + 2, vim.fn.strdisplaywidth(footer) + 2), vim.o.columns - 4)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = cols,
    height = math.max(3, math.min(height, vim.o.lines - 4)),
    row = 1,
    col = math.max(0, math.floor((vim.o.columns - cols) / 2) - 1),
    border = "rounded",
    title = " " .. opts.title .. " ",
    footer = footer,
    footer_pos = "right",
  })
  vim.wo[win].wrap, vim.wo[win].cursorline = false, false
  local here = opts.current and boxes[opts.current]
  if here then
    vim.api.nvim_win_set_cursor(win, { here.y + 2, vim.fn.byteidx(lines[here.y + 2], here.x + 2) })
  end

  local function close()
    pcall(vim.api.nvim_win_close, win, true)
  end
  local function key(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true })
  end
  key("q", close)
  key("<Esc>", close)
  key("<CR>", function()
    local row = vim.api.nvim_win_get_cursor(win)[1] - 1
    local col = vim.fn.virtcol(".") - 1
    for id, b in pairs(boxes) do
      if row >= b.y and row <= b.y + 2 and col >= b.x and col < b.x + b.w then
        close()
        return opts.pick(id)
      end
    end
  end)
  return win, buf
end

return M
