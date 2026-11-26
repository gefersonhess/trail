---A path drawn as a tree, always fully open: one per entry point, each change
---under the change it is reached from, with the unchanged functions on the
---way as rows shared by the changes reached through them. A change reached
---again repeats under each caller with the changes below it. Each row's
---details (step, interface, tests, package) are kept for the cursor row only.
local M = {}

vim.api.nvim_set_hl(0, "TrailCurrentStep", { link = "Visual", default = true })

local function plural(n, word)
  return n .. " " .. word .. (n == 1 and "" or "s")
end

---What the trees say about the path: each function's callees in the order
---the trees show them, which functions lead to a step, and the first steps
---each unchanged function reaches.
local function calls(path, is_step)
  local callees, callers = {}, {}
  for _, tree in ipairs(path.trees) do
    local above = {}
    for k, row in ipairs(tree.rows) do
      for d = #above, row.depth + 1, -1 do
        above[d] = nil
      end
      local parent = above[row.depth]
      if k > 1 and parent and not parent.join then
        table.insert(callees[parent.id], { id = row.id, via = row.via })
        callers[row.id] = callers[row.id] or {}
        table.insert(callers[row.id], parent.id)
      end
      if not row.join then
        callees[row.id] = callees[row.id] or {}
      end
      above[row.depth + 1] = row
    end
  end
  local leads, queue = {}, {}
  for id in pairs(callees) do
    if is_step(id) then
      leads[id] = true
      table.insert(queue, id)
    end
  end
  while #queue > 0 do
    for _, p in ipairs(callers[table.remove(queue)] or {}) do
      if not leads[p] then
        leads[p] = true
        table.insert(queue, p)
      end
    end
  end
  local nearest = {}
  local function first_steps(id)
    if nearest[id] then
      return nearest[id]
    end
    local out, seen, level = {}, { [id] = true }, { id }
    local hops = 0
    while #level > 0 do
      local next_level = {}
      for _, u in ipairs(level) do
        for _, c in ipairs(callees[u] or {}) do
          if leads[c.id] and not seen[c.id] then
            seen[c.id] = true
            if is_step(c.id) then
              table.insert(out, { id = c.id, hops = hops, via = c.via })
            else
              table.insert(next_level, c.id)
            end
          end
        end
      end
      level, hops = next_level, hops + 1
    end
    nearest[id] = out
    return out
  end
  return callees, leads, first_steps
end

---Builds the trees as nested nodes: `{ id, key, children, again, chain,
---hops, via }`.
local function build(path, is_step)
  local callees, leads, first_steps = calls(path, is_step)
  local placed, walked = {}, {}

  local function again(id, key, on_branch)
    local node = { id = id, key = key, again = true, children = {} }
    on_branch[id] = true
    local seen = {}
    local function add(c, hops, via)
      if on_branch[c] or seen[c] then
        return
      end
      seen[c] = true
      local child = again(c, key .. ">" .. c, on_branch)
      child.hops, child.via = hops, via
      table.insert(node.children, child)
    end
    for _, c in ipairs(callees[id] or {}) do
      if is_step(c.id) then
        add(c.id, 0, c.via)
      elseif leads[c.id] then
        for _, n in ipairs(first_steps(c.id)) do
          add(n.id, n.hops + 1, n.via)
        end
      end
    end
    on_branch[id] = nil
    return node
  end


  local function home(id, key, on_branch)
    local node = { id = id, key = key, children = {} }
    if is_step(id) then
      placed[id] = true
    end
    on_branch[id] = true
    local seen = {}
    local function add(child)
      if not seen[child.id] then
        seen[child.id] = true
        table.insert(node.children, child)
      end
    end
    local function through(c, chain, via)
      if on_branch[c] or seen[c] then
        return
      end
      local child_key = key .. ">" .. c
      if is_step(c) then
        local child = placed[c] and again(c, child_key, on_branch) or home(c, child_key, on_branch)
        child.chain, child.hops, child.via = chain, #chain, via
        add(child)
      elseif leads[c] then
        if walked[c] then
          for _, n in ipairs(first_steps(c)) do
            if not on_branch[n.id] and not seen[n.id] then
              local child = again(n.id, key .. ">" .. n.id, on_branch)
              child.hops, child.via = #chain + 1 + n.hops, n.via
              add(child)
            end
          end
        else
          walked[c] = true
          local next_chain = vim.list_extend(vim.list_extend({}, chain), { { id = c, via = via } })
          for _, cc in ipairs(callees[c] or {}) do
            through(cc.id, next_chain, cc.via)
          end
        end
      end
    end
    for _, c in ipairs(callees[id] or {}) do
      through(c.id, {}, c.via)
    end
    on_branch[id] = nil
    return node
  end

  local trees, quiet = {}, {}
  for _, tree in ipairs(path.trees) do
    local root = tree.rows[1].id
    if tree.changes then
      walked[root] = true
      table.insert(trees, home(root, root, {}))
    else
      table.insert(quiet, root)
    end
  end
  for _, root in ipairs(quiet) do
    local node = { id = root, key = root, children = {} }
    for _, n in ipairs(first_steps(root)) do
      local child = again(n.id, root .. ">" .. n.id, { [root] = true })
      child.hops, child.via = n.hops, n.via
      table.insert(node.children, child)
    end
    table.insert(trees, node)
  end
  return trees
