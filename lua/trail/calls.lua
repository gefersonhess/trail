---Calls between a path's functions: where each is made, shown in the diff on
---the calling line and on the called function's first line, and followed
---with ]] into the function called and [[ back.
local pathview = require("trail.pathview")

local M = {}

vim.api.nvim_set_hl(0, "TrailCall", { underline = true, bold = true, default = true })

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

local function name_of(node)
  return node.short:match("([%w_]+)$") or node.short
end

---Notes for the diff of `file`: each call made in it, and each function in it
---with where it is called from.
function M.notes(path, file, view)
  local nodes, step_of, calls = graph(path)
  if not nodes then
    return {}
  end
  local notes, callers = {}, {}
  local lines = view.lines("new")
  for _, c in ipairs(calls) do
    if c.from.file == file then
      local hint = { { "→ ", "WarningMsg" }, { c.to.short, "TrailCall" } }
      if step_of[c.to.id] then
        table.insert(hint, { " · step " .. step_of[c.to.id], "TrailThread" })
      end
      local text, name = lines[c.line] or "", name_of(c.to)
      local at = text:find(name .. "%s*[%(%[]") or text:find(name, 1, true)
      local spans = at and { { at - 1, at - 1 + #name, "TrailCall" } } or nil
      table.insert(notes, { side = "new", line = c.line, hint = hint, spans = spans })
    end
    if c.to.file == file then
      callers[c.to.id] = callers[c.to.id] or {}
      table.insert(callers[c.to.id], c)
    end
  end
  for id, list in pairs(callers) do
    local where = vim.tbl_map(function(c)
      return c.from.short .. " line " .. c.line
    end, list)
    table.insert(notes, {
      side = "new",
      line = nodes[id].line,
      hint = { { "← called by ", "TrailThread" }, { table.concat(where, ", "), "TrailThread" } },
    })
  end
  return notes
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

---]]: follows the call on the cursor's line into the function it calls, a
---step of the path or a function on the way; on a line without one, moves
---to the next call below.
function M.follow(view, file)
  local path, step = pathview.current()
  local nodes, step_of, calls = graph(path)
  local here = view and view.line_at_cursor()
  if not (nodes and here) then
    return
  end
  local on_line, below = {}, nil
  for _, c in ipairs(calls) do
    if c.from.file == file and here.side == "new" then
      if c.line == here.line then
        table.insert(on_line, { node = c.to, label = c.to.short })
      elseif c.line > here.line and (not below or c.line < below) then
        below = c.line
      end
    end
  end
  if #on_line == 0 then
    if below then
      view.focus("new", below)
    else
      vim.notify("trail: no call into the path below", vim.log.levels.INFO)
    end
    return
  end
  pick(on_line, "Follow the call into", function(c)
    table.insert(history, { step = step, file = file, line = here.line })
    if step_of[c.node.id] then
      pathview.go(step_of[c.node.id])
    else
      pathview.go(step, c.node.file, c.node.line)
    end
  end)
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
