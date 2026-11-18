local compose = require("trail.compose")
local store = require("trail.state")

local M = {}

M.kinds = { "blocking", "question", "nit" }
local kind_hl = { blocking = "TrailBlocking", question = "TrailQuestion", nit = "TrailNit" }
vim.api.nvim_set_hl(0, "TrailBlocking", { link = "DiagnosticError", default = true })
vim.api.nvim_set_hl(0, "TrailQuestion", { link = "DiagnosticInfo", default = true })
vim.api.nvim_set_hl(0, "TrailNit", { link = "Comment", default = true })

function M.highlight(kind)
  return kind_hl[kind] or "Comment"
end

local function blend(a, b, t)
  local out = 0
  for shift = 0, 16, 8 do
    local x, y = bit.band(bit.rshift(a, shift), 0xff), bit.band(bit.rshift(b, shift), 0xff)
    out = out + bit.lshift(math.floor(x * t + y * (1 - t) + 0.5), shift)
  end
  return out
end

---A faint background in each kind's colour, behind a saved comment.
local function set_block_highlights()
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  local bg = normal.bg or (vim.o.background == "light" and 0xffffff or 0x0d1117)
  for _, hl in pairs(kind_hl) do
    local fg = vim.api.nvim_get_hl(0, { name = hl, link = false }).fg or normal.fg or 0x888888
    vim.api.nvim_set_hl(0, hl .. "Block", { bg = blend(fg, bg, 0.14), default = true })
  end
end
set_block_highlights()
vim.api.nvim_create_autocmd("ColorScheme", { callback = set_block_highlights })

function M.block_highlight(kind)
  return M.highlight(kind) .. "Block"
end

local WRAP = 80

---A comment's text as lines to draw: without the carriage returns GitHub
---sends, and wrapped at word boundaries to WRAP columns.
function M.wrap(text)
  local out = {}
  for _, paragraph in ipairs(vim.split(text:gsub("\r", ""), "\n", { plain = true })) do
    local line = ""
    for word in paragraph:gmatch("%S+") do
      if line ~= "" and vim.fn.strdisplaywidth(line .. " " .. word) > WRAP then
        table.insert(out, line)
        line = word
      else
        line = line == "" and word or line .. " " .. word
      end
    end
    local indent = paragraph:match("^%s*")
    table.insert(out, (line ~= "" and indent or "") .. line)
  end
  return out
end

---Splits the `**nit:** ` prefix trail puts on comments it submits: the kind
---(nil when there is none) and the rest of the text.
function M.split_kind(body)
  local kind, rest = body:match("^%*%*(%a+):%*%*%s*(.*)$")
  if kind and vim.tbl_contains(M.kinds, kind) then
    return kind, rest
  end
  return nil, body
end

---The kind `cc` starts with: `vim.g.trail_default_comment_kind`, or blocking.
function M.default_kind()
  local wanted = vim.g.trail_default_comment_kind
  return vim.tbl_contains(M.kinds, wanted) and wanted or M.kinds[1]
end

local function file_of(side, old_path, new_path)
  return side == "old" and (old_path or new_path) or (new_path or old_path)
end

---Where a comment's line is now: its saved line if the text still matches,
---otherwise the nearest line with the same text, otherwise nil (outdated).
function M.anchor(comment, lines)
  if lines[comment.line] == comment.text then
    return comment.line
  end
  local best
  for i, l in ipairs(lines) do
    if l == comment.text and (not best or math.abs(i - comment.line) < math.abs(best - comment.line)) then
      best = i
    end
  end
  return best
end

---How many lines a comment covers beyond its first.
local function span(comment)
  return comment.last and comment.last - comment.line or 0
end

---"12", or "12-15" for a comment on several lines.
function M.where(comment)
  return comment.last and string.format("%d-%d", comment.line, comment.last) or tostring(comment.line)
end

local function in_file(comment, old_path, new_path)
  return comment.file == file_of(comment.side, old_path, new_path)
end

