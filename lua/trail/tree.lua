local M = {}

vim.api.nvim_set_hl(0, "TrailModified", { link = "Function", default = true })
vim.api.nvim_set_hl(0, "TrailCurrentStep", { link = "Visual", default = true })
vim.api.nvim_set_hl(0, "TrailEntry", { link = "Special", default = true })

local function subtree_end(rows, i)
  local j = i + 1
  while j <= #rows and rows[j].depth > rows[i].depth do
    j = j + 1
  end
  return j
end

---The rows to draw for one tree: every row on the way to one of the path's
---steps, and a fold line for each run of rows that leads to none.
local function visible(rows, tree_index, is_step, expanded)
  local function has_step(from, to)
    for k = from, to - 1 do
      if is_step(rows[k]) then
        return true
      end
    end
    return false
  end
  local out = {}
  local function raw(from, to)
    for k = from, to - 1 do
      table.insert(out, { row = rows[k] })
    end
  end
  local i = 1
  while i <= #rows do
    local row, last = rows[i], subtree_end(rows, i)
    if has_step(i, last) then
      table.insert(out, { row = row })
      if last > i + 1 and not has_step(i + 1, last) then
        local key = tree_index .. ":" .. (i + 1)
        if expanded[key] then
          raw(i + 1, last)
        else
          table.insert(out, { fold = key, depth = row.depth + 1, count = last - i - 1 })
        end
        i = last
      else
        i = i + 1
      end
    else
      -- Sibling branches with no step fold into one line at their level.
      local j = last
      while j <= #rows and rows[j].depth == row.depth and not has_step(j, subtree_end(rows, j)) do
        j = subtree_end(rows, j)
      end
      local key = tree_index .. ":" .. i
      if expanded[key] then
        raw(i, j)
      else
        table.insert(out, { fold = key, depth = row.depth, count = j - i })
      end
      i = j
    end
  end
  return out
end

---The rows to draw for one tree in the changes view: its entry point and the
---path's changes, each under the change above it, with a link line standing
---for the unchanged functions the call goes through until opened.
local function changes_only(rows, tree_index, is_step, expanded)
  local out = {}
  -- The row on each depth above the current one, to find a row's ancestors.
  local above = {}
  -- Rows already drawn, with the depth they were drawn at.
  local drawn = {}
  -- Changes drawn in this tree, or joined to: a join is kept only once, and
  -- only for a change shown in an earlier tree.
  local here = {}
  for k, row in ipairs(rows) do
    for d = #above, row.depth + 1, -1 do
      above[d] = nil
    end
    above[row.depth + 1] = k
    local keep = k == 1 or is_step(row) or (row.join and is_step({ id = row.id }) and not here[row.id])
    if keep then
      here[row.id] = true
    end
    if keep and k > 1 then
      -- The nearest ancestor already drawn, and the unchanged rows between.
      local parent, chain = nil, {}
      for d = row.depth, 1, -1 do
        local a = above[d]
        if drawn[a] then
          parent = a
          break
        end
        table.insert(chain, 1, rows[a])
      end
      local depth = parent and drawn[parent] + 1 or 0
      local key = tree_index .. ":link:" .. k
      if #chain > 0 and not expanded[key] then
        table.insert(out, {
          fold = key,
          depth = depth,
          label = #chain .. " function" .. (#chain == 1 and "" or "s"),
        })
        depth = depth + 1
      elseif #chain > 0 then
        for _, link in ipairs(chain) do
          table.insert(out, { row = link, depth = depth })
          depth = depth + 1
        end
      end
      -- The call's interface belongs to the hop just above, hidden while the link is folded.
      local shown = row
      if #chain > 0 and not expanded[key] then
        shown = { id = row.id, depth = row.depth, join = row.join }
      end
      table.insert(out, { row = shown, depth = depth })
      drawn[k] = depth
    elseif keep then
      table.insert(out, { row = row, depth = 0 })
      drawn[k] = 0
    end
  end
  return out
end

local function plural(n, word)
  return n .. " " .. word .. (n == 1 and "" or "s")
end

