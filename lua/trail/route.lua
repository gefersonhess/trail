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

---The route through `id`: up through the callers `prefer.up` names (the
---first otherwise) to an entry point, and down through the callees
---`prefer.down` names to the last change. Returns the ids and where `id` is.
function M.through(g, id, prefer)
  prefer = prefer or {}
  local up, seen = {}, { [id] = true }
  local at = id
  while g.parents[at] do
    local p = prefer.up and prefer.up[at]
    p = (p and vim.tbl_contains(g.parents[at], p)) and p or g.parents[at][1]
    if seen[p] then
      break
    end
    seen[p] = true
    table.insert(up, 1, p)
    at = p
  end
  local route = vim.list_extend(up, { id })
  local index = #route
  at = id
  while g.children[at] do
    local c = prefer.down and prefer.down[at]
    c = (c and vim.tbl_contains(g.children[at], c)) and c or g.children[at][1]
    if seen[c] then
      break
    end
    seen[c] = true
    table.insert(route, c)
    at = c
  end
  return route, index
end

---The path's main route: from its first entry point down through the first
---change below each.
function M.main(g)
  local first = g.entries[1]
  if not first then
    return {}, 0
  end
  return M.through(g, first)
end

local prefers = {}

---The callers and callees picked along a path's routes, kept while the review
---is open, so the paths screen draws the route the path view shows.
function M.prefer(path_id)
  prefers[path_id] = prefers[path_id] or { up = {}, down = {} }
  return prefers[path_id]
end

local SEP = " ── "

---Draws `route` on one line. `opts.current` is the station shown now,
---`opts.done(id)` whether a step was reviewed, and `opts.width` the room
---there is: a route wider than that shows the stations around
---`opts.anchor` (the current one, or the first), counting the hidden ones at
---each end.
---@return string line, table[] highlights { from, to, group }, table<integer, integer> col of each shown station
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
    cols[i] = #line
    if id == opts.current then
      put(label.mark .. label.name, "TrailCurrentStep")
    elseif g.step_of[id] then
      put(label.mark, opts.done(id) and "TrailAddText" or "Comment")
      put(label.name)
    else
      put(label.name, "Comment")
    end
  end
  if last < #route then
    put(string.format("  %d ›", #route - last), "Comment")
  end
  return line, hls, cols
end

return M