end

---A node's children with the unchanged functions on their way as rows of
---their own, shared where the routes start the same: `Job.Run` with two
---changes below it is one row with both under it, not one per change.
local function with_hops(children)
  local out, hop_of = {}, {}
  for _, c in ipairs(children) do
    local link = c.chain and c.chain[1]
    if link then
      local hop = hop_of[link.id]
      if not hop then
        hop = { id = link.id, via = link.via, hop = true, below = {} }
        hop_of[link.id] = hop
        table.insert(out, hop)
      end
      table.insert(hop.below, vim.tbl_extend("force", c, { chain = vim.list_slice(c.chain, 2) }))
    else
      table.insert(out, c)
    end
  end
  for _, n in ipairs(out) do
    if n.hop then
      n.children, n.below = with_hops(n.below), nil
    end
  end
  return out
end

---Draws an impact path's trees. `opts.current` is the step shown and
---`opts.station` an unchanged function shown instead; `opts.done[i]` says
---step `i` is reviewed.
---@param path table the engine's impact path
---@param opts { current: integer|nil, station: string|nil, done: table<integer, boolean>|nil, threads: (fun(id): integer)|nil, indent: string|nil }
---@return string[] lines, table[] highlights, table<integer, table> item_of_row
function M.render(path, opts)
  opts = opts or {}
  local done = opts.done or {}
  local indent = opts.indent or ""
  local threads = opts.threads or function()
    return 0
  end
  local nodes, step_of, tests = {}, {}, {}
  for _, n in ipairs(path.nodes) do
    nodes[n.id] = n
  end
  for i, id in ipairs(path.steps) do
    step_of[id] = i
  end
  for _, e in ipairs(path.edges) do
    if nodes[e.from] and nodes[e.from].is_test then
      tests[e.to] = tests[e.to] or {}
      tests[e.to][e.from] = true
    end
  end
  local function is_step(id)
    return step_of[id] ~= nil
  end
  local current = opts.station or (opts.current and path.steps[opts.current])


  local trees = build(path, is_step)
  local rows = {}
  local function guide(guides)
    local prefix = ""
    for _, open in ipairs(guides) do
      prefix = prefix .. (open and "│ " or "  ")
    end
    return prefix
  end
  local function deeper(guides, last)
    return vim.list_extend(vim.list_extend({}, guides), { not last })
  end
  local function flatten(node, guides, last, depth)
    local connector = ""
    if depth > 0 then
      connector = (last and "└" or "├") .. ((node.hops or 0) > 0 and not node.chain and "┄" or "─")
    end
    table.insert(rows, {
      prefix = guide(guides) .. connector,
      id = node.id,
      again = node.again,
      hop = node.hop,
      hops = not node.chain and node.hops or 0,
      via = node.via,
    })
    local children = node.hop and node.children or with_hops(node.children)
    local below = depth > 0 and deeper(guides, last) or {}
    for i, c in ipairs(children) do
      flatten(c, below, i == #children, depth + 1)
    end
  end
  for t, tree in ipairs(trees) do
    if t > 1 then
      table.insert(rows, { blank = true })
    end
    flatten(tree, {}, true, 0)
  end

  local width = 0
  local function label(r)
    local text = nodes[r.id].short
    if r.hops and r.hops > 0 then
      text = text .. "  ┄" .. r.hops
    end
    return text
  end
  for _, r in ipairs(rows) do
    if r.id then
      width = math.max(width, vim.fn.strdisplaywidth(r.prefix .. label(r)))
    end
  end

  local lines, hls, item_of_row = {}, {}, {}
  for _, r in ipairs(rows) do
    local row = #lines
    local head = indent .. (r.prefix or "")
    if r.blank then
      table.insert(lines, "")
    else
      local n = nodes[r.id]
      local step = step_of[r.id]
      local shown = r.id == current and not r.again and not r.hop
      local mark, mark_hl = "◇", "Comment"
      if shown then
        mark, mark_hl = "▶", "TrailCurrentStep"
      elseif step then
        if done[step] then
          mark, mark_hl = "●", "TrailAddText"
        else
          mark, mark_hl = "○", "Comment"
        end
      end
      local line = head .. mark .. " "
      table.insert(hls, { row, #indent, #head, "Comment" })
      table.insert(hls, { row, #head, #head + #mark, mark_hl })
      local name_at = #line
      line = line .. n.short
      local name_hl = shown and "TrailCurrentStep"
        or n.status == "added" and "TrailAddText"
        or n.status == "removed" and "TrailDeleteText"
        or n.status == "unchanged" and "Comment"
        or nil
      if name_hl then
        table.insert(hls, { row, name_at, #line, name_hl })
      end
      local rest = label(r):sub(#n.short + 1)
      if rest ~= "" then
        table.insert(hls, { row, #line, #line + #rest, "Comment" })
        line = line .. rest
      end
      local count = threads(r.id)
      if count > 0 then
        line = line .. string.rep(" ", width - vim.fn.strdisplaywidth(r.prefix .. label(r)) + 3)
        local text = plural(count, "thread")
        table.insert(hls, { row, #line, #line + #text, "TrailThreadAuthor" })
        line = line .. text
      end
      table.insert(lines, line)

      local details = {}
      if step then
        table.insert(details, "step " .. step)
      elseif n.status ~= "unchanged" then
        table.insert(details, n.status)
      end
      if r.again then
        table.insert(details, "shown above")
      end
      if r.hops and r.hops > 0 then
        table.insert(details, "through " .. plural(r.hops, "function"))
      end
      if r.via then
        local parts = vim.split(r.via, ".", { plain = true })
        table.insert(details, "via " .. (parts[#parts - 1] or r.via))
      end
      if tests[r.id] then
        table.insert(details, "◇ " .. plural(vim.tbl_count(tests[r.id]), "test"))
      end
      if n.package and n.package ~= "" then
        table.insert(details, n.package)
      end
      item_of_row[row + 1] = {
        node = n,
        step = not r.again and not r.hop and step or nil,
        again = r.again,
        details = table.concat(details, " · "),
      }
    end
  end
  return lines, hls, item_of_row
end

---The rows a walk through the path stops at, in the order the tree shows
---them: each entry point and change where it first shows, with the index of
---the row it sits under and the function that row calls to reach it (the
---first unchanged function on the way, or itself).
---@return { id: string, parent: integer|nil, call: string }[]
function M.walk(path)
  local steps = {}
  for _, id in ipairs(path.steps) do
    steps[id] = true
  end
  local out = {}
  local function visit(node, parent)
    if node.again then
      return
    end
    local first = node.chain and node.chain[1]
    table.insert(out, { id = node.id, parent = parent, call = first and first.id or node.id })
    local here = #out
    for _, c in ipairs(node.children) do
      visit(c, here)
    end
  end
  for _, root in ipairs(build(path, function(id)
    return steps[id] ~= nil
  end)) do
    visit(root, nil)
  end
  return out
end

---The route from an entry point down to where `id` first shows in the
---trees, unchanged functions on the way included, and how many other
---functions of the path call `id`.
---@return string[] ids, integer others
function M.chain(path, id)
  local steps = {}
  for _, s in ipairs(path.steps) do
    steps[s] = true
  end
  local route
  local function visit(node, above)
    if route then
      return
    end
    local here = vim.list_extend({}, above)
    for _, c in ipairs(node.chain or {}) do
      table.insert(here, c.id)
      if c.id == id then
        route = here
        return
      end
    end
    table.insert(here, node.id)
    if node.id == id then
      route = here
      return
    end
    for _, c in ipairs(node.children) do
      visit(c, here)
    end
  end
  for _, root in ipairs(build(path, function(n)
    return steps[n] ~= nil
  end, { ["*"] = true })) do
    visit(root, {})
  end
  route = route or { id }
  local tests, callers = {}, {}
  for _, n in ipairs(path.nodes) do
    tests[n.id] = n.is_test
  end
  for _, e in ipairs(path.edges) do
    if e.to == id and e.from ~= route[#route - 1] and e.from ~= id and not tests[e.from] then
      callers[e.from] = true
    end
  end
  return route, vim.tbl_count(callers)
end

return M
