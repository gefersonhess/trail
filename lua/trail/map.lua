---The review drawn as a map in a floating window: packages as boxes, callers
---above what they call, and every path as a numbered route through the
---packages it reaches. Only the selected path is in colour, and `▶` marks
---the function shown.
local M = {}

local ns = vim.api.nvim_create_namespace("trail.map")

vim.api.nvim_set_hl(0, "TrailMapRoute", { link = "DiagnosticWarn", default = true })

local graphs = setmetatable({}, { __mode = "k" })

local function package_of(n)
  return (n.package or "") ~= "" and n.package or vim.fs.dirname(n.file)
end

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
  local children, linked = {}, {}
  local function link(from, to)
    local key = from .. "\0" .. to
    if from == to or linked[key] then
      return
    end
    linked[key] = true
    children[from] = children[from] or {}
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
  local g = { nodes = nodes, step_of = step_of, children = children, entries = entries }
  graphs[impact] = g
  return g
end

---The number of path `i` as drawn on the map: ① to ⑳, then (21).
function M.number(i)
  if i <= 20 then
    return vim.fn.nr2char(0x245F + i)
  end
  return "(" .. i .. ")"
end

---The packages the paths reach, which calls which, and the paths through
---each package and each call. Only functions on the way to a change count:
---a path's entry points, its changes, and the unchanged functions between
---them. A package is named by its last folder, or its last two where that is
---shared.
local function packages(paths)
  local order, by_name, edges = {}, {}, {}
  local function package(name)
    if not by_name[name] then
      by_name[name] = { name = name, paths = {}, kids = {}, parents = 0 }
      table.insert(order, name)
    end
    return by_name[name]
  end
  for i, path in ipairs(paths) do
    local impact = path.impact
    local nodes, steps = M.graph(impact).nodes, M.graph(impact).step_of
    for _, tree in ipairs(impact.trees) do
      local rows = tree.rows
      -- Walking back, `below[d]` says a row at depth d since the last
      -- shallower one leads to a change: those are the next row's children.
      local leads, below = {}, {}
      for k = #rows, 1, -1 do
        local d = rows[k].depth
        leads[k] = steps[rows[k].id] ~= nil or below[d + 1] == true
        for deeper in pairs(below) do
          if deeper > d then
            below[deeper] = nil
          end
        end
        below[d] = below[d] or leads[k]
      end
      local above = {}
      for k, r in ipairs(rows) do
        for d = #above, r.depth + 1, -1 do
          above[d] = nil
        end
        if leads[k] and not nodes[r.id].is_test then
          local here = package(package_of(nodes[r.id]))
          here.paths[i] = true
          local parent = above[r.depth]
          if parent and parent ~= here then
            local key = parent.name .. "\0" .. here.name
            if not edges[key] then
              edges[key] = {}
              table.insert(parent.kids, here.name)
              here.parents = here.parents + 1
            end
            edges[key][i] = true
          end
          above[r.depth + 1] = here
        end
      end
    end
  end
  local last = {}
  for _, name in ipairs(order) do
    local tail = name:match("[^/]+$") or name
    last[tail] = (last[tail] or 0) + 1
  end
  for _, name in ipairs(order) do
    local tail = name:match("[^/]+$") or name
    by_name[name].short = last[tail] > 1 and (name:match("[^/]+/[^/]+$") or name) or tail
  end
  return order, by_name, edges
end

---Each package once, under the first package calling it, depth first from
---the packages nothing calls.
local function spanning(order, by_name)
  local visited, kids, roots = {}, {}, {}
  local function visit(name)
    kids[name] = {}
    for _, c in ipairs(by_name[name].kids) do
      if not visited[c] then
        visited[c] = true
        table.insert(kids[name], c)
        visit(c)
      end
    end
  end
  for pass = 1, 2 do
    for _, name in ipairs(order) do
      if not visited[name] and (pass == 2 or by_name[name].parents == 0) then
        visited[name] = true
        table.insert(roots, name)
        visit(name)
      end
    end
  end
  return roots, kids
end

local GAP = 3

