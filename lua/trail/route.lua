---A path's changes as routes: the entry points and the changed functions,
---each linked to the one it is reached from, with the unchanged functions
---between them left out. A route is one chain through them, from an entry
---point down to the last change below.
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
  graphs[impact] = g
  return g
end

---The path's routes, in the order `]s` walks its steps: one chain from an
---entry point down to each change with nothing changed below it. Another
---entry point that only reaches changes already on a route is not a route of
---its own; one with changes of its own ends at the first change it joins.
function M.routes(g)
  if g.routes then
    return g.routes
  end
  local routes, visited = {}, {}
  local function walk(id, chain)
    visited[id] = true
    chain = vim.list_extend(vim.list_extend({}, chain), { id })
    local before, join = #routes, nil
    for _, c in ipairs(g.children[id] or {}) do
      if not visited[c] then
        walk(c, chain)
      elseif not join then
        join = c
      end
    end
    local own = vim.iter(chain):any(function(c)
      return g.step_of[c] ~= nil
    end)
    if #routes == before and own then
      table.insert(routes, { ids = join and vim.list_extend(chain, { join }) or chain, joins = join ~= nil })
    end
  end
  for _, entry in ipairs(g.entries) do
    if not visited[entry] then
      walk(entry, {})
    end
  end
  g.routes = routes
  return routes
end

---Where `id` is on route `r`, or nil.
function M.index(route, id)
  for i, v in ipairs(route.ids) do
    if v == id then
      return i
    end
  end
end

---The route to show `id` on: `keep` when it holds `id`, otherwise the first
---that does, preferring one it doesn't merely join.
function M.find(g, id, keep)
  local routes = M.routes(g)
  if keep and routes[keep] and M.index(routes[keep], id) then
    return keep
  end
  local joined
  for r, route in ipairs(routes) do
    local i = M.index(route, id)
    if i and not (route.joins and i == #route.ids) then
      return r
    end
    joined = joined or (i and r)
  end
  return joined
end

local current = {}

---The route last shown for a path, kept while the review is open, so the
---paths screen draws the route the path view shows.
function M.current(path_id, r)
  if r then
    current[path_id] = r
  end
  return current[path_id]
end

local SEP = " ── "

---Draws `route` on one line. `opts.current` is the station shown now,
---`opts.done(id)` whether a step was reviewed, and `opts.width` the room
---there is: a route wider than that shows the stations around
---`opts.anchor` (the current one, or the first), counting the hidden ones at
---each end.
---@return string line, table[] highlights { from, to, group }, table<integer, integer[]> byte range of each shown station
function M.draw(g, route, opts)
  local labels = {}
  for i, id in ipairs(route) do
    local n = g.nodes[id]
    local mark
    if id == opts.current then
      mark = "▶ "
    elseif g.step_of[id] then
      mark = opts.done(id) and "● " or "○ "
    else
      mark = ""
    end
    labels[i] = { mark = mark, name = n.short }
  end
  local function width(i)
    return vim.fn.strdisplaywidth(labels[i].mark .. labels[i].name)
  end
  local first, last = 1, #route
  local anchor = opts.anchor or 1
  if opts.width and #route > 0 then
    local total = 0
    for i = 1, #route do
      total = total + width(i) + (i > 1 and #SEP or 0)
    end
    if total > opts.width then
      local room = opts.width - 12
      first, last = anchor, anchor
      local used = width(anchor)
      local grew = true
      while grew do
        grew = false
        if last < #route and used + #SEP + width(last + 1) <= room then
          last = last + 1
          used = used + #SEP + width(last)
          grew = true
        end
        if first > 1 and used + #SEP + width(first - 1) <= room then
          first = first - 1
          used = used + #SEP + width(first)
          grew = true
        end
      end
    end
  end

  local line, hls, cols = "", {}, {}
  local function put(text, group)
    if group then
      table.insert(hls, { #line, #line + #text, group })
    end
    line = line .. text
  end
  if first > 1 then
    put(string.format("‹ %d  ", first - 1), "Comment")
  end
  for i = first, last do
    if i > first then
      put(SEP, "Comment")
    end
    local id, label = route[i], labels[i]
    local from = #line
    if id == opts.current then
      put(label.mark .. label.name, "TrailCurrentStep")
    elseif g.step_of[id] then
      put(label.mark, opts.done(id) and "TrailAddText" or "Comment")
      put(label.name)
    else
      put(label.name, "Comment")
    end
    cols[i] = { from, #line }
  end
  if last < #route then
    put(string.format("  %d ›", #route - last), "Comment")
  end
  return line, hls, cols
end

return M
