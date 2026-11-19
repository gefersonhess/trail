local engine = require("trail.engine")
local diffview = require("trail.diffview")
local help = require("trail.help")
local peek = require("trail.peek")
local tree = require("trail.tree")
local pane = require("trail.pane")
local pathview = require("trail.pathview")
local store = require("trail.state")
local calls = require("trail.calls")
local commits = require("trail.commits")
local comments = require("trail.comments")
local compose = require("trail.compose")
local send = require("trail.send")
local threads = require("trail.threads")

local M = {}

local ns = vim.api.nvim_create_namespace("trail")
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
---A thread's line as a target the diff can open at.
local function thread_target(t)
  return {
    file = t.path,
    old = { start = t.line, len = t.side == "old" and 1 or 0 },
    new = { start = t.line, len = t.side == "new" and 1 or 0 },
  }
end

---Whether a thread's line falls in a step's function or hunk.
local function step_has(step, t)
  local target = step.node or step.hunk
  local range = target and (t.side == "old" and target.old or target.new)
  return range ~= nil and target.file == t.path and t.line >= range.start and t.line < range.start + math.max(range.len, 1)
end

---The threads of a path's steps, in step order and then line order.
local function path_threads(path)
  local out, listed = {}, {}
  for i, step in ipairs(path.steps) do
    local here = {}
    for _, t in ipairs(threads.all()) do
      if threads.placed(t) and not listed[t.id] and step_has(step, t) then
        listed[t.id] = true
        table.insert(here, t)
      end
    end
    table.sort(here, function(a, b)
      return a.line < b.line
    end)
    for _, t in ipairs(here) do
      table.insert(out, { step = i, thread = t })
    end
  end
  return out
end

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
---Where a hunk starts on screen: its first removed line, or its first added one.
local function hunk_start(h)
  if h.old.len > 0 then
    return "old", math.max(h.old.start, 1)
  end
  return "new", math.max(h.new.start, 1)
end

---Redraws everything that shows which hunks are seen.
local function seen_changed()
  pathview.refresh_graph()
  M.refresh_home()
  if state.shown then
    state.shown.view.redraw_marks()
  end
end

---Marks hunks as seen, or clears them when they all are already. Hunks
---cleared by hand are not marked again by scrolling until they have left
---the screen.
---@return boolean whether they were marked
local function toggle_seen(ids)
  state.unmarked = state.unmarked or {}
  local reviewed = vim.iter(ids):all(store.seen)
  for _, id in ipairs(ids) do
    state.unmarked[id] = reviewed or nil
  end
  if reviewed then
    store.unmark_seen(ids)
  else
    store.mark_seen(ids)
  end
  seen_changed()
  return not reviewed
end

local reply_to, load_threads, comments_changed, poster

local function arrange()
  if not vim.g.trail_app then
    return
  end
  pane.arrange()