---Draws an impact path from its entry points down. By default it shows only
---the changes and how they connect; `opts.all` shows every function on the
---way, stopping at the last change. What leads to no change is folded until
---`expanded` opens it.
---@param path table the engine's impact path
---@param opts { expanded: table<string, boolean>|nil, all: boolean|nil, current: integer|nil, done: table<integer, boolean>|nil }
---@return string[] lines, table[] highlights, table<integer, table> item_of_row
function M.render(path, opts)
  opts = opts or {}
  local expanded = opts.expanded or {}
  local nodes, step_of, tests = {}, {}, {}
  for _, n in ipairs(path.nodes) do
    nodes[n.id] = n
  end
  for i, id in ipairs(path.steps) do
    step_of[id] = i
  end
  for _, e in ipairs(path.edges) do
    if nodes[e.from].is_test then
      tests[e.to] = tests[e.to] or {}
      tests[e.to][e.from] = true
    end
  end
  local function is_step(row)
    return step_of[row.id] ~= nil and not row.join
  end

  local items = {}
  local quiet = {}
  for t, tree in ipairs(path.trees) do
    if tree.changes or expanded.entries then
      local shown
      if not tree.changes then
        shown = vim.tbl_map(function(row)
          return { row = row }
        end, tree.rows)
      elseif opts.all then
        shown = visible(tree.rows, t, is_step, expanded)
      else
        shown = changes_only(tree.rows, t, is_step, expanded)
      end
      if #items > 0 then
        table.insert(items, { blank = true })
      end
      vim.list_extend(items, shown)
    else
      table.insert(quiet, tree)
    end
  end
  if #quiet > 0 then
    table.insert(items, { blank = true })
    table.insert(items, {
      fold = "entries",
      depth = 0,
      text = "▸ " .. plural(#quiet, "more entry point") .. (#quiet == 1 and " reaches" or " reach") .. " this path without other changes",
    })
  end

  -- Whether each item is the last child of its parent, for the connectors.
  local function depth(item)
    return item.depth or item.row.depth
  end
  local last = {}
  for k, item in ipairs(items) do
    if not item.blank then
      local next_depth = -1
      for m = k + 1, #items do
        if items[m].blank then
          break
        end
        if depth(items[m]) <= depth(item) then
          next_depth = depth(items[m])
          break
        end
      end
      last[k] = next_depth < depth(item)
    end
  end

  local rendered, open_levels = {}, {}
  for k, item in ipairs(items) do
    if item.blank then
      open_levels = {}
      table.insert(rendered, { text = "" })
    else
      local d = depth(item)
      while #open_levels > d do
        table.remove(open_levels)
      end
      local prefix = ""
      for level = 2, #open_levels do
        prefix = prefix .. (open_levels[level] and "   " or "│  ")
      end
      if d > 0 then
        prefix = prefix .. (last[k] and "└─ " or "├─ ")
      end
      if item.fold then
        table.insert(rendered, {
          text = item.text or (prefix .. "▸ " .. (item.label or (item.count .. " more"))),
          fold = item.fold,
        })
      else
        local row = item.row
        local n = nodes[row.id]
        local step = is_step(row) and step_of[row.id] or nil
        local mark, mark_hl = "○", "Comment"
        if n.status == "added" then
          mark, mark_hl = "✚", "TrailAdd"
        elseif n.status == "modified" then
          mark, mark_hl = "●", "TrailModified"
        elseif n.entry then
          mark, mark_hl = "◆", "TrailEntry"
        end
        local tags = {}
        if step then
          table.insert(tags, "step " .. step)
        elseif n.status ~= "unchanged" then
          table.insert(tags, n.status)
        end
        if n.entry and d == 0 then
          table.insert(tags, "entry")
        end
        if row.via then
          local parts = vim.split(row.via, ".", { plain = true })
          table.insert(tags, "via " .. (parts[#parts - 1] or row.via))
        end
        if row.join then
          table.insert(tags, "↑ joins above")
        elseif tests[row.id] then
          table.insert(tags, "◇ " .. plural(vim.tbl_count(tests[row.id]), "test"))
        end
        local name = prefix .. mark .. " " .. n.short
        table.insert(rendered, {
          name = name,
          tags = #tags > 0 and ("   " .. table.concat(tags, " · ")) or "",
          package = n.package,
          node = n,
          step = step,
          mark_col = #prefix,
          mark_len = #mark,
          mark_hl = mark_hl,
        })
      end
      table.insert(open_levels, last[k])
    end
  end

  local width = 0
  for _, r in ipairs(rendered) do
    if r.node then
      width = math.max(width, vim.fn.strdisplaywidth(r.name .. r.tags))
    end
  end
  local lines, hls, item_of_row = {}, {}, {}
  local previous
  for _, r in ipairs(rendered) do
    local marker = "  "
    if r.step and r.step == opts.current then
      marker = "▶ "
    elseif r.step and opts.done and opts.done[r.step] then
      marker = "✓ "
    end
    local row = #lines
    if r.node then
      local left = r.name .. r.tags
      local package = r.package ~= previous and r.package or ""
      previous = r.package
      local line = marker .. left
      if package ~= "" then
        line = line .. string.rep(" ", width - vim.fn.strdisplaywidth(left) + 3) .. package
      end
      table.insert(lines, line)
      local mark_at = #marker + r.mark_col
      table.insert(hls, { row, mark_at, mark_at + r.mark_len, r.mark_hl })
      local tags_at = #marker + #r.name
      if r.tags ~= "" then
        table.insert(hls, { row, tags_at, tags_at + #r.tags, "Comment" })
      end
      if package ~= "" then
        table.insert(hls, { row, #line - #package, #line, "Comment" })
      end
      if r.node.status == "unchanged" then
        table.insert(hls, { row, mark_at + r.mark_len, tags_at, "Comment" })
      end
      if r.step and r.step == opts.current then
        table.insert(hls, { row, 0, #line, "TrailCurrentStep" })
      elseif r.step and opts.done and opts.done[r.step] then
        table.insert(hls, { row, 0, #marker, "TrailAdd" })
      end
      item_of_row[row + 1] = { node = r.node, step = r.step }
    else
      local line = r.text == "" and "" or (marker .. r.text)
      table.insert(lines, line)
      if r.fold then
        table.insert(hls, { row, 0, #line, "Comment" })
        item_of_row[row + 1] = { fold = r.fold }
      end
    end
  end
  return lines, hls, item_of_row
end

return M
