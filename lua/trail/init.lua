local engine = require("trail.engine")
local sidebyside = require("trail.sidebyside")

local M = {}

local ns = vim.api.nvim_create_namespace("trail")
local state = {}

local signs = { added = "+", modified = "~", removed = "-" }
local sign_hl = { added = "DiffAdd", modified = "DiffChange", removed = "DiffDelete" }
local edge_note = { added = "new call", removed = "call removed" }

local function parse_range(arg)
  local base, head = arg:match("^(.-)%.%.%.?(.*)$")
  if not base then
    base, head = arg, ""
  end
  return base, head ~= "" and head or "HEAD"
end

local function short_name(node)
  return (node.id:gsub("^%w+:", ""))
end

local function build_lines(review)
  local by_id, callees, called = {}, {}, {}
  for _, n in ipairs(review.nodes) do
    by_id[n.id] = n
    callees[n.id] = {}
  end
  for _, e in ipairs(review.edges) do
    local from, to = by_id[e.from], by_id[e.to]
    if from and to then
      table.insert(callees[e.from], { node = to, status = e.status })
      if from.is_test == to.is_test then
        called[e.to] = true
      end
    end
  end

  local lines, items, hls = {}, {}, {}
  local function add(text, item, hl)
    table.insert(lines, text)
    items[#lines] = item
    if hl then
      for _, h in ipairs(hl) do
        table.insert(hls, { #lines - 1, h[1], h[2], h[3] })
      end
    end
  end

  local expanded = {}
  local function walk(node, depth, edge, in_tests)
    local indent = string.rep("  ", depth + 1)
    local sign = signs[node.status]
    local range = node.new or node.old
    local loc = string.format("%s:%d", node.file, range.start)
    local note = edge and edge_note[edge.status] or nil
    local leaf = expanded[node.id] or (in_tests and not node.is_test)
    local text = string.format("%s%s %s  %s", indent, sign, short_name(node), loc)
    local loc_col = #text - #loc
    if note then
      text = text .. "  (" .. note .. ")"
    end
    if expanded[node.id] and #callees[node.id] > 0 and not (in_tests and not node.is_test) then
      text = text .. "  ↑ see above"
    end
    add(text, { node = node }, {
      { sign_hl[node.status], #indent, #indent + 1 },
      { "Comment", loc_col, #text },
    })
    if leaf then
      return
    end
    expanded[node.id] = true
    for _, c in ipairs(callees[node.id]) do
      walk(c.node, depth + 1, c, in_tests)
    end
  end

  local function section(title, want_tests)
    local roots = {}
    for _, n in ipairs(review.nodes) do
      if n.is_test == want_tests and not called[n.id] then
        table.insert(roots, n)
      end
    end
    if #roots == 0 and not vim.iter(review.nodes):any(function(n)
      return n.is_test == want_tests
    end) then
      return
    end
    add("")
    add(title, nil, { { "Title", 0, #title } })
    for _, n in ipairs(roots) do
      walk(n, 0, nil, want_tests)
    end
    for _, n in ipairs(review.nodes) do
      if n.is_test == want_tests and not expanded[n.id] then
        walk(n, 0, nil, want_tests)
      end
    end
  end

  local in_node = {}
  for _, n in ipairs(review.nodes) do
    for _, h in ipairs(n.hunks) do
      in_node[h] = true
    end
  end
  local loose = vim.tbl_filter(function(h)
    return not in_node[h.id]
  end, review.hunks)

  local header = string.format("trail  %s..%s  (%s → %s)", state.base, state.head,
    review.base_commit:sub(1, 7), review.head_commit:sub(1, 7))
  add(header, nil, { { "Title", 0, #header } })
  local function count(n, word)
    return n .. " " .. word .. (n == 1 and "" or "s")
  end
  add(string.format("%s · %s · %s outside functions", count(#review.nodes, "function"),
    count(#review.edges, "call"), count(#loose, "hunk")), nil, { { "Comment", 0, -1 } })
  add("Calls are matched by name and may be wrong.  <CR> diff  R refresh  q quit", nil, { { "Comment", 0, -1 } })

  section("Code", false)
  section("Tests", true)

  if #loose > 0 then
    add("")
    add("Not in any function", nil, { { "Title", 0, 19 } })
    for _, h in ipairs(loose) do
      local side = h.new.len > 0 and h.new or h.old
      local text = string.format("    %s:%d-%d", h.file, side.start, side.start + math.max(side.len, 1) - 1)
      add(text, { hunk = h }, { { "Comment", 0, #text } })
    end
  end
  return lines, items, hls
end

local function back_to_list()
  if vim.api.nvim_tabpage_is_valid(state.list_tab) then
    vim.api.nvim_set_current_tabpage(state.list_tab)
  end
end

local function open_item(item)
  local review = state.review
  local path = item.node and item.node.file or item.hunk.file
  local file = vim.iter(review.files):find(function(f)
    return f.path == path
  end)
  local params = {
    repo = state.repo,
    base_commit = review.base_commit,
    head_commit = review.head_commit,
    old_path = file.status ~= "added" and (file.old_path or file.path) or nil,
    new_path = file.status ~= "deleted" and file.path or nil,
  }
  engine.request("file_diff", params, function(err, diff)
    if err then
      vim.notify("trail: " .. err.message, vim.log.levels.ERROR)
      return
    end
    if state.diff_tab and vim.api.nvim_tabpage_is_valid(state.diff_tab) then
      vim.api.nvim_set_current_tabpage(state.diff_tab)
      vim.cmd("silent! tabclose")
    end
    vim.cmd("tabnew")
    state.diff_tab = vim.api.nvim_get_current_tabpage()
    local view = sidebyside.show(diff, {
      old_path = params.old_path,
      new_path = params.new_path,
      on_back = back_to_list,
    })
    local target = item.node or item.hunk
    local on_new = target.new and (item.node or target.new.len > 0)
    view.focus(on_new and "new" or "old", math.max((on_new and target.new or target.old).start, 1))
  end)
end

local function render()
  local buf = state.list_buf
  local lines, items, hls = build_lines(state.review)
  state.items = items
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, h in ipairs(hls) do
    local end_col = h[4] < 0 and #lines[h[1] + 1] or h[4]
    vim.api.nvim_buf_set_extmark(buf, ns, h[1], h[3], { end_col = end_col, hl_group = h[2] })
  end
end

local function load()
  engine.request("open", { repo = state.repo, base = state.base, head = state.head }, function(err, result)
    if err then
      vim.notify("trail: " .. err.message, vim.log.levels.ERROR)
      return
    end
    state.review = result
    if vim.api.nvim_buf_is_valid(state.list_buf) then
      render()
    end
  end)
end

function M.open(arg)
  if not arg or arg == "" then
    vim.notify("usage: :Trail base..head", vim.log.levels.ERROR)
    return
  end
  local root = vim.fs.root(0, ".git") or vim.fn.getcwd()
  state = { repo = root }
  state.base, state.head = parse_range(arg)

  vim.cmd("tabnew")
  state.list_tab = vim.api.nvim_get_current_tabpage()
  local buf = vim.api.nvim_get_current_buf()
  state.list_buf = buf
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_name(buf, "trail://" .. arg)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "trail: loading " .. arg .. " ..." })
  vim.bo[buf].modifiable = false

  vim.keymap.set("n", "<CR>", function()
    local item = state.items and state.items[vim.api.nvim_win_get_cursor(0)[1]]
    if item then
      open_item(item)
    end
  end, { buffer = buf, desc = "Open diff" })
  vim.keymap.set("n", "R", load, { buffer = buf, desc = "Refresh" })
  vim.keymap.set("n", "q", function()
    if state.diff_tab and vim.api.nvim_tabpage_is_valid(state.diff_tab) then
      vim.api.nvim_set_current_tabpage(state.diff_tab)
      vim.cmd("tabclose")
    end
    vim.api.nvim_set_current_tabpage(state.list_tab)
    if #vim.api.nvim_list_tabpages() > 1 then
      vim.cmd("tabclose")
    else
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end, { buffer = buf, desc = "Quit trail" })

  load()
end

return M