---Lays the spanning tree out as boxes: each subtree as wide as its widest
---level, its children side by side under it and centred below it, each
---level a row below the tallest box above it. `label(id)` is a box's lines.
local function layout(roots, kids, label)
  local function box_width(id)
    local w = 0
    for _, l in ipairs(label(id)) do
      w = math.max(w, vim.fn.strdisplaywidth(l))
    end
    return w + 4
  end
  local width = {}
  local function measure(id)
    local box = box_width(id)
    local below = 0
    for i, c in ipairs(kids[id]) do
      below = below + measure(c) + (i > 1 and GAP or 0)
    end
    width[id] = math.max(box, below)
    return width[id]
  end
  local boxes, x = {}, 0
  local tallest = {}
  local function place(id, left, level)
    local box = box_width(id)
    local below = -GAP
    for _, c in ipairs(kids[id]) do
      below = below + width[c] + GAP
    end
    local cx = left + math.floor((width[id] - below) / 2)
    for _, c in ipairs(kids[id]) do
      place(c, cx, level + 1)
      cx = cx + width[c] + GAP
    end
    local center = left + math.floor(width[id] / 2)
    if #kids[id] > 0 then
      center = math.floor((boxes[kids[id][1]].center + boxes[kids[id][#kids[id]]].center) / 2)
    end
    local at = math.max(left, math.min(center - math.floor(box / 2), left + width[id] - box))
    local h = #label(id) + 2
    tallest[level] = math.max(tallest[level] or 0, h)
    boxes[id] = { x = at, level = level, w = box, h = h, center = at + math.floor(box / 2) }
  end
  for _, root in ipairs(roots) do
    measure(root)
    place(root, x, 0)
    x = x + width[root] + GAP
  end
  local top = { [0] = 0 }
  for level = 1, #tallest do
    top[level] = top[level - 1] + tallest[level - 1] + 1
  end
  for _, b in pairs(boxes) do
    b.y = top[b.level]
    b.bus = b.y + tallest[b.level]
  end
  return boxes, math.max(0, x - GAP)
end

---Draws the map of `paths` (impact paths with `title` and `steps`) in a
---float. `opts.selected` is the path in colour, `n`/`p` change it;
---`opts.current` the function shown in it. `<CR>` on a box calls
---`opts.pick(i, package)` for the selected path, on a path's line
---`opts.pick(i)`.
---@param opts { selected: integer, current: string|nil, done: fun(i: integer): integer, pick: fun(i: integer, package: string|nil) }
function M.open(paths, opts)
  local order, by_name, edges = packages(paths)
  local roots, kids = spanning(order, by_name)
  local selected = opts.selected
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local boxes, legend_row

  local function here()
    local id = selected == opts.selected and opts.current
    local node = id and M.graph(paths[selected].impact).nodes[id]
    return node and package_of(node)
  end

  local function marks(out, through, current)
    for i = 1, #paths do
      if through[i] then
        table.insert(out, { " " })
        table.insert(out, { (i == selected and current and "▶" or "") .. M.number(i), i == selected and "TrailMapRoute" or nil })
      end
    end
    return out
  end
  ---A box's lines as segments of text and highlight: the package and the
  ---paths through it, then each call to a package drawn under another, with
  ---the paths making it.
  local function segments(name)
    local out = { marks({ { by_name[name].short } }, by_name[name].paths, here() == name) }
    for _, c in ipairs(by_name[name].kids) do
      if not vim.list_contains(kids[name], c) then
        table.insert(out, marks({ { "→ " .. by_name[c].short } }, edges[name .. "\0" .. c], false))
      end
    end
    return out
  end
  local function label(name)
    return vim.tbl_map(function(line)
      return table.concat(vim.tbl_map(function(s)
        return s[1]
      end, line))
    end, segments(name))
  end

  local function render()
    local width
    boxes, width = layout(roots, kids, label)
    local height = 0
    for _, b in pairs(boxes) do
      height = math.max(height, b.y + b.h)
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
        i = i + vim.fn.strdisplaywidth(ch)
      end
    end
    for name, b in pairs(boxes) do
      put(b.y, b.x, "┌" .. string.rep("─", b.w - 2) .. "┐")
      for l, line in ipairs(segments(name)) do
        put(b.y + l, b.x, "│" .. string.rep(" ", b.w - 2) .. "│")
        local col = b.x + 2
        for _, s in ipairs(line) do
          put(b.y + l, col, s[1], s[2])
          col = col + vim.fn.strdisplaywidth(s[1])
        end
      end
      local bottom = b.y + b.h - 1
      put(bottom, b.x, "└" .. string.rep("─", b.w - 2) .. "┘")
      if #kids[name] > 0 then
        local function route(c)
          return edges[name .. "\0" .. c][selected] and "TrailMapRoute" or nil
        end
        local on = vim.iter(kids[name]):any(function(c)
          return route(c) ~= nil
        end) and "TrailMapRoute" or nil
        put(bottom, b.center, "┬", on)
        for r = bottom + 1, b.bus - 1 do
          put(r, b.center, "│", on)
        end
        local lo, hi = b.center, b.center
        for _, c in ipairs(kids[name]) do
          lo, hi = math.min(lo, boxes[c].center), math.max(hi, boxes[c].center)
        end
        for c = lo, hi do
          put(b.bus, c, "─")
        end
        local function corner(at, left, right, middle)
          return at == lo and at ~= hi and left or (at == hi and at ~= lo and right or middle)
        end
        for _, c in ipairs(kids[name]) do
          local at = boxes[c].center
          put(b.bus, at, corner(at, "╭", "╮", "┬"), route(c))
          local from, to = math.min(at, b.center), math.max(at, b.center)
          if route(c) then
            for x = from + 1, to - 1 do
              put(b.bus, x, "─", "TrailMapRoute")
            end
          end
        end
        put(b.bus, b.center, lo == hi and "│" or corner(b.center, "╰", "╯", "┴"), on)
      end
    end

    local lines, marks = {}, {}
    for r, cells in ipairs(grid) do
      local line = ""
      for _, cell in ipairs(cells) do
        if cell[2] then
          table.insert(marks, { r - 1, #line, #line + #cell[1], cell[2] })
        end
        if cell[1] ~= "" then
          line = line .. cell[1]
        end
      end
      lines[r] = (line:gsub("%s+$", ""))
    end
    table.insert(lines, "")
    legend_row = #lines
    for i, path in ipairs(paths) do
      local line = (i == selected and "▶ " or "  ") .. M.number(i) .. " " .. path.title
        .. "  " .. opts.done(i) .. "/" .. #path.steps
      table.insert(lines, line)
      if i == selected then
        table.insert(marks, { #lines - 1, 0, #line, "TrailMapRoute" })
      end
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for _, m in ipairs(marks) do
      vim.api.nvim_buf_set_extmark(buf, ns, m[1], m[2], { end_col = math.min(m[3], #lines[m[1] + 1]), hl_group = m[4] })
    end
    return lines
  end

  local lines = render()
  local footer = " n p path  ⏎ open  q close "
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  local cols = math.min(math.max(width + 2, vim.fn.strdisplaywidth(footer) + 2), vim.o.columns - 4)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = cols,
    height = math.max(3, math.min(#lines, vim.o.lines - 4)),
    row = 1,
    col = math.max(0, math.floor((vim.o.columns - cols) / 2) - 1),
    border = "rounded",
    title = " Map ",
    footer = footer,
    footer_pos = "right",
  })
  vim.wo[win].wrap, vim.wo[win].cursorline = false, false
  local at = boxes[here() or ""]
  if at then
    vim.api.nvim_win_set_cursor(win, { at.y + 2, vim.fn.byteidx(lines[at.y + 2], at.x + 2) })
  end

  local function close()
    pcall(vim.api.nvim_win_close, win, true)
  end
  local function key(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true })
  end
  local function cycle(delta)
    selected = (selected - 1 + delta) % #paths + 1
    local cursor = vim.api.nvim_win_get_cursor(win)
    render()
    pcall(vim.api.nvim_win_set_cursor, win, cursor)
  end
  key("q", close)
  key("<Esc>", close)
  key("n", function()
    cycle(1)
  end)
  key("p", function()
    cycle(-1)
  end)
  key("<CR>", function()
    local row = vim.api.nvim_win_get_cursor(win)[1] - 1
    if row >= legend_row then
      close()
      return opts.pick(row - legend_row + 1)
    end
    local col = vim.fn.virtcol(".") - 1
    for name, b in pairs(boxes) do
      if row >= b.y and row < b.y + b.h and col >= b.x and col < b.x + b.w then
        close()
        return opts.pick(selected, by_name[name].paths[selected] and name or nil)
      end
    end
  end)
  return win, buf
end

---The first step of `path` in `package`, or nil.
function M.step_in(path, package)
  local g = M.graph(path.impact)
  for s, step in ipairs(path.steps) do
    local n = g.nodes[step.node.id]
    if n and package_of(n) == package then
      return s
    end
  end
end

return M
