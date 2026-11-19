---A path's changes drawn as lanes: one row per change, in the order `]s`
---walks them, with the calls between them drawn in a gutter on the left and
---the unchanged functions between them left out. Another caller of a change
---already drawn shows on its row as `⇠ Caller`.
local M = {}

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
  g.roots, g.kids, g.joins = M.spanning(g)
  graphs[impact] = g
  return g
end

---Each change once, under the first caller to reach it depth first: the
---roots, each station's children, and for every change the other callers
---reaching it. An entry point reaching only changes already placed is not a
---root; it shows among those changes' other callers.
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
  local placed_under = {}
  for parent, list in pairs(kids) do
    for _, c in ipairs(list) do
      placed_under[c] = parent
    end
  end
  local joins = {}
  for to, from in pairs(g.parents) do
    for _, p in ipairs(from) do
      if placed_under[to] ~= p then
        joins[to] = joins[to] or {}
        table.insert(joins[to], p)
      end
    end
  end
  return roots, kids, joins
end

---The rows to draw, depth first: each with its id, depth, and the guide
---characters before its mark.
function M.rows(g)
  local rows = {}
  local function walk(id, depth, guides, last)
    local prefix = ""
    for _, open in ipairs(guides) do
      prefix = prefix .. (open and "│ " or "  ")
    end
    if depth > 0 then
      prefix = prefix .. (last and "╰─" or "├─")
    end
    table.insert(rows, { id = id, depth = depth, prefix = prefix })
    local list = g.kids[id] or {}
    local below = depth > 0 and vim.list_extend(vim.list_extend({}, guides), { not last }) or {}
    for i, c in ipairs(list) do
      walk(c, depth + 1, below, i == #list)
    end
  end
  for i, root in ipairs(g.roots) do
    walk(root, 0, {}, i == #g.roots)
  end
  return rows
end

local function plural(n, word)
  return n .. " " .. word .. (n == 1 and "" or "s")
end

---Draws `rows`: the gutter, the change's mark (`▶` shown now, `●` reviewed,
---`○` not yet, `◇` an unchanged entry point), its name with its other
---callers, and its threads in a column on the right.
---@param opts { indent: string|nil, current: string|nil, done: fun(id): boolean, threads: fun(id): integer }
---@return string[] lines, table[] highlights { row, from, to, group }
function M.render(g, rows, opts)
  local indent = opts.indent or " "
  local gutter, names = 0, {}
  for i, r in ipairs(rows) do
    gutter = math.max(gutter, vim.fn.strdisplaywidth(r.prefix))
    local others = vim.tbl_map(function(p)
      return g.nodes[p].short
    end, g.joins[r.id] or {})
    names[i] = { name = g.nodes[r.id].short, joins = #others > 0 and ("  ⇠ " .. table.concat(others, ", ")) or "" }
  end
  local width = 0
  for _, n in ipairs(names) do
    width = math.max(width, vim.fn.strdisplaywidth(n.name .. n.joins))
  end
  local lines, hls = {}, {}
  for i, r in ipairs(rows) do
    local id, row = r.id, i - 1
    local mark, mark_hl = "◇", "Comment"
    if id == opts.current then
      mark, mark_hl = "▶", "TrailCurrentStep"
    elseif g.step_of[id] then
      if opts.done(id) then
        mark, mark_hl = "●", "TrailAddText"
      else
        mark, mark_hl = "○", "Comment"
      end
    end
    local head = indent .. r.prefix
    local line = head .. mark
    table.insert(hls, { row, #indent, #head, "Comment" })
    table.insert(hls, { row, #head, #line, mark_hl })
    line = line .. string.rep(" ", gutter - vim.fn.strdisplaywidth(r.prefix) + 2)
    local name_at = #line
    line = line .. names[i].name
    if id == opts.current then
      table.insert(hls, { row, name_at, #line, "TrailCurrentStep" })
    elseif not g.step_of[id] then
      table.insert(hls, { row, name_at, #line, "Comment" })
    end
    if names[i].joins ~= "" then
      table.insert(hls, { row, #line, #line + #names[i].joins, "Comment" })
      line = line .. names[i].joins
    end
    local n = opts.threads(id)
    if n > 0 then
      line = line .. string.rep(" ", width - vim.fn.strdisplaywidth(names[i].name .. names[i].joins) + 3)
      local count = plural(n, "thread")
      table.insert(hls, { row, #line, #line + #count, "TrailThreadAuthor" })
      line = line .. count
    end
    table.insert(lines, line)
  end
  return lines, hls
end

return M
