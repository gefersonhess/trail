local engine = require("trail.engine")
local diffview = require("trail.diffview")
local help = require("trail.help")
local peek = require("trail.peek")
local tree = require("trail.tree")
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

---Turns the impact paths, the changed test files and the hunks left over
---into paths the path view can walk. Every hunk lands in one of them.
local function build_paths(review, impact)
  local nodes, hunks = {}, {}
  for _, n in ipairs(review.nodes) do
    nodes[n.id] = n
  end
  for _, h in ipairs(review.hunks) do
    hunks[h.id] = h
  end
  local covered = {}
  local code = {}
  for _, p in ipairs(impact and impact.paths or {}) do
    local steps, short = {}, {}
    for _, n in ipairs(p.nodes) do
      short[n.id] = n
    end
    for _, id in ipairs(p.steps) do
      if nodes[id] then
        table.insert(steps, { node = nodes[id] })
        for _, h in ipairs(nodes[id].hunks) do
          covered[h] = true
        end
      end
    end
    table.insert(code, { id = p.id, title = short[p.id].short, kind = "code", impact = p, steps = steps })
  end
  local tests = {}
  for _, t in ipairs(review.tests) do
    local steps, in_nodes = {}, {}
    for _, id in ipairs(t.nodes) do
      table.insert(steps, { node = nodes[id] })
      for _, h in ipairs(nodes[id].hunks) do
        in_nodes[h] = true
        covered[h] = true
      end
    end
    for _, id in ipairs(t.hunks) do
      covered[id] = true
      if not in_nodes[id] then
        table.insert(steps, { hunk = hunks[id] })
      end
    end
    table.insert(tests, { id = "tests:" .. t.file, title = t.file, kind = "tests", steps = steps, test = t })
  end
  local loose = { id = "loose", title = "Not in any path", kind = "loose", steps = {} }
  if impact then
    for _, h in ipairs(review.hunks) do
      if not covered[h.id] then
        table.insert(loose.steps, { hunk = h })
      end
    end
  end
  return code, tests, loose
end

---Changed functions of a path that no test calls, even through other code.
local function untested(path)
  local nodes, callers = {}, {}
  for _, n in ipairs(path.impact.nodes) do
    nodes[n.id] = n
  end
  for _, e in ipairs(path.impact.edges) do
    callers[e.to] = callers[e.to] or {}
    table.insert(callers[e.to], e.from)
  end
  local out = {}
  for _, id in ipairs(path.impact.steps) do
    local seen, queue, reached = { [id] = true }, { id }, false
    while #queue > 0 and not reached do
      for _, caller in ipairs(callers[table.remove(queue)] or {}) do
        if nodes[caller].is_test then
          reached = true
        elseif not seen[caller] then
          seen[caller] = true
          table.insert(queue, caller)
        end
      end
    end
    if not reached then
      table.insert(out, nodes[id].short)
    end
  end
  return out
end

local function all_paths()
  local list = vim.list_extend(vim.list_extend({}, state.code), state.tests)
  if #state.loose.steps > 0 then
    table.insert(list, state.loose)
  end
  return list
end

---Leaves a single window in the review tab and returns it. The paths screen,
---a path and the send screen take turns in it, so a review is one tab.
local function review_window()
  vim.api.nvim_set_current_tabpage(state.list_tab)
  vim.cmd("silent! only!")
  local win = vim.api.nvim_get_current_win()
  vim.w[win].trail_pane = nil
  -- A diff still loading for a step that was left must not draw over what comes next.
  vim.w[win].trail_request = (vim.w[win].trail_request or 0) + 1
  return win
end