---Virtual-line notes for the comments on the file shown in `view`.
function M.notes(view, old_path, new_path)
  local notes, moved = {}, false
  for _, c in ipairs(store.comments()) do
    if in_file(c, old_path, new_path) then
      local line = M.anchor(c, view.lines(c.side))
      if line and line ~= c.line then
        if c.last then
          c.last = line + span(c)
        end
        c.line = line
        moved = true
      end
      if line then
        local virt = {}
        local label = c.kind .. (c.last and string.format(" %d-%d", c.line, c.last) or "")
        local hl, block = M.highlight(c.kind), M.block_highlight(c.kind)
        local body = M.wrap(c.body)
        local width = 0
        for _, body_line in ipairs(body) do
          width = math.max(width, vim.fn.strdisplaywidth(body_line))
        end
        for i, body_line in ipairs(body) do
          local pad = string.rep(" ", width - vim.fn.strdisplaywidth(body_line) + 2)
          table.insert(virt, {
            { "▎ ", { hl, block } },
            { i == 1 and label or string.rep(" ", #label), { hl, block } },
            { "  " .. body_line .. pad, { "Normal", block } },
          })
        end
        table.insert(notes, { side = c.side, line = line + span(c), lines = virt })
      end
    end
  end
  if moved then
    store.save()
  end
  return notes
end

local function at_cursor(view, old_path, new_path)
  local here = view.line_at_cursor()
  if not here then
    return nil
  end
  for i, c in ipairs(store.comments()) do
    local anchored = in_file(c, old_path, new_path) and c.side == here.side and M.anchor(c, view.lines(c.side))
    if anchored and here.line >= anchored and here.line <= anchored + span(c) then
      return c, i, here
    end
  end
  return nil, nil, here
end

function M.add(kind, view, old_path, new_path, on_change)
  local mode = vim.fn.mode()
  local visual = mode == "v" or mode == "V" or mode == "\22"
  local here = visual and view.selection() or view.line_at_cursor()
  if visual then
    vim.cmd.normal({ args = { "\27" }, bang = true })
  end
  if not here then
    vim.notify("trail: no code line under the cursor", vim.log.levels.INFO)
    return
  end
  compose.open({ kind = kind, kinds = M.kinds, highlight = M.highlight }, function(body, picked)
    if body == "" then
      return
    end
    kind = picked
    table.insert(store.comments(), {
      id = tostring(vim.uv.hrtime()),
      kind = kind,
      body = body,
      file = file_of(here.side, old_path, new_path),
      side = here.side,
      line = here.line,
      last = here.last and here.last > here.line and here.last or nil,
      text = here.text,
    })
    store.save()
    on_change()
  end)
end

function M.edit(view, old_path, new_path, on_change)
  local comment = at_cursor(view, old_path, new_path)
  if not comment then
    vim.notify("trail: no comment on this line", vim.log.levels.INFO)
    return
  end
  local opts = { kind = comment.kind, kinds = M.kinds, highlight = M.highlight, body = comment.body }
  compose.open(opts, function(body, picked)
    if body == "" then
      return M.delete(view, old_path, new_path, on_change)
    end
    comment.body = body
    comment.kind = picked
    store.save()
    on_change()
  end)
end

function M.delete(view, old_path, new_path, on_change)
  local comment, index = at_cursor(view, old_path, new_path)
  if not comment then
    vim.notify("trail: no comment on this line", vim.log.levels.INFO)
    return
  end
  table.remove(store.comments(), index)
  store.save()
  on_change()
end

---Comments grouped by file, in file order then line order.
function M.by_file()
  local groups, order = {}, {}
  for _, c in ipairs(store.comments()) do
    if not groups[c.file] then
      groups[c.file] = {}
      table.insert(order, c.file)
    end
    table.insert(groups[c.file], c)
  end
  table.sort(order)
  for _, file in ipairs(order) do
    table.sort(groups[file], function(a, b)
      return a.line < b.line
    end)
  end
  return order, groups
end

function M.markdown(title)
  local out = { "## Review of " .. title, "" }
  if store.verdict() then
    vim.list_extend(out, { "**Verdict:** " .. store.verdict(), "" })
  end
  local order, groups = M.by_file()
  for _, file in ipairs(order) do
    vim.list_extend(out, { "### " .. file, "" })
    for _, c in ipairs(groups[file]) do
      local lines = c.last and "lines" or "line"
      local where = (c.side == "old" and "removed " or "") .. lines .. " " .. M.where(c)
      local body = vim.split(c.body, "\n", { plain = true })
      table.insert(out, string.format("- **%s** (%s): %s", c.kind, where, body[1]))
      for i = 2, #body do
        table.insert(out, "  " .. body[i])
      end
      table.insert(out, "  > `" .. vim.trim(c.text) .. "`")
    end
    table.insert(out, "")
  end
  if #order == 0 then
    vim.list_extend(out, { "No comments.", "" })
  end
  return table.concat(out, "\n")
end

return M
