local M = {}

local signs = { added = "+", modified = "~", removed = "-", context = "·" }
local sign_hl = { added = "TrailAdd", modified = "TrailModified", removed = "TrailDelete", context = "Comment" }
local edge_note = { added = "new call", removed = "call removed" }

vim.api.nvim_set_hl(0, "TrailModified", { link = "Function", default = true })
vim.api.nvim_set_hl(0, "TrailCurrentStep", { link = "Visual", default = true })

local function short(id)
  return (id:gsub("^%w+:", ""))
end

---Draws a path as a tree that follows its calls.
---@param path { steps: table[], entries: string[]|nil }
---@param review table the engine's open result
---@param opts { current: integer|nil, done: table<integer, boolean>|nil }
---@return string[] lines, table[] highlights, table<integer, integer> step_of_row
function M.render(path, review, opts)
  opts = opts or {}
  local step_of, labels = {}, {}
  for i, step in ipairs(path.steps) do
    if step.node then
      step_of[step.node.id] = i
    end
  end
  local callees = {}
  for _, e in ipairs(review.edges) do
    if step_of[e.from] and step_of[e.to] and e.from ~= e.to then
      callees[e.from] = callees[e.from] or {}
      table.insert(callees[e.from], e)
    end
  end

  local rows = {}
  local expanded = {}
  local function label(step)
    if step.hunk then
      local h = step.hunk
      local side = h.new.len > 0 and h.new or h.old
      return { text = string.format("%s:%d-%d", h.file, side.start, side.start + math.max(side.len, 1) - 1) }
    end
    local n = step.node
    local range = n.new or n.old
    return { sign = signs[n.status], hl = sign_hl[n.status], text = short(n.id), loc = string.format("%s:%d", n.file, range.start) }
  end
  local function walk(i, prefix, connector, edge)
    local step = path.steps[i]
    local id = step.node and step.node.id
    local repeated = id and expanded[id]
    table.insert(rows, { step = i, prefix = prefix .. connector, label = label(step), edge = edge, repeated = repeated and callees[id] ~= nil })
    if repeated or not id then
      return
    end
    expanded[id] = true
    local children = callees[id] or {}
    local child_prefix = prefix .. (connector == "├─ " and "│  " or (connector == "└─ " and "   " or ""))
    for k, e in ipairs(children) do
      walk(step_of[e.to], child_prefix, k == #children and "└─ " or "├─ ", e)
    end
  end
  for _, entry in ipairs(path.entries or {}) do
    if step_of[entry] and not expanded[entry] then
      walk(step_of[entry], "", "", nil)
    end
  end
  for i, step in ipairs(path.steps) do
    if not (step.node and expanded[step.node.id]) then
      walk(i, "", "", nil)
    end
  end

  local width = 0
  for _, r in ipairs(rows) do
    labels[r] = r.prefix .. (r.label.sign and (r.label.sign .. " ") or "") .. r.label.text
    width = math.max(width, vim.fn.strdisplaywidth(labels[r]))
  end
  local lines, hls, step_of_row = {}, {}, {}
  for _, r in ipairs(rows) do
    local marker = r.step == opts.current and "▶ " or (opts.done and opts.done[r.step] and "✓ " or "  ")
    local text = labels[r]
    local line = marker .. text .. string.rep(" ", width - vim.fn.strdisplaywidth(text))
    local row = #lines
    if r.label.loc then
      line = line .. "  " .. r.label.loc
    end
    if r.edge and r.edge.kind == "use" then
      line = line .. "  (uses)"
    elseif r.edge and edge_note[r.edge.status] then
      line = line .. "  (" .. edge_note[r.edge.status] .. ")"
    end
    if r.edge and r.edge.source == "name_match" and r.edge.status ~= "removed" then
      line = line .. "  ?"
    end
    if r.repeated then
      line = line .. "  ↑ see above"
    end
    table.insert(lines, line)
    step_of_row[row + 1] = r.step
    local sign_col = #marker + #r.prefix
    if r.label.sign then
      table.insert(hls, { row, sign_col, sign_col + 1, r.label.hl })
    end
    local loc_col = #marker + #text + (width - vim.fn.strdisplaywidth(text)) + 2
    if r.label.loc then
      table.insert(hls, { row, loc_col, #line, "Comment" })
    end
    if r.step == opts.current then
      table.insert(hls, { row, 0, #line, "TrailCurrentStep" })
    elseif opts.done and opts.done[r.step] then
      table.insert(hls, { row, 0, #marker, "TrailAdd" })
    end
  end
  return lines, hls, step_of_row
end

return M
