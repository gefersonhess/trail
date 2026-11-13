local engine = require("trail.engine")
local diffview = require("trail.diffview")
local help = require("trail.help")
local peek = require("trail.peek")
local graph = require("trail.graph")
local pathview = require("trail.pathview")
local store = require("trail.state")
local comments = require("trail.comments")
local send = require("trail.send")

local M = {}

local ns = vim.api.nvim_create_namespace("trail")
local ns_preview = vim.api.nvim_create_namespace("trail.preview")
local state = {}

local function parse_range(arg)
  local base, head = arg:match("^(.-)%.%.%.?(.*)$")
  if not base then
    base, head = arg, ""
  end
  return base, head ~= "" and head or "HEAD"
end

local function count(n, word)
  return n .. " " .. word .. (n == 1 and "" or "s")
end

local function hunk_label(h)
  local side = h.new.len > 0 and h.new or h.old
  return string.format("%s:%d-%d", h.file, side.start, side.start + math.max(side.len, 1) - 1)
end

---Turns the engine's paths, tests and loose hunks into paths the path view can walk.
local function build_paths(review)
  local nodes, hunks = {}, {}
  for _, n in ipairs(review.nodes) do
    nodes[n.id] = n
  end
  for _, h in ipairs(review.hunks) do
    hunks[h.id] = h
  end
  local code = {}
  for _, p in ipairs(review.paths) do
    local steps = {}
    for _, step in ipairs(p.steps) do
      table.insert(steps, { node = nodes[step[1]] })
    end
    table.insert(code, { id = p.id, title = p.title, kind = "code", entries = p.entries, steps = steps })
  end
  local tests = {}
  for _, t in ipairs(review.tests) do
    local steps, in_nodes = {}, {}
    for _, id in ipairs(t.nodes) do
      table.insert(steps, { node = nodes[id] })
      for _, h in ipairs(nodes[id].hunks) do
        in_nodes[h] = true
      end
    end
    for _, id in ipairs(t.hunks) do
      if not in_nodes[id] then
        table.insert(steps, { hunk = hunks[id] })
      end
    end
    table.insert(tests, { id = "tests:" .. t.file, title = t.file, kind = "tests", steps = steps, test = t })
  end
  local loose = { id = "loose", title = "Not in any path", kind = "loose", steps = {} }
  for _, id in ipairs(review.unassigned) do
    table.insert(loose.steps, { hunk = hunks[id] })
  end
  return code, tests, loose
end

local function all_paths()
  local list = vim.list_extend(vim.list_extend({}, state.code), state.tests)
  if #state.loose.steps > 0 then
    table.insert(list, state.loose)
  end
  return list
end

local function home()
  if vim.api.nvim_tabpage_is_valid(state.list_tab) then
    vim.api.nvim_set_current_tabpage(state.list_tab)
  end
end

