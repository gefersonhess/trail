---Calls between a path's functions, followed with ]] into the function
---called and [[ back.
local pathview = require("trail.pathview")

local M = {}

---Where ]] came from, to go back to with [[.
local history = {}

---The path's functions by id, its steps by function id, and its calls: one
---per call line, test functions left out.
local function graph(path)
  local impact = path and path.impact
  if not impact then
    return nil
  end
  local nodes, step_of, calls = {}, {}, {}
  for _, n in ipairs(impact.nodes) do
    nodes[n.id] = n
  end
  for i, s in ipairs(path.steps) do
    if s.node then
      step_of[s.node.id] = i
    end
  end
  for _, e in ipairs(impact.edges) do
    local from, to = nodes[e.from], nodes[e.to]
    if from and to and not from.is_test then
      for _, line in ipairs(e.lines or {}) do
        table.insert(calls, { from = from, to = to, line = line })
      end
    end
  end
  return nodes, step_of, calls
end

local function pick(list, label, go)
  if #list == 1 then
    return go(list[1])
  end
  vim.ui.select(list, { prompt = label, format_item = function(c)
    return c.label
  end }, function(choice)
    if choice then
      go(choice)
    end
  end)
end

---The calls ]] can follow from `here` in `file`, one per function called,
---in the order they are made on the line, and the line of the next call
---below.
local function followable(view, calls, file, here)
  local on_line, seen, below = {}, {}, nil
  for _, c in ipairs(calls) do
    if c.from.file == file and here.side == "new" then
      if c.line == here.line and not seen[c.to.id] then
        seen[c.to.id] = true
        table.insert(on_line, { node = c.to, name = c.to.short:match("([%w_]+)$") })
      elseif c.line > here.line and (not below or c.line < below) then
        below = c.line
      end
    end
  end
  local text = view.lines("new")[here.line] or ""
  local function at(c)
    return text:find(c.name .. "%s*[%(%[]") or text:find(c.name, 1, true) or math.huge
  end
  table.sort(on_line, function(a, b)
    return at(a) < at(b)
  end)
  return on_line, below
end

---Where ]] goes from the cursor's line: a mark on that line for each call
---on it, `]]` for the first, `2]]` for the second and so on, naming the
---function called.
function M.jumps(view, file)
  local _, _, calls = graph(pathview.current())
  local here = view and view.line_at_cursor()
  if not (calls and here) then
    return {}
  end
  local out = {}
  for k, c in ipairs((followable(view, calls, file, here))) do
    table.insert(out, { key = (k > 1 and k or "") .. "]]", side = "new", line = here.line, call = c.name })
  end
  return out
end

---]]: follows the call on the cursor's line into the function it calls, a
---step of the path or a function on the way; with several, the first, or
---the count-th for a count. On a line without one, moves to the next call
---below.
function M.follow(view, file, count)
  local path, step = pathview.current()
  local nodes, step_of, calls = graph(path)
  local here = view and view.line_at_cursor()
  if not (nodes and here) then
    return
  end
  local on_line, below = followable(view, calls, file, here)
  if #on_line == 0 then
    if below then
      view.focus("new", below)
    else
      vim.notify("trail: no call into the path below", vim.log.levels.INFO)
    end
    return
  end
  local c = on_line[math.max(count or 1, 1)]
  if not c then
    vim.notify(("trail: this line makes %d calls into the path"):format(#on_line), vim.log.levels.INFO)
    return
  end
  table.insert(history, { step = step, file = file, line = here.line })
  if step_of[c.node.id] then
    pathview.go(step_of[c.node.id])
  else
    pathview.go(step, c.node.file, c.node.line)
  end
end

---[[: goes back to where ]] came from; with nowhere to go back to, up to the
---line calling the function the cursor is in.
function M.back(view, file)
  local entry = table.remove(history)
  if entry then
    return pathview.go(entry.step, entry.file, entry.line)
  end
  local path, step = pathview.current()
  local nodes, step_of, calls = graph(path)
  local here = view and view.line_at_cursor()
  if not (nodes and here) then
    return
  end
  local inside
  if here.side == "old" then
    -- A removed line has no place at head: its function is the step whose old lines hold it.
    for _, s in ipairs(path.steps) do
      local old = s.node and s.node.file == file and s.node.old
      if old and here.line >= old.start and here.line < old.start + old.len then
        inside = nodes[s.node.id]
      end
    end
  else
    for _, n in pairs(nodes) do
      if n.file == file and n.line <= here.line and (not inside or n.line > inside.line) then
        inside = n
      end
    end
  end
  local up = {}
  for _, c in ipairs(calls) do
    if inside and c.to.id == inside.id then
      table.insert(up, { node = c.from, line = c.line, label = c.from.short .. " line " .. c.line })
    end
  end
  if #up == 0 then
    vim.notify("trail: nothing in the path calls this", vim.log.levels.INFO)
    return
  end
  pick(up, "Go up to the call from", function(c)
    pathview.go(step_of[c.node.id] or step, c.node.file, c.line)
  end)
end

return M
