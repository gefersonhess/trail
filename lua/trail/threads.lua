local comments = require("trail.comments")
local help = require("trail.help")

local M = {}

local list = {}
local opened = {}
local ns = vim.api.nvim_create_namespace("trail.threads")
local screen

local function set_highlights()
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  local bg = normal.bg or (vim.o.background == "light" and 0xffffff or 0x0d1117)
  local fg = normal.fg or (vim.o.background == "light" and 0x24292f or 0xc9d1d9)
  local mixed = 0
  for shift = 0, 16, 8 do
    local x, y = bit.band(bit.rshift(fg, shift), 0xff), bit.band(bit.rshift(bg, shift), 0xff)
    mixed = mixed + bit.lshift(math.floor(x * 0.08 + y * 0.92 + 0.5), shift)
  end
  vim.api.nvim_set_hl(0, "TrailThreadBlock", { bg = mixed, default = true })
  vim.api.nvim_set_hl(0, "TrailThread", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "TrailThreadAuthor", { link = "Identifier", default = true })
  vim.api.nvim_set_hl(0, "TrailThreadResolved", { link = "TrailAddText", default = true })
end
set_highlights()
vim.api.nvim_create_autocmd("ColorScheme", { callback = set_highlights })

---Replaces the pull request's review threads, as the engine's
---`review_threads` returns them.
function M.set(threads)
  list = threads or {}
end

function M.all()
  return list
end

---Whether a thread has a line in the code shown, so it can be drawn there.
function M.placed(t)
  return not t.outdated and t.line ~= vim.NIL and t.line ~= nil
end

local function in_file(t, old_path, new_path)
  return M.placed(t) and (t.path == new_path or (t.side == "old" and t.path == old_path))
end

local function first_line(text)
  local kind, rest = comments.split_kind(text)
  local line = vim.split(rest:gsub("\r", ""), "\n", { plain = true })[1] or ""
  return (kind and kind .. ": " or "") .. line
end