end

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
        local notes = comments.notes(current, params.old_path, params.new_path)
        vim.list_extend(notes, threads.notes(params.old_path, params.new_path))
        local path = pathview.current()
        if path and params.new_path then
          vim.list_extend(notes, calls.notes(path, params.new_path, current))
        end
        current.annotate(notes)
      end
    end
    local function changed()
      annotate()
      M.refresh_home()
    end
    local all_keys = vim.list_extend({}, keys or {})
    for _, kind in ipairs(comments.kinds) do
      local function add()
        comments.add(kind, current, params.old_path, params.new_path, changed, poster())
      end
      table.insert(all_keys, { "c" .. kind:sub(1, 1), add, "Add a " .. kind .. " comment on this line" })
      table.insert(all_keys, { "c" .. kind:sub(1, 1), add, "Add a " .. kind .. " comment on the selected lines", "x" })
    end
    local function add_default()
      comments.add(comments.default_kind(), current, params.old_path, params.new_path, changed, poster())
    end
    table.insert(all_keys, { "]]", function()
      calls.follow(current, params.new_path)
    end, "Follow the call on this line into the function it calls" })
    table.insert(all_keys, { "[[", function()
      calls.back(current, params.new_path)
    end, "Go back to the call followed, or up to this function's caller" })
    table.insert(all_keys, { "r", function()
      local here = current and current.line_at_cursor()
      local t = here and threads.at(params.old_path, params.new_path, here.side, here.line)
      if t then
        reply_to(t)
      else
        vim.notify("trail: no review thread on this line", vim.log.levels.INFO)
      end
    end, "Reply to the review thread on this line, or resolve or reopen it" })
    table.insert(all_keys, { "<CR>", function()
      local here = current and current.line_at_cursor()
      local t = here and threads.at(params.old_path, params.new_path, here.side, here.line)
      if t then
        threads.show(t, reply_to)
      end
    end, "Open the review thread on this line" })
    table.insert(all_keys, { "cc", add_default, "Add a comment on this line (kind from vim.g.trail_default_comment_kind)" })
    table.insert(all_keys, { "cc", add_default, "Add a comment on the selected lines", "x" })
    table.insert(all_keys, { "ce", function()
      comments.edit(current, params.old_path, params.new_path, changed, poster())
    end, "Edit the comment on this line" })
    table.insert(all_keys, { "cd", function()
      comments.delete(current, params.old_path, params.new_path, changed)
    end, "Delete the comment on this line" })
    -- A changed function, as a step shows it: the rest of its file is dimmed.
    local focus = target.focus or (is_node and target.hunks and (target.old or target.new)
      and { old = target.old, new = target.new }) or nil
    local view = diffview.show(diff, {
      focus = focus,
      win = win,
      keys = all_keys,
      on_redraw = function(again)
        arrange()
        current = again
        state.shown = { view = again, file = target.file, old_path = params.old_path, new_path = params.new_path }
        annotate()
      end,
      hunks = vim.tbl_filter(function(h)
        return h.file == target.file
      end, review.hunks),
      is_seen = store.seen,
      on_seen = function(ids)
        if quiet then
          return
        end
        -- A hunk unmarked by hand stays unmarked until it has left the screen.
        local unmarked, on_screen = state.unmarked or {}, {}
        for _, id in ipairs(ids) do
          on_screen[id] = true
        end
        for id in pairs(unmarked) do
          if not on_screen[id] then
            unmarked[id] = nil
          end
        end
        if vim.g.trail_seen_on_scroll == false then
          return
        end
        ids = vim.tbl_filter(function(id)
          return not unmarked[id]
        end, ids)
        if store.mark_seen(ids) then
          seen_changed()
        end
      end,
      on_toggle_seen = function(ids)
        toggle_seen(ids)
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
    arrange()
    current = view
    state.shown = { view = view, file = target.file, old_path = params.old_path, new_path = params.new_path }
    state.reannotate = annotate
    annotate()
    if target.at_start then
      view.focus(hunk_start(target))
    else
      local on_new = target.new and (is_node or target.new.len > 0)
      view.focus(on_new and "new" or "old", math.max((on_new and target.new or target.old).start, 1))
    end
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
  local short = node.short
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
    hunks_of = function(step)
      local by_id = {}
      for _, h in ipairs(state.review.hunks) do
        by_id[h.id] = h
      end
      local hunks = step.node and vim.tbl_map(function(id)
        return by_id[id]
      end, step.node.hunks) or { step.hunk }
      table.sort(hunks, function(a, b)
        return a.new.start < b.new.start or (a.new.start == b.new.start and a.old.start < b.old.start)
      end)
      return hunks
    end,
    ---The next hunk of `hunks` after the cursor (or before it, for dir < 0),
    ---when the diff shown is their file; `false` when another file is shown.
    ---The next thread of the path after the cursor (dir 1) or before it
    ---(dir -1): its step, a target at its line, and whether it is in the
    ---diff shown now.
    next_thread = function(path, step, dir)
      local shown = state.shown
      local cursor = shown and shown.view.cursor_row()
      local function position(item)
        if item.step ~= step then
          return item.step < step and -1 or 1
        end
        if not (shown and shown.file == item.thread.path) then
          return dir
        end
        local row = shown.view.row_of(item.thread.side, item.thread.line)
        return row == cursor and 0 or (row < cursor and -1 or 1)
      end
      local items = path_threads(path)
      local first, last = 1, #items
      if dir < 0 then
        first, last = last, first
      end
      for k = first, last, dir do
        local item = items[k]
        if position(item) == dir then
          local t = item.thread
          local here = item.step == step and shown ~= nil and shown.file == t.path
          return { step = item.step, target = thread_target(t), here = here, side = t.side, line = t.line }
        end
      end
    end,
    focus_line = function(side, line)
      state.shown.view.focus(side, line)
    end,
    next_hunk = function(hunks, dir)
      local shown = state.shown
      if not shown or #hunks == 0 or shown.file ~= hunks[1].file then
        return false
      end
      local cursor = shown.view.cursor_row()
      local first, last = 1, #hunks
      if dir < 0 then
        first, last = last, first
      end
      for k = first, last, dir do
        local row = shown.view.row_of(hunk_start(hunks[k]))
        if (dir > 0 and row > cursor) or (dir < 0 and row < cursor) then
          return hunks[k]
        end
      end
    end,
    focus_hunk = function(h)
      state.shown.view.focus(hunk_start(h))
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
  local marked = toggle_seen(ids)
  vim.notify(string.format("trail: %s %s", marked and "marked as reviewed:" or "unmarked", path.title), vim.log.levels.INFO)
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

local function enter(path, step, target)
  if #path.steps == 0 then
    return
  end
  pathview.open(path_context(), path, step or store.position(path.id) or 1, target)
end

---Posts a reply to a review thread and resolves or reopens it, either or both.
local function update_thread(t, body, change, done)
  local replying = state
  engine.request("update_thread", {
    repo = state.repo,
    url = state.pr_url,
    number = state.pr,
    thread = t.id,
    body = body,
    state = change,
  }, function(err)
    if err then
      vim.notify("trail: " .. err.message, vim.log.levels.ERROR)
      return
    end
    local did = body ~= "" and (change and "replied and " .. change .. "d" or "replied") or change .. "d"
    vim.notify(string.format("trail: %s the thread on %s:%d", did, t.path, t.line ~= vim.NIL and t.line or t.original_line), vim.log.levels.INFO)
    if done then
      done()
    end
    if state == replying then
      load_threads()
    end
  end)
end

---Posts a comment to the pull request at once, outside the review: a reply
---to its thread, or a comment on its own line. A new comment GitHub refuses
---is kept for the review instead, so its text is not lost.
local function post_now(c, done)
  if c.reply_to then
    return update_thread({ id = c.reply_to, path = c.file, line = c.line }, c.body, nil, done)
  end
  local posting = state
  engine.request("post_comment", {
    repo = state.repo,
    url = state.pr_url,
    number = state.pr,
    commit = state.full_head or state.review.head_commit,
    base = state.base,
    comment = { path = c.file, side = c.side, line = c.line, last = c.last, text = c.text,
      body = string.format("**%s:** %s", c.kind, c.body) },
  }, function(err, posted)
    if state ~= posting then
      return
    end
    if err then
      if not vim.tbl_contains(store.comments(), c) then
        table.insert(store.comments(), c)
        store.save()
        comments_changed()
      end
      vim.notify("trail: " .. err.message .. " (kept for the review)", vim.log.levels.WARN)
      return
    end
    vim.notify("trail: posted: " .. posted.url, vim.log.levels.INFO)
    if done then
      done()
    end
    load_threads()
  end)
end

---What `<C-y>` posts with in the comment box: only on a pull request.
poster = function()
  return state.pr and post_now or nil
end

---In the trail app, a reply is written now and sent with the review's other
---comments; its line's text is kept to find the line again. `<C-y>` posts it at once.
local function draft_reply(t)
  compose.open({ kind = "reply", kinds = { "reply" }, highlight = function()
    return "TrailThreadAuthor"
  end, on_now = state.pr and function(body)
    update_thread(t, body, nil)
  end or nil }, function(body)
    if body == "" then
      return
    end
    local shown = state.shown
    local text = shown and shown.new_path == t.path and shown.view.lines(t.side)[t.line] or ""
    table.insert(store.comments(), {
      id = tostring(vim.uv.hrtime()),
      kind = "reply",
      reply_to = t.id,
      body = body,
      file = t.path,
      side = t.side,
      line = t.line ~= vim.NIL and t.line or t.original_line,
      text = text,
    })
    store.save()
    comments_changed()
  end)
end

---Replies to a review thread, or resolves or reopens it, in the comment box:
---<Tab> picks the action, and any text written is posted as a reply.
reply_to = function(t)
  if vim.g.trail_app then
    return draft_reply(t)
  end
  local kinds = t.resolved and { "reply", "reopen" } or { "reply", "resolve" }
  compose.open({
    kind = "reply",
    kinds = kinds,
    highlight = function(action)
      return action == "resolve" and "TrailAddText" or action == "reopen" and "WarningMsg" or "TrailThreadAuthor"
    end,
    footer = " <C-s> post to GitHub  <Tab> " .. kinds[2] .. " too  q cancel ",
  }, function(body, action)
    local change = action ~= "reply" and action or nil
    if body == "" and not change then
      return
    end
    update_thread(t, body, change)
  end)
end

local function open_threads()
  threads.open_list({
    reply = reply_to,
    title = state.title,
    window = review_window,
    home = home,
    jump = function(t)
      for _, path in ipairs(all_paths()) do
        for i, step in ipairs(path.steps) do
          if step_has(step, t) then
            return enter(path, i, thread_target(t))
          end
        end
      end
      vim.notify("trail: that thread is not on a path step", vim.log.levels.INFO)
    end,
  })
end

---Reads the pull request's review threads, and redraws what shows them.
load_threads = function()
  if not state.pr_url then
    return
  end
  local loading = state
  engine.request("review_threads", { repo = state.repo, url = state.pr_url, number = state.pr }, function(err, list)
    if state ~= loading then
      return
    end
    if err then
      vim.notify("trail: could not read the pull request's threads: " .. err.message, vim.log.levels.WARN)
      return
    end
    threads.set(list)
    -- A comment sent before trail handed sent comments over to GitHub is
    -- still here; once its thread is read, the thread stands for it.
    local all, dropped = store.comments(), false
    local function clean(text)
      return vim.trim((text:gsub("\r", "")))
    end
    for k = #all, 1, -1 do
      local c = all[k]
      local posted = c.sent and string.format("**%s:** %s", c.kind, clean(c.body))
      if posted and vim.iter(list):any(function(t)
        return t.path == c.file and vim.iter(t.comments):any(function(tc)
          return clean(tc.body) == posted
        end)
      end) then
        table.remove(all, k)
        dropped = true
      end
    end
    if dropped then
      store.save()
    end
    if state.reannotate then
      state.reannotate()
    end
    M.refresh_home()
  end)
end

local verdict_events = { comment = "COMMENT", approve = "APPROVE", ["request changes"] = "REQUEST_CHANGES" }

---Submits the review to the pull request: an overall comment and verdict
---written in the comment box, and every comment not sent before.
local function submit_review(done)
  local verdicts = { "comment", "approve", "request changes", "draft" }
  local start = vim.tbl_contains(verdicts, store.verdict()) and store.verdict() or "comment"
  local function highlight(verdict)
    return verdict == "approve" and "TrailAdd" or verdict == "request changes" and "TrailDelete" or "Title"
  end
  compose.open({
    kind = start,
    kinds = verdicts,
    highlight = highlight,
    footer = " <C-s> submit to GitHub  <Tab> verdict  q cancel ",
  }, function(body, verdict)
    local pending = vim.tbl_filter(function(c)
      return comments.selected(c) and not c.reply_to
    end, store.comments())
    local replies = vim.tbl_filter(function(c)
      return comments.selected(c) and c.reply_to ~= nil
    end, store.comments())
    local list = vim.tbl_map(function(c)
      return { path = c.file, side = c.side, line = c.line, last = c.last, text = c.text,
        body = string.format("**%s:** %s", c.kind, c.body) }
    end, pending)
    local commit = state.full_head or state.review.head_commit
    local submitting = state
    vim.notify("trail: submitting the review…", vim.log.levels.INFO)
    engine.request("submit_review", {
      repo = state.repo,
      url = state.pr_url,
      number = state.pr,
      commit = commit,
      base = state.base,
      event = verdict_events[verdict],
      body = body,
      comments = list,
    }, function(err, result)
      if err then
        vim.notify("trail: " .. err.message, vim.log.levels.ERROR)
        return
      end
      if state ~= submitting then
        -- Another review was opened meanwhile; its state must not record this one.
        vim.notify("trail: review submitted: " .. result.url, vim.log.levels.INFO)
        return
      end
      -- A comment posted inline is a GitHub thread from now on; one that went
      -- into the overall comment stays here, marked sent.
      local inline = {}
      for _, index in ipairs(result.inline_comments or {}) do
        inline[pending[index + 1]] = true
      end
      local all = store.comments()
      for k = #all, 1, -1 do
        if inline[all[k]] then
          table.remove(all, k)
        end
      end
      for _, c in ipairs(pending) do
        c.sent = true
      end
      if verdict ~= "draft" then
        store.set_verdict(verdict)
      end
      store.set_submitted({ commit = commit, url = result.url, verdict = verdict })
      load_threads()
      -- Replies go to their threads one by one, each the thread's once posted.
      local function post_reply(k)
        local c = replies[k]
        if not c or state ~= submitting then
          return
        end
        update_thread({ id = c.reply_to, path = c.file, line = c.line }, c.body, nil, function()
          local all = store.comments()
          for j = #all, 1, -1 do
            if all[j] == c then
              table.remove(all, j)
            end
          end
          store.save()
          comments_changed()
          post_reply(k + 1)
        end)
      end
      post_reply(1)
      vim.notify(string.format("trail: %s submitted, %d inline, %d in the overall comment: %s",
        verdict == "draft" and "pending review" or "review", result.inline, result.in_body, result.url), vim.log.levels.INFO)
      done()
    end)
  end)
end

comments_changed = function()
  if state.reannotate then
    state.reannotate()
  end
  M.refresh_home()
  threads.refresh()
  vim.cmd("redrawtabline")
end

local function open_send()
  send.open({
    title = state.title,
    submit = state.pr and submit_review or nil,
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

threads.hooks({
  reply = function(t)
    reply_to(t)
  end,
  resolve = function(t)
    update_thread(t, "", t.resolved and "reopen" or "resolve")
  end,
  send = function()
    if state.pr then
      submit_review(function() end)
    else
      open_send()
    end
  end,
  changed = function()
    comments_changed()
  end,
  poster = function()
    return poster()
  end,
})

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

local function bar(done, total, width)
  local filled = total > 0 and math.floor(done / total * width + 0.5) or 0
  return string.rep("█", filled), string.rep("░", width - filled)
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
  local open = state.open or {}
  state.open = open
  local function fold(key, label, n)
    local text = (open[key] and "▾ " or "▸ ") .. label .. (n and string.format(" (%d)", n) or "")
    add(text, { fold = key }, { { "Title", 0, #text - (n and #tostring(n) + 3 or 0) }, { "Comment", #text - (n and #tostring(n) + 3 or 0), -1 } })
    return open[key]
  end
  -- Folded sections sit together; an open one is set apart.
  local function gap()
    if not (lines[#lines] or ""):match("^▸ ") then
      add("")
    end
  end

  local pr = state.pr_info
  if pr then
    local title = string.format("#%d %s", pr.number, pr.title)
    local by = string.format(" · %s → %s", pr.author, pr.base_branch)
    add(title .. by, nil, { { "Title", 0, #title }, { "Comment", #title, -1 } })
  else
    add(state.title, nil, { { "Title", 0, -1 } })
  end
  if state.range then
    local only = "Reviewing " .. state.range.label .. "  ·  C to change"
    add(only, nil, { { "WarningMsg", 0, #("Reviewing " .. state.range.label) }, { "Comment", #("Reviewing " .. state.range.label), -1 } })
  end
  local seen = 0
  for _, h in ipairs(review.hunks) do
    if store.seen(h.id) then
      seen = seen + 1
    end
  end
  local filled, empty = bar(seen, #review.hunks, 20)
  local status = ""
  if pr then
    local submitted = store.submitted()
    status = submitted and " · submitted at " .. submitted.commit:sub(1, 7) or " · not submitted"
  end
  local progress_line = string.format("%s%s  %d/%d hunks%s", filled, empty, seen, #review.hunks, status)
  add(progress_line, nil, { { "TrailAddText", 0, #filled }, { "Comment", #filled, -1 } })

  if pr and pr.description and vim.trim(pr.description) ~= "" then
    add("")
    if fold("description", "Description") then
      for _, l in ipairs(vim.split(vim.trim(pr.description):gsub("\r", ""), "\n", { plain = true })) do
        add("  " .. l)
      end
    end
  end

  local not_reached = {}
  for _, p in ipairs(state.code) do
    vim.list_extend(not_reached, untested(p))
  end
  local unresolved = #vim.tbl_filter(function(t)
    return not t.resolved
  end, threads.all())
  local blocking = #vim.tbl_filter(function(c)
    return c.kind == "blocking" and not c.sent
  end, store.comments())
  if unresolved + blocking + #not_reached > 0 then
    add("")
    add("Needs attention", nil, { { "Title", 0, -1 } })
    if unresolved > 0 then
      local text = "  ● " .. count(unresolved, "unresolved thread")
      add(text, { attention = "threads" }, { { "TrailThreadAuthor", 2, 5 } })
    end
    if blocking > 0 then
      local text = "  ● " .. count(blocking, "blocking comment")
      add(text, { attention = "blocking" }, { { "TrailBlocking", 2, 5 } })
    end
    if #not_reached > 0 then
      local text = "  ! " .. count(#not_reached, "untested change")
      add(text, { fold = "untested" }, { { "WarningMsg", 2, 3 } })
      if open.untested then
        for _, name in ipairs(not_reached) do
          add("      " .. name, { fold = "untested" }, { { "Comment", 0, -1 } })
        end
      end
    end
  end

  add("")
  add("Paths", nil, { { "Title", 0, 5 } })
  if state.impact_error then
    add("  The impact could not be worked out: " .. state.impact_error, nil, { { "WarningMsg", 0, -1 } })
  elseif not state.impact then
    local waited = state.impact_started and math.floor((vim.uv.now() - state.impact_started) / 1000) or 0
    add(string.format("  Working out the paths… %ds  (engine log: %s)", waited,
      vim.fn.fnamemodify(engine.log_path, ":~")), nil, { { "Comment", 0, -1 } })
  elseif #state.code == 0 then
    add("  (no changed functions)", nil, { { "Comment", 0, -1 } })
  end
  local width = 0
  for _, p in ipairs(state.code) do
    width = math.max(width, vim.fn.strdisplaywidth(p.title))
  end
  for i, p in ipairs(state.code) do
    local done = progress(p)
    local f, e = bar(done, #p.steps, 10)
    local left = string.format("  %s  %s", i <= 9 and tostring(i) or " ", p.title .. string.rep(" ", width - vim.fn.strdisplaywidth(p.title)))
    local text = left .. "  " .. f .. e
    local bar_start = #left + 2
    text = text .. string.format("  %d/%d", done, #p.steps) .. (done == #p.steps and " ✓" or "")
    local n = #path_threads(p)
    if n > 0 then
      text = text .. "  " .. count(n, "thread")
    end
    add(text, { path = p }, {
      { "Number", 2, 3 },
      { "TrailAddText", bar_start, bar_start + #f },
      { "Comment", bar_start + #f, -1 },
    })
  end

  if #state.tests > 0 then
    gap()
    if fold("tests", "Tests", #state.tests) then
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
        local indent = dir == "" and "    " or "      "
        if dir ~= "" then
          add("    " .. dir, nil, { { "Directory", 4, -1 } })
        end
        for _, t in ipairs(groups[dir]) do
          local name = dir == "" and t.title or t.title:sub(#dir + 1)
          local text = string.format("%s%s  covers %s  %d/%d", indent, name, count(#t.test.covers, "function"), progress(t), #t.steps)
          add(text, { path = t }, { { "Comment", #indent + #name, -1 } })
        end
      end
    end
  end

  if #state.loose.steps > 0 then
    gap()
    if fold("loose", "Not in any path", #state.loose.steps) then
      -- One line per file, opening at its first hunk.
      local files, first, tally = {}, {}, {}
      for i, step in ipairs(state.loose.steps) do
        local file = step.hunk.file
        if not first[file] then
          first[file] = i
          table.insert(files, file)
          tally[file] = { hunks = 0, seen = 0 }
        end
        tally[file].hunks = tally[file].hunks + 1
        if store.seen(step.hunk.id) then
          tally[file].seen = tally[file].seen + 1
        end
      end
      for _, file in ipairs(files) do
        local n = tally[file]
        local text = "    " .. file .. "  " .. count(n.hunks, "hunk") .. (n.seen == n.hunks and " ✓" or "")
        add(text, { path = state.loose, step = first[file] }, { { "Comment", 4 + #file, -1 } })
      end
    end
  end

  if review.ignored and #review.ignored > 0 then
    gap()
    if fold("hidden", "Hidden", #review.ignored) then
      for _, file in ipairs(review.ignored) do
        add("    " .. file, nil, { { "Comment", 0, -1 } })
      end
    end
  end

  add("")
  add("? keys", nil, { { "Comment", 0, -1 } })
  return lines, items, hls
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
---The range the review shows: all of it, or the commits picked on the Commits screen.
local function range()
  if state.range then
    return state.range.base, state.range.head
  end
  return state.base, state.head
end

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
  local base, head = range()
  engine.request("impact", {
    repo = state.repo,
    base = base,
    head = head,
    lsp = vim.g.trail_lsp ~= false,
    ignore = vim.g.trail_ignore,
    ignore_defaults = vim.g.trail_ignore_defaults ~= false,
  }, function(err, result)
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

---Replaces the loading text with what failed, so the tab doesn't look stuck.
local function show_failure(message)
  vim.notify("trail: " .. message, vim.log.levels.ERROR)
  local buf = state.list_buf
  if state.review or not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  local lines = { "trail: could not open " .. state.title, "" }
  vim.list_extend(lines, vim.split(message, "\n", { plain = true }))
  vim.list_extend(lines, { "", "R tries again  ·  q closes" })
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

local function review_range()
  store.load(state.repo, state.key)
  -- Paths from before a reload must not be entered while the new ones are worked out.
  state.impact, state.impact_error = nil, nil
  M.refresh_home()
  -- An answer for a review the user has since left must not land in the new one.
  local opening = state
  local base, head = range()
  engine.request("open", { repo = state.repo, base = base, head = head, ignore = vim.g.trail_ignore, ignore_defaults = vim.g.trail_ignore_defaults ~= false }, function(err, result)
    if state ~= opening then
      return
    end
    if err then
      return show_failure(err.message)
    end
    state.review = result
    -- Comments are posted against the whole review's head, even from a narrower range.
    if not state.range then
      state.full_head = result.head_commit
    end
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
  local loading = state
  engine.request("pull_request", { repo = state.repo, number = state.pr }, function(err, pr)
    if state ~= loading then
      return
    end
    if err then
      return show_failure(err.message)
    end
    state.base, state.head = pr.base, pr.head
    state.pr_url = pr.url
    state.pr_info = pr
    state.title = string.format("#%d %s", pr.number, pr.title)
    review_range()
    load_threads()
  end)
end

---Lists the repository's open pull requests, those asking for your review
---first, and opens the one picked.
local function pick_pull_request(root)
  if vim.g.trail_app then
    return require("trail.pulls").show(function(cb)
      engine.request("pull_requests", { repo = root }, cb)
    end, function(number)
      M.open("#" .. number)
    end)
  end
  vim.notify("trail: listing open pull requests…", vim.log.levels.INFO)
  engine.request("pull_requests", { repo = root }, function(err, list)
    if err then
      vim.notify("trail: " .. err.message, vim.log.levels.ERROR)
      return
    end
    if #list == 0 then
      vim.notify("trail: no open pull requests", vim.log.levels.INFO)
      return
    end
    vim.ui.select(list, {
      prompt = "Pull request to review",
      format_item = function(pr)
        return string.format("#%d  %s  · %s · %s%s%s", pr.number, pr.title, pr.author, pr.head_ref_name,
          pr.is_draft and " · draft" or "", pr.review_requested and " · review requested" or "")
      end,
    }, function(choice)
      if choice then
        M.open("#" .. choice.number)
      end
    end)
  end)
end

---The Commits screen: picking one commit or a run of them reloads the review
---on just those; all of them widens it back. Comments and marks stay.
local function open_commits()
  commits.open({
    title = state.title,
    window = review_window,
    home = home,
    list = function(cb)
      engine.request("commits", { repo = state.repo, base = state.base, head = state.head }, cb)
    end,
    picked = function()
      return state.range
    end,
    pick = function(list, first, last)
      if first and not (first == 1 and last == #list) then
        state.range = { base = list[first].id .. "^", head = list[last].id, first = first, last = last,
          label = commits.label(first, last, #list) }
      else
        state.range = nil
      end
      home()
      load()
    end,
  })
end

function M.open(arg)
  arg = vim.trim(arg or "")
  local root = vim.fs.root(0, ".git") or vim.fn.getcwd()
  if arg == "" then
    return pick_pull_request(root)
  end
  state = { repo = root }
  commits.reset()
  threads.set({})
  local pr = arg:match("^#(%d+)$") or arg:match("^https?://%S+/pull/(%d+)/?%S*$")
  if pr then
    state.pr = tonumber(pr)
    state.key = "pr-" .. pr
    state.title = "#" .. pr
  else
    state.base, state.head = parse_range(arg)
    state.key = state.base .. ".." .. state.head
    state.title = state.key
  end

  vim.cmd("tabnew")
  state.list_tab = vim.api.nvim_get_current_tabpage()
  if vim.g.trail_app then
    -- The app shows one review: the empty tab it started in, or the review
    -- opened before this one, goes.
    vim.cmd("silent! tabonly")
  end
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
    if not item then
      return
    elseif item.fold then
      state.open[item.fold] = not state.open[item.fold] or nil
      M.refresh_home()
    elseif item.attention == "threads" then
      open_threads()
    elseif item.attention == "blocking" then
      open_send()
    elseif item.path then
      enter(item.path, item.step)
    end
  end, "Enter the path, or open the line")
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
  map("T", function()
    if not state.pr then
      vim.notify("trail: review threads come from a pull request (:Trail #123)", vim.log.levels.INFO)
      return
    end
    open_threads()
  end, "Review threads of the pull request")
  map("C", open_commits, "Commits: review one or some of them")
  map("R", load, "Refresh")
  map("?", help.show, "Show keys")
  map("q", function()
    if vim.g.trail_app then
      vim.cmd("qa")
      return
    end
    vim.api.nvim_set_current_tabpage(state.list_tab)
    if #vim.api.nvim_list_tabpages() > 1 then
      vim.cmd("tabclose")
    end
    vim.api.nvim_buf_delete(buf, { force = true })
  end, "Quit trail")

  load()
end

local modes = { n = "NORMAL", i = "INSERT", v = "VISUAL", V = "V-LINE", ["\22"] = "V-BLOCK", c = "COMMAND", R = "REPLACE", t = "TERMINAL" }

local function escape(text)
  return (text:gsub("%%", "%%%%"))
end

---The trail app's tabline: the screens, the current one marked, and inside a
---path its step and progress.
function M.tabline()
  if help.screen(vim.api.nvim_get_current_buf()) == "pulls" then
    return "%#TrailTabBrand# trail %#TabLineSel# Pull requests %#TabLineFill#"
  end
  local path, step = pathview.current()
  local screen = "home"
  if path then
    screen = "path"
  elseif state.list_tab and vim.api.nvim_tabpage_is_valid(state.list_tab) then
    screen = help.screen(vim.api.nvim_win_get_buf(vim.api.nvim_tabpage_get_win(state.list_tab)))
  end
  local tabs = {
    { "Overview", screen == "home" },
    { path and path.title or "Paths", screen == "path" },
    { "Commits", screen == "commits" },
  }
  if state.pr then
    local open = #vim.tbl_filter(function(t)
      return not t.resolved
    end, threads.all())
    table.insert(tabs, { "Threads" .. (open > 0 and " " .. open or ""), screen == "threads" })
  end
  local to_send = state.review and #comments.to_send() or 0
  table.insert(tabs, { "Send" .. (to_send > 0 and " " .. to_send or ""), screen == "send" })
  local out = "%#TrailTabBrand# trail "
  for _, tab in ipairs(tabs) do
    out = out .. (tab[2] and "%#TabLineSel#" or "%#TabLine#") .. " " .. escape(tab[1]) .. " "
  end
  out = out .. "%#TabLineFill#%="
  if path then
    local done = progress(path)
    local filled = math.floor(done / math.max(#path.steps, 1) * 10 + 0.5)
    out = out .. string.format("%%#TabLine# step %d/%d  %%#TrailAddText#%s%%#TabLine#%s %d/%d ", step, #path.steps,
      string.rep("█", filled), string.rep("░", 10 - filled), done, #path.steps)
  elseif state.title then
    out = out .. "%#TabLine# " .. escape(state.title .. (state.range and " · " .. state.range.label or "")) .. " "
  end
  return out
end

---The trail app's status line: the mode, where the cursor is, and the
---screen's main keys.
function M.statusline()
  local mode = modes[vim.api.nvim_get_mode().mode:sub(1, 1)] or "NORMAL"
  local buf = vim.api.nvim_get_current_buf()
  local screen = help.screen(buf)
  local where = ({
    pulls = "pull requests",
    commits = "commits",
    home = "overview",
    tree = "path",
    send = "send",
    threads = "threads",
    comment = "comment",
    thread = "thread",
  })[screen] or vim.api.nvim_buf_get_name(buf):gsub("^trail://%a+/", "")
  -- %< cuts the key hints first when the window is narrow.
  return "%#TrailMode" .. mode:gsub("-", "") .. "# " .. mode .. " %#StatusLine# " .. escape(where)
    .. "%=%<" .. escape(help.hints(buf) or "") .. " "
end

---In the trail app the thread pane follows the cursor onto the next thread.
function M.follow_thread()
  local shown = state.shown
  if not (threads.pane_open() and not pane.held() and shown and help.screen(0) == "diff") then
    return
  end
  local here = shown.view.line_at_cursor()
  if here then
    threads.show_line(shown.old_path, shown.new_path, here.side, here.line)
  end
end

return M