local function home()
  if not vim.api.nvim_tabpage_is_valid(state.list_tab) or not vim.api.nvim_buf_is_valid(state.list_buf) then
    return
  end
  local win = review_window()
  if vim.api.nvim_win_get_buf(win) ~= state.list_buf then
    vim.api.nvim_win_set_buf(win, state.list_buf)
    M.refresh_home()
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
    peek.open_editor(checkout.path .. "/" .. match.path, match.start,
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
  -- Context nodes can live in files the change does not touch.
  local file = vim.iter(review.files):find(function(f)
    return f.path == target.file
  end) or {
    path = target.file,
    status = "modified",
    language = target.file:match("%.go$") and "go" or (target.file:match("%.rs$") and "rust" or nil),
  }
  local params = {
    repo = state.repo,
    base_commit = review.base_commit,
    head_commit = review.head_commit,
    old_path = file.status ~= "added" and (file.old_path or file.path) or nil,
    new_path = file.status ~= "deleted" and file.path or nil,
  }
  -- Only the newest request for a window may draw in it; answers for steps
  -- the user has already moved past are dropped.
  local request = (vim.w[win].trail_request or 0) + 1
  vim.w[win].trail_request = request
  engine.request("file_diff", params, function(err, diff)
    if err then
      vim.notify("trail: " .. err.message, vim.log.levels.ERROR)
      return
    end
    if not vim.api.nvim_win_is_valid(win) or vim.w[win].trail_request ~= request then
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

---Shows a function from an impact tree in the peek popup.
local function peek_node(node)
  local language = node.file:match("%.go$") and "go" or (node.file:match("%.rs$") and "rust" or nil)
  local short = node.short:gsub("^closure in ", "")
  local name = short:match("([%w_]+)$")
  local qualifier = short:match("^([%w_]+)[%.:]")
  engine.request("peek", {
    repo = state.repo,
    commit = state.review.head_commit,
    language = language,
    name = name,
    qualifier = qualifier,
    from_path = node.file,
  }, function(err, result)
    if err then
      vim.notify("trail: " .. err.message, vim.log.levels.ERROR)
      return
    end
    local match = vim.iter(result.matches):find(function(m)
      return m.path == node.file and m.start <= node.line
    end) or result.matches[1]
    if not match then
      vim.notify("trail: no function named " .. name, vim.log.levels.INFO)
      return
    end
    local filetype = vim.filetype.match({ filename = match.path }) or language
    peek.show(match, {
      filetype = filetype,
      total = #result.matches,
      changed = node.status ~= "unchanged",
      on_open = function()
        open_definition(match, "new", filetype)
      end,
    })
  end)
end

local toggle_reviewed

local function path_context()
  return {
    show_target = show_target,
    peek_node = peek_node,
    home = home,
    window = review_window,
    switch_path = function()
      M.switch_path()
    end,
    done_steps = function(path)
      return M.done_steps(path)
    end,
    on_step = function(path, step)
      store.set_position(path.id, step)
    end,
    toggle_reviewed = function(path)
      toggle_reviewed(path)
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

---Marks every hunk of a path as seen, or clears them when they all are
---already. Progress is per function, so other paths sharing them follow.
toggle_reviewed = function(path)
  local ids = {}
  for _, step in ipairs(path.steps) do
    vim.list_extend(ids, step_hunks(step))
  end
  if #ids == 0 then
    return
  end
  local reviewed = vim.iter(ids):all(store.seen)
  if reviewed then
    store.unmark_seen(ids)
  else
    store.mark_seen(ids)
  end
  pathview.refresh_graph()
  M.refresh_home()
  vim.notify(string.format("trail: %s %s", reviewed and "unmarked" or "marked as reviewed:", path.title), vim.log.levels.INFO)
end

---The path a row of the paths screen stands for; a file under "Not in any
---path" stands for that file's hunks only.
local function row_path(item)
  if item.path ~= state.loose or not item.step then
    return item.path
  end
  local file = state.loose.steps[item.step].hunk.file
  local steps = vim.tbl_filter(function(step)
    return step.hunk.file == file
  end, state.loose.steps)
  return { title = file, steps = steps }
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
    window = review_window,
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
  local changed = 0
  for _, p in ipairs(state.code) do
    changed = changed + #p.steps
  end
  if state.impact then
    add(string.format("%s · %s · %s · %s not in any path · %s", count(#state.code, "path"), count(changed, "changed function"),
      count(#state.tests, "test file"), count(#state.loose.steps, "hunk"), count(#store.comments(), "comment")), nil,
      { { "Comment", 0, -1 } })
  else
    add(string.format("%s · %s", count(#review.files, "file"), count(#store.comments(), "comment")), nil, { { "Comment", 0, -1 } })
  end
  add("<CR> or 1-9 enters a path  ·  mr marks it reviewed  ·  S send  ·  ? keys", nil, { { "Comment", 0, -1 } })
  if review.ignored and #review.ignored > 0 then
    add(count(#review.ignored, "file") .. " hidden by vim.g.trail_ignore", nil, { { "Comment", 0, -1 } })
  end

  add("")
  add("Paths", nil, { { "Title", 0, 5 } })
  if state.impact_error then
    add("  The impact could not be worked out: " .. state.impact_error, nil, { { "WarningMsg", 0, -1 } })
  elseif not state.impact then
    local waited = state.impact_started and math.floor((vim.uv.now() - state.impact_started) / 1000) or 0
    add(string.format("  Working out the impact of each change… %ds  (engine log: %s)", waited,
      vim.fn.fnamemodify(engine.log_path, ":~")), nil, { { "Comment", 0, -1 } })
  end
  local rows = {}
  local widths = { 0, 0, 0 }
  for i, p in ipairs(state.code) do
    local entries, functions, tested, packages, seen_package = 0, 0, false, {}, {}
    for _, n in ipairs(p.impact.nodes) do
      if n.entry then
        entries = entries + 1
      end
      if n.is_test then
        tested = true
      else
        functions = functions + 1
      end
    end
    for _, id in ipairs(p.impact.steps) do
      for _, n in ipairs(p.impact.nodes) do
        if n.id == id and not seen_package[n.package] then
          seen_package[n.package] = true
          table.insert(packages, n.package)
        end
      end
    end
    local reach = count(entries, "entry point") .. " · " .. count(functions, "function")
    if functions <= 1 then
      reach = tested and "only tests call it" or "nothing calls it"
    end
    local done = progress(p)
    local row = {
      number = i <= 9 and tostring(i) or " ",
      title = p.title,
      changes = count(#p.steps, "change"),
      reach = reach,
      progress = string.format("%s %d/%d", done == #p.steps and "✓" or "·", done, #p.steps),
      packages = table.concat(packages, ", "),
      done = done == #p.steps,
      path = p,
    }
    widths[1] = math.max(widths[1], vim.fn.strdisplaywidth(row.title))
    widths[2] = math.max(widths[2], vim.fn.strdisplaywidth(row.changes))
    widths[3] = math.max(widths[3], vim.fn.strdisplaywidth(row.reach))
    table.insert(rows, row)
  end
  local function pad(text, width)
    return text .. string.rep(" ", width - vim.fn.strdisplaywidth(text))
  end
  for _, r in ipairs(rows) do
    local left = string.format("  %s  %s   ", r.number, pad(r.title, widths[1]))
    local text = left .. pad(r.changes, widths[2]) .. "   " .. pad(r.reach, widths[3]) .. "   " .. r.progress .. "   " .. r.packages
    add(text, { path = r.path }, {
      { "Number", 2, 3 },
      { "Comment", #left, #text - #r.packages - #r.progress - 3 },
      { r.done and "TrailAdd" or "Comment", #text - #r.packages - #r.progress - 3, #text - #r.packages - 3 },
      { "Comment", #text - #r.packages, -1 },
    })
  end
  if state.impact and #state.code == 0 then
    add("  (no changed functions)", nil, { { "Comment", 0, -1 } })
  end

  local not_reached = {}
  for _, p in ipairs(state.code) do
    vim.list_extend(not_reached, untested(p))
  end
  if #not_reached > 0 then
    add("")
    add("No test reaches", nil, { { "Title", 0, 15 } })
    local text = "  " .. table.concat(not_reached, " · ")
    add(text, nil, { { "Comment", 0, -1 } })
  end

  if #state.tests > 0 then
    add("")
    add("Test changes", nil, { { "Title", 0, 12 } })
    -- Go tests group by package (their folder); other languages list each file.
    local groups, order = {}, {}
    for _, t in ipairs(state.tests) do
      local dir = t.title:match("%.go$") and (vim.fs.dirname(t.title) .. "/") or ""
      if not groups[dir] then
        groups[dir] = {}
        table.insert(order, dir)
      end
      table.insert(groups[dir], t)
    end
    for _, dir in ipairs(order) do
      local indent = dir == "" and "     " or "       "
      if dir ~= "" then
        local header = "   " .. dir
        add(header .. "  " .. count(#groups[dir], "test file"), nil,
          { { "Directory", 3, #header }, { "Comment", #header, -1 } })
      end
      for _, t in ipairs(groups[dir]) do
        local name = dir == "" and t.title or t.title:sub(#dir + 1)
        local text = string.format("%s%s  %s · covers %s  · %d/%d", indent, name, count(#t.test.nodes, "test"),
          count(#t.test.covers, "function"), progress(t), #t.steps)
        add(text, { path = t }, { { "Comment", #indent + #name, -1 } })
      end
    end
  end

  if #state.loose.steps > 0 then
    add("")
    add("Not in any path", nil, { { "Title", 0, 15 } })
    -- One line per file, opening at its first hunk.
    local files, first, seen = {}, {}, {}
    for i, step in ipairs(state.loose.steps) do
      local file = step.hunk.file
      if not first[file] then
        first[file] = i
        table.insert(files, file)
        seen[file] = { hunks = 0, seen = 0 }
      end
      seen[file].hunks = seen[file].hunks + 1
      if store.seen(step.hunk.id) then
        seen[file].seen = seen[file].seen + 1
      end
    end
    for _, file in ipairs(files) do
      local n = seen[file]
      local text = (n.seen == n.hunks and "  ✓  " or "     ") .. file .. "  " .. count(n.hunks, "hunk")
      add(text, { path = state.loose, step = first[file] }, { { "Comment", 0, -1 } })
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
  if path and path.impact then
    local tree_lines, tree_hls = tree.render(path.impact, { done = M.done_steps(path) })
    local title = "── " .. path.title .. " "
    lines = { "", title .. string.rep("─", math.max(0, 60 - vim.fn.strdisplaywidth(title))) }
    vim.list_extend(lines, tree_lines)
    table.insert(hls, { 1, 0, -1, "Comment" })
    for _, h in ipairs(tree_hls) do
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
  state.code, state.tests, state.loose = build_paths(state.review, state.impact)
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

---Asks the engine for the impact paths in the background: the walk through
---callers and callees can take a while, so the screen shows meanwhile.
local function request_impact()
  local review = state.review
  state.impact_started = vim.uv.now()
  -- Redraw every second while waiting, so the time shows the walk is still going.
  local ticker = vim.uv.new_timer()
  ticker:start(1000, 1000, vim.schedule_wrap(function()
    if state.review ~= review or state.impact or state.impact_error then
      ticker:stop()
      ticker:close()
      return
    end
    M.refresh_home()
  end))
  engine.request("impact", { repo = state.repo, base = state.base, head = state.head, ignore = vim.g.trail_ignore, ignore_defaults = vim.g.trail_ignore_defaults ~= false }, function(err, result)
    if state.review ~= review then
      return
    end
    if err then
      state.impact_error = err.message
    else
      state.impact = result
    end
    M.refresh_home()
  end)
end

local function review_range()
  store.load(state.repo, state.key)
  -- Paths from before a reload must not be entered while the new ones are worked out.
  state.impact, state.impact_error = nil, nil
  M.refresh_home()
  engine.request("open", { repo = state.repo, base = state.base, head = state.head, ignore = vim.g.trail_ignore, ignore_defaults = vim.g.trail_ignore_defaults ~= false }, function(err, result)
    if err then
      vim.notify("trail: " .. err.message, vim.log.levels.ERROR)
      return
    end
    state.review = result
    state.impact, state.impact_error = nil, nil
    request_impact()
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
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  local name = "trail://" .. vim.fs.basename(root) .. "/" .. arg
  local earlier = vim.fn.bufnr(name)
  if earlier ~= -1 then
    vim.api.nvim_buf_delete(earlier, { force = true })
  end
  vim.api.nvim_buf_set_name(buf, name)
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
  map("mr", function()
    local item = state.items and state.items[vim.api.nvim_win_get_cursor(0)[1]]
    if item and item.path then
      toggle_reviewed(row_path(item))
    end
  end, "Mark the path as reviewed, or unmark it")
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
    vim.api.nvim_set_current_tabpage(state.list_tab)
    if #vim.api.nvim_list_tabpages() > 1 then
      vim.cmd("tabclose")
    end
    vim.api.nvim_buf_delete(buf, { force = true })
  end, "Quit trail")

  load()
end

return M
