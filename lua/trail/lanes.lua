---A path's changes drawn as lanes: one row per change, in the order `]s`
---walks them, with the calls between them drawn in a gutter on the left and
---the unchanged functions between them left out. A change reached again
---shows again under each caller, with the changes below it.
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

local FOLD = 5

---The rows to draw, depth first: each with its id, depth, and the guide
---characters before its mark. A change reached again shows again under each
---caller as `again`, with the changes below it, which fold into one row
---(`fold`, `count`) when there are more than `FOLD`, unless `expanded[fold]`.
---Entry points that only reach changes placed elsewhere come last.
---@param expanded table<string, boolean>|nil
function M.rows(g, expanded)
  expanded = expanded or {}
  local rows = {}
  local function prefix_of(depth, guides, last)
    local prefix = ""
    for _, open in ipairs(guides) do
      prefix = prefix .. (open and "│ " or "  ")
    end
    if depth > 0 then
      prefix = prefix .. (last and "╰─" or "├─")
    end
    return prefix
  end
  local function home(id, c)
    return vim.list_contains(g.kids[id] or {}, c)
  end
  local function count(id, on_branch, limit)
    local n = 0
    for _, c in ipairs(g.children[id] or {}) do
      if not on_branch[c] then
        on_branch[c] = true
        n = n + 1 + count(c, on_branch, limit - n - 1)
        on_branch[c] = nil
        if n > limit then
          return n
        end
      end
    end
    return n
  end
  local function walk(id, depth, guides, last, again, top, on_branch, at)
    table.insert(rows, { id = id, depth = depth, prefix = prefix_of(depth, guides, last), again = again })
    on_branch[id] = true
    local below = depth > 0 and vim.list_extend(vim.list_extend({}, guides), { not last }) or {}
    local list = vim.tbl_filter(function(c)
      return not on_branch[c]
    end, g.children[id] or {})
    if top and #list > 0 and not expanded[at] and count(id, vim.deepcopy(on_branch), FOLD) > FOLD then
      local n = count(id, vim.deepcopy(on_branch), math.huge)
      table.insert(rows, { fold = at, count = n, depth = depth + 1, prefix = prefix_of(depth + 1, below, true) })
    else
      for i, c in ipairs(list) do
        local here = home(id, c)
        walk(c, depth + 1, below, i == #list, again or not here, not again and not here, on_branch, at .. ">" .. c)
      end
    end
    on_branch[id] = nil
  end
  for i, root in ipairs(g.roots) do
    walk(root, 0, {}, i == #g.roots, false, false, {}, root)
  end
  for _, entry in ipairs(g.entries) do
    if not vim.list_contains(g.roots, entry) then
      walk(entry, 0, {}, true, false, false, {}, entry)
    end
  end
  return rows
end

local function plural(n, word)
  return n .. " " .. word .. (n == 1 and "" or "s")
end

---Draws `rows`: the gutter, the change's mark (`▶` shown now, `●` reviewed,
---`○` not yet, `◇` an unchanged entry point), its name, and its threads in a
---column on the right.
---@param opts { indent: string|nil, current: string|nil, done: fun(id): boolean, threads: fun(id): integer }
---@return string[] lines, table[] highlights { row, from, to, group }
function M.render(g, rows, opts)
  local indent = opts.indent or " "
  local gutter, width = 0, 0
  for _, r in ipairs(rows) do
    if r.id then
      gutter = math.max(gutter, vim.fn.strdisplaywidth(r.prefix))
      width = math.max(width, vim.fn.strdisplaywidth(g.nodes[r.id].short))
    end
  end
  local lines, hls = {}, {}
  for i, r in ipairs(rows) do
    local id, row = r.id, i - 1
    local head = indent .. r.prefix
    if r.fold then
      local line = head .. "▸ " .. plural(r.count, "change")
      table.insert(hls, { row, #indent, #line, "Comment" })
      table.insert(lines, line)
    else
      local shown = id == opts.current and not r.again
      local mark, mark_hl = "◇", "Comment"
      if shown then
        mark, mark_hl = "▶", "TrailCurrentStep"
      elseif g.step_of[id] then
        if opts.done(id) then
          mark, mark_hl = "●", "TrailAddText"
        else
          mark, mark_hl = "○", "Comment"
        end
      end
      local line = head .. mark
      table.insert(hls, { row, #indent, #head, "Comment" })
      table.insert(hls, { row, #head, #line, mark_hl })
      line = line .. string.rep(" ", gutter - vim.fn.strdisplaywidth(r.prefix) + 2)
      local name_at = #line
      local name = g.nodes[id].short
      line = line .. name
      if shown then
        table.insert(hls, { row, name_at, #line, "TrailCurrentStep" })
      elseif not g.step_of[id] then
        table.insert(hls, { row, name_at, #line, "Comment" })
      end
      local n = opts.threads(id)
      if n > 0 then
        line = line .. string.rep(" ", width - vim.fn.strdisplaywidth(name) + 3)
        local count = plural(n, "thread")
        table.insert(hls, { row, #line, #line + #count, "TrailThreadAuthor" })
        line = line .. count
      end
      table.insert(lines, line)
    end
  end
  return lines, hls
end

return M