local function find_definition(file, params, side, on_found)
  if not file.language then
    vim.notify("trail: peek works in Go and Rust files", vim.log.levels.INFO)
    return
  end
  local name, qualifier = peek.word_at_cursor()
  if not name then
    return
  end
  local review = state.review
  local old = side == "old"
  engine.request("peek", {
    repo = state.repo,
    commit = old and review.base_commit or review.head_commit,
    language = file.language,
    name = name,
    qualifier = qualifier,
    from_path = old and (params.old_path or params.new_path) or (params.new_path or params.old_path),
  }, function(err, result)
    if err then
      vim.notify("trail: " .. err.message, vim.log.levels.ERROR)
      return
    end
    local match = result.matches[1]
    if not match then
      vim.notify("trail: no function named " .. name, vim.log.levels.INFO)
      return
    end
    on_found(match, #result.matches, vim.filetype.match({ filename = match.path }) or file.language)
  end)
end

local function open_definition(match, side, filetype)
  if side == "old" then
    peek.open_lines(match, filetype, string.format(" base  %s:%d  ·  read-only, no LSP  ·  :q closes ", match.path, match.start))
    return
  end
  engine.request("checkout", { repo = state.repo, commit = state.review.head_commit }, function(err, checkout)
    if err then
      vim.notify("trail: " .. err.message, vim.log.levels.ERROR)
      return
    end
    local where = checkout.worktree and "review worktree" or "your checkout"
    peek.open_file(checkout.path .. "/" .. match.path, match.start,
      string.format(" %s:%d  ·  %s  ·  :q closes ", match.path, match.start, where))
  end)
end

local function peek_at_cursor(file, params, side)
  find_definition(file, params, side, function(match, total, filetype)
    local range_side = side == "old" and "old" or "new"
    local changed = vim.iter(state.review.nodes):any(function(n)
      local range = n[range_side]
      return n.file == match.path and range ~= nil and match.start >= range.start
        and match.start < range.start + range.len
    end)
    peek.show(match, {
      filetype = filetype,
      total = total,
      changed = changed,
      on_open = function()
        open_definition(match, side, filetype)
      end,
    })
  end)
end

---Shows the diff of a node's or hunk's file in `win`, focused on it.
local function show_target(target, is_node, win, keys, after)
  local review = state.review
  local file = vim.iter(review.files):find(function(f)
    return f.path == target.file
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
    if not vim.api.nvim_win_is_valid(win) then
      return
    end
    -- A diff arriving after the user moved to another tab renders there
    -- without pulling them back or counting its hunks as seen.
    local previous = vim.api.nvim_get_current_win()
    local quiet = vim.api.nvim_win_get_tabpage(win) ~= vim.api.nvim_get_current_tabpage()
    local current
    local function annotate()
      if current then
        current.annotate(comments.notes(current, params.old_path, params.new_path))
      end
    end
    local function changed()
      annotate()
      M.refresh_home()
    end
    local all_keys = vim.list_extend({}, keys or {})
    for _, kind in ipairs(comments.kinds) do
      table.insert(all_keys, { "c" .. kind:sub(1, 1), function()
        comments.add(kind, current, params.old_path, params.new_path, changed)
      end, "Add a " .. kind .. " comment on this line" })
    end
    table.insert(all_keys, { "ce", function()
      comments.edit(current, params.old_path, params.new_path, changed)
    end, "Edit the comment on this line" })
    table.insert(all_keys, { "cd", function()
      comments.delete(current, params.old_path, params.new_path, changed)
    end, "Delete the comment on this line" })
    local view = diffview.show(diff, {
      win = win,
      keys = all_keys,
      on_redraw = function(again)
        current = again
        annotate()
      end,
      hunks = vim.tbl_filter(function(h)
        return h.file == target.file
      end, review.hunks),
      on_seen = function(ids)
        if quiet then
          return
        end
        if store.mark_seen(ids) then
          pathview.refresh_graph()
          M.refresh_home()
        end
      end,
      old_path = params.old_path,
      new_path = params.new_path,
      on_back = home,
      on_peek = function(side)
        peek_at_cursor(file, params, side)
      end,
      on_definition = function(side)
        find_definition(file, params, side, function(match, _, filetype)
          open_definition(match, side, filetype)
        end)
      end,
    })
    current = view
    annotate()
    local on_new = target.new and (is_node or target.new.len > 0)
    view.focus(on_new and "new" or "old", math.max((on_new and target.new or target.old).start, 1))
    if quiet then
      vim.api.nvim_set_current_win(previous)
      quiet = false
    elseif after then
      after()
    end
  end)
end

local function path_context()
  return {
    review = function()
      return state.review
    end,
    show_target = show_target,
    home = home,
    switch_path = function()
      M.switch_path()
    end,
    done_steps = function(path)
      return M.done_steps(path)
    end,
    on_step = function(path, step)
      store.set_position(path.id, step)
    end,
  }
end

local function step_hunks(step)
  return step.node and step.node.hunks or { step.hunk.id }
end

---Steps whose hunks have all been seen.
function M.done_steps(path)
  local done = {}
  for i, step in ipairs(path.steps) do
    done[i] = vim.iter(step_hunks(step)):all(store.seen)
  end
  return done
end

local function progress(path)
  local n = 0
  for _, d in pairs(M.done_steps(path)) do
    n = n + (d and 1 or 0)
  end
  return n
end

local function enter(path, step)
  if #path.steps == 0 then
    return
  end
  pathview.open(path_context(), path, step or store.position(path.id) or 1)
end

local function open_send()
  send.open({
    title = state.title,
    unseen = function()
      local labels = {}
      for _, h in ipairs(state.review.hunks) do
        if not store.seen(h.id) then
          table.insert(labels, hunk_label(h))
        end
      end
      return labels
    end,
    jump = function(c)
      for _, path in ipairs(all_paths()) do
        for i, step in ipairs(path.steps) do
          local n = step.node
          local range = n and (c.side == "old" and n.old or n.new)
          local h = step.hunk
          local hrange = h and (c.side == "old" and h.old or h.new)
          local function within(r, file)
            return r and file == c.file and c.line >= r.start and c.line < r.start + math.max(r.len, 1)
          end
          if within(range, n and n.file) or within(hrange, h and h.file) then
            return enter(path, i)
          end
        end
      end
      vim.notify("trail: that comment is not in any path step", vim.log.levels.INFO)
    end,
    home = home,
  })
end

function M.switch_path()
  local list = all_paths()
  vim.ui.select(list, {
    prompt = "Path",
    format_item = function(p)
      return string.format("%s  (%s)", p.title, count(#p.steps, "step"))
    end,
  }, function(choice)
    if choice then
      enter(choice)
    end
  end)
end

local function build_home(review)
  local lines, items, hls = {}, {}, {}
  local function add(text, item, hl)
    table.insert(lines, text)
    items[#lines] = item
    for _, h in ipairs(hl or {}) do
      table.insert(hls, { #lines - 1, h[2], h[3], h[1] })
    end
  end
  local header = string.format("trail  %s  (%s → %s)", state.title,
    review.base_commit:sub(1, 7), review.head_commit:sub(1, 7))
  add(header, nil, { { "Title", 0, #header } })
  add(string.format("%s · %s · %s · %s not in any path · %s", count(#state.code, "path"), count(#review.nodes, "function"),
    count(#state.tests, "test file"), count(#state.loose.steps, "hunk"), count(#store.comments(), "comment")), nil,
    { { "Comment", 0, -1 } })
  local uncertain = vim.iter(review.edges):any(function(e)
    return e.source == "name_match"
  end)
  add((uncertain and "Calls matched by name may be wrong.  " or "") .. "<CR> or 1-9 enters a path  ·  S send  ·  ? keys", nil,
    { { "Comment", 0, -1 } })

  add("")
  add("Paths", nil, { { "Title", 0, 5 } })
  local title_width = 0
  for _, p in ipairs(state.code) do
    title_width = math.max(title_width, vim.fn.strdisplaywidth(p.title))
  end
  for i, p in ipairs(state.code) do
    local number = i <= 9 and tostring(i) or " "
    local done = progress(p)
    local text = string.format("  %s  %s%s  %s  %s %d/%d", number, p.title,
      string.rep(" ", title_width - vim.fn.strdisplaywidth(p.title)), count(#p.steps, "step"),
      done == #p.steps and "✓" or "·", done, #p.steps)
    add(text, { path = p }, {
      { "Number", 2, 3 },
      { done == #p.steps and "TrailAdd" or "Comment", 5 + #p.title + title_width - vim.fn.strdisplaywidth(p.title) + 2, -1 },
    })
  end
  if #state.code == 0 then
    add("  (no changed functions)", nil, { { "Comment", 0, -1 } })
  end

  if #state.tests > 0 or #review.uncovered > 0 then
    add("")
    add("Tests", nil, { { "Title", 0, 5 } })
    for _, t in ipairs(state.tests) do
      local text = string.format("     %s  %s · covers %s  · %d/%d", t.title, count(#t.test.nodes, "test"),
        count(#t.test.covers, "function"), progress(t), #t.steps)
      add(text, { path = t }, { { "Comment", 5 + #t.title, -1 } })
    end
    if #review.uncovered > 0 then
      local names = vim.tbl_map(function(id)
        return (id:gsub("^%w+:", ""))
      end, review.uncovered)
      local text = "  !  no test change covers " .. table.concat(names, ", ")
      add(text, nil, { { "WarningMsg", 2, 3 }, { "Comment", 5, -1 } })
    end
  end

  if #state.loose.steps > 0 then
    add("")
    add("Not in any path", nil, { { "Title", 0, 15 } })
    for i, step in ipairs(state.loose.steps) do
      local text = (store.seen(step.hunk.id) and "  ✓  " or "     ") .. hunk_label(step.hunk)
      add(text, { path = state.loose, step = i }, { { "Comment", 0, -1 } })
    end
  end
  return lines, items, hls
end

local function render_preview()
  local buf = state.list_buf
  local win = vim.fn.bufwinid(buf)
  local row = win ~= -1 and vim.api.nvim_win_get_cursor(win)[1] or 0
  local item = state.items[row] or {}
  local path = item.path or state.code[1]
  if path == state.preview_path and state.preview_start then
    return
  end
  state.preview_path = path
  local lines, hls = {}, {}
  if path then
    local graph_lines, graph_hls = graph.render(path, state.review, {})
    local title = "── " .. path.title .. " "
    lines = { "", title .. string.rep("─", math.max(0, 60 - vim.fn.strdisplaywidth(title))) }
    vim.list_extend(lines, graph_lines)
    table.insert(hls, { 1, 0, -1, "Comment" })
    for _, h in ipairs(graph_hls) do
      table.insert(hls, { h[1] + 2, h[2], h[3], h[4] })
    end
  end
  local start = state.preview_start
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, start, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns_preview, 0, -1)
  for _, h in ipairs(hls) do
    local line = lines[h[1] + 1]
    vim.api.nvim_buf_set_extmark(buf, ns_preview, start + h[1], h[2], { end_col = h[3] < 0 and #line or h[3], hl_group = h[4] })
  end
end

local function render()
  local buf = state.list_buf
  state.code, state.tests, state.loose = build_paths(state.review)
  local lines, items, hls = build_home(state.review)
  state.items = items
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, h in ipairs(hls) do
    local end_col = h[3] < 0 and #lines[h[1] + 1] or h[3]
    vim.api.nvim_buf_set_extmark(buf, ns, h[1], h[2], { end_col = end_col, hl_group = h[4] })
  end
  state.preview_start = #lines
  state.preview_path = nil
  render_preview()
  pathview.refresh_graph()
end

function M.refresh_home()
  if state.list_buf and vim.api.nvim_buf_is_valid(state.list_buf) and state.review then
    local view = vim.fn.bufwinid(state.list_buf)
    local cursor = view ~= -1 and vim.api.nvim_win_get_cursor(view)
    render()
    if cursor then
      pcall(vim.api.nvim_win_set_cursor, view, cursor)
    end
  end
end

local function review_range()
  store.load(state.repo, state.key)
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

local function load()
  if not state.pr then
    return review_range()
  end
  engine.request("pull_request", { repo = state.repo, number = state.pr }, function(err, pr)
    if err then
      vim.notify("trail: " .. err.message, vim.log.levels.ERROR)
      return
    end
    state.base, state.head = pr.base, pr.head
    state.title = string.format("#%d %s", pr.number, pr.title)
    review_range()
  end)
end

function M.open(arg)
  if not arg or arg == "" then
    vim.notify("usage: :Trail base..head", vim.log.levels.ERROR)
    return
  end
  local root = vim.fs.root(0, ".git") or vim.fn.getcwd()
  state = { repo = root }
  local pr = arg:match("^#(%d+)$")
  if pr then
    state.pr = tonumber(pr)
    state.key = "pr-" .. pr
    state.title = arg
  else
    state.base, state.head = parse_range(arg)
    state.key = state.base .. ".." .. state.head
    state.title = state.key
  end

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

  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, desc = desc, nowait = true })
  end
  map("<CR>", function()
    local item = state.items and state.items[vim.api.nvim_win_get_cursor(0)[1]]
    if item and item.path then
      enter(item.path, item.step)
    end
  end, "Enter the path")
  for n = 1, 9 do
    vim.keymap.set("n", tostring(n), function()
      if state.code and state.code[n] then
        enter(state.code[n])
      end
    end, { buffer = buf, nowait = true })
  end
  map("gp", M.switch_path, "Switch path")
  map("S", open_send, "Send screen: comments, verdict, copy")
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = buf,
    callback = function()
      if state.items and state.preview_start then
        render_preview()
      end
    end,
  })
  map("R", load, "Refresh")
  map("?", help.show, "Show keys")
  map("q", function()
    local path_tab = pathview.tab()
    if path_tab and vim.api.nvim_tabpage_is_valid(path_tab) then
      vim.api.nvim_set_current_tabpage(path_tab)
      vim.cmd("tabclose")
    end
    vim.api.nvim_set_current_tabpage(state.list_tab)
    if #vim.api.nvim_list_tabpages() > 1 then
      vim.cmd("tabclose")
    else
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end, "Quit trail")

  load()
end

return M