---Virtual-line notes for the threads on the file shown.
function M.notes(old_path, new_path)
  local notes = {}
  for _, t in ipairs(list) do
    if in_file(t, old_path, new_path) then
      local rows = {}
      local block = "TrailThreadBlock"
      if t.resolved and not opened[t.id] then
        local first = t.comments[1] or { author = "?", body = "" }
        local more = #t.comments > 1 and string.format("  (%d comments)", #t.comments) or ""
        table.insert(rows, {
          { "✓ resolved", "TrailThreadResolved" },
          { " · " .. first.author .. ": " .. first_line(first.body) .. more .. "  <CR> opens", "TrailThread" },
        })
      else
        if t.resolved then
          table.insert(rows, { { "✓ resolved", "TrailThreadResolved" }, { "  <CR> folds", "TrailThread" } })
        end
        for i, c in ipairs(t.comments) do
          if i > 1 then
            table.insert(rows, { { "", "TrailThread" } })
          end
          table.insert(rows, {
            { c.author, "TrailThreadAuthor" },
            { " · " .. (c.created_at or ""):sub(1, 10), "TrailThread" },
          })
          local kind, rest = comments.split_kind(c.body)
          for k, body_line in ipairs(comments.wrap(rest)) do
            if k == 1 and kind then
              table.insert(rows, { { "  ", "Normal" }, { kind, comments.highlight(kind) }, { "  " .. body_line, "Normal" } })
            else
              table.insert(rows, { { (kind and string.rep(" ", #kind + 2) or "") .. "  " .. body_line, "Normal" } })
            end
          end
        end
      end
      local width = 0
      for _, row in ipairs(rows) do
        local w = 0
        for _, chunk in ipairs(row) do
          w = w + vim.fn.strdisplaywidth(chunk[1])
        end
        row.width = w
        width = math.max(width, w)
      end
      local virt = {}
      for _, row in ipairs(rows) do
        local line = { { "┃ ", { "TrailThread", block } } }
        for _, chunk in ipairs(row) do
          table.insert(line, { chunk[1], { chunk[2], block } })
        end
        table.insert(line, { string.rep(" ", width - row.width + 2), block })
        table.insert(virt, line)
      end
      table.insert(notes, { side = t.side, line = t.line, lines = virt })
    end
  end
  return notes
end

---The thread on a line of the file shown, if any.
function M.at(old_path, new_path, side, line)
  for _, t in ipairs(list) do
    if in_file(t, old_path, new_path) and t.side == side and t.line == line then
      return t
    end
  end
end

---Opens or folds the resolved thread on a line; returns whether there was one.
function M.toggle_at(old_path, new_path, side, line)
  for _, t in ipairs(list) do
    if t.resolved and in_file(t, old_path, new_path) and t.side == side and t.line == line then
      opened[t.id] = not opened[t.id] or nil
      return true
    end
  end
  return false
end

local function render()
  local ctx = screen.ctx
  local lines, hls, items = {}, {}, {}
  local function add(text, item, hl)
    table.insert(lines, text)
    items[#lines] = item
    for _, h in ipairs(hl or {}) do
      table.insert(hls, { #lines - 1, h[2], h[3], h[1] })
    end
  end
  local title = "Review threads of " .. ctx.title
  add(title, nil, { { "Title", 0, #title } })
  add("<CR> goes to a thread  ·  r replies  ·  ]t [t move between threads inside a path  ·  - back", nil, { { "Comment", 0, -1 } })
  local by_file, order = {}, {}
  for _, t in ipairs(list) do
    if not by_file[t.path] then
      by_file[t.path] = {}
      table.insert(order, t.path)
    end
    table.insert(by_file[t.path], t)
  end
  table.sort(order)
  if #order == 0 then
    add("")
    add("No review threads on this pull request.", nil, { { "Comment", 0, -1 } })
  end
  for _, path in ipairs(order) do
    add("")
    add(path, nil, { { "Directory", 0, -1 } })
    local threads = by_file[path]
    local function at(t)
      return M.placed(t) and t.line or (t.original_line ~= vim.NIL and t.original_line or 0)
    end
    table.sort(threads, function(a, b)
      return at(a) < at(b)
    end)
    for _, t in ipairs(threads) do
      local first = t.comments[1] or { author = "?", body = "" }
      local where = (M.placed(t) and "" or "~") .. tostring(at(t))
      local mark = t.outdated and "outdated" or (t.resolved and "✓" or "●")
      local head = string.format("  %6s  %s  %s", where, mark .. string.rep(" ", 8 - vim.fn.strdisplaywidth(mark)), first.author)
      local text = head .. "  " .. first_line(first.body)
        .. (#t.comments > 1 and string.format("  · %d comments", #t.comments) or "")
      local mark_hl = t.outdated and "WarningMsg" or (t.resolved and "TrailThreadResolved" or "TrailThreadAuthor")
      add(text, t, { { mark_hl, 10, 10 + #mark }, { "TrailThreadAuthor", #head - #first.author, #head } })
      if t.outdated and t.diff_hunk ~= "" then
        local hunk = vim.split(t.diff_hunk, "\n", { plain = true })
        for i = math.max(2, #hunk - 2), #hunk do
          add(string.rep(" ", 20) .. hunk[i], t, { { "Comment", 0, -1 } })
        end
      end
    end
  end
  vim.bo[screen.buf].modifiable = true
  vim.api.nvim_buf_set_lines(screen.buf, 0, -1, false, lines)
  vim.bo[screen.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(screen.buf, ns, 0, -1)
  for _, h in ipairs(hls) do
    vim.api.nvim_buf_set_extmark(screen.buf, ns, h[1], h[2], {
      end_col = h[3] == -1 and #lines[h[1] + 1] or math.min(h[3], #lines[h[1] + 1]),
      hl_group = h[4],
    })
  end
  screen.items = items
end

---Opens the list of every review thread, outdated ones included.
---@param ctx { title: string, window: fun(): integer, home: fun(), jump: fun(thread: table), reply: fun(thread: table) }
function M.open_list(ctx)
  if not (screen and vim.api.nvim_buf_is_valid(screen.buf)) then
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.api.nvim_buf_set_name(buf, "trail://threads")
    screen = { buf = buf }
    local function map(lhs, fn, desc)
      vim.keymap.set("n", lhs, fn, { buffer = buf, desc = desc, nowait = true })
    end
    map("<CR>", function()
      local t = screen.items[vim.api.nvim_win_get_cursor(0)[1]]
      if not t then
        return
      end
      if not M.placed(t) then
        vim.notify("trail: this thread is outdated, its code has changed since: " .. (t.comments[1] or {}).url, vim.log.levels.INFO)
        return
      end
      screen.ctx.jump(t)
    end, "Go to the thread")
    map("r", function()
      local t = screen.items[vim.api.nvim_win_get_cursor(0)[1]]
      if t then
        screen.ctx.reply(t)
      end
    end, "Reply to the thread, or resolve or reopen it")
    map("-", function()
      screen.ctx.home()
    end, "Back to the paths screen")
    map("q", function()
      screen.ctx.home()
    end, "Back to the paths screen")
    map("?", help.show, "Show keys")
  end
  screen.ctx = ctx
  vim.api.nvim_win_set_buf(ctx.window(), screen.buf)
  render()
end

return M
