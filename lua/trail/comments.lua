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
        c.line = line
        moved = true
      end
      if line then
        local virt = {}
        for i, body_line in ipairs(vim.split(c.body, "\n", { plain = true })) do
          local hl = M.highlight(c.kind)
          table.insert(virt, {
            { "▎ ", hl },
            { i == 1 and c.kind or string.rep(" ", #c.kind), hl },
            { "  " .. body_line, "Normal" },
          })
        end
        table.insert(notes, { side = c.side, line = line, lines = virt })
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
    if in_file(c, old_path, new_path) and c.side == here.side and M.anchor(c, view.lines(c.side)) == here.line then
      return c, i, here
    end
  end
  return nil, nil, here
end

function M.add(kind, view, old_path, new_path, on_change)
  local here = view.line_at_cursor()
  if not here then
    vim.notify("trail: no code line under the cursor", vim.log.levels.INFO)
    return
  end
  vim.ui.input({ prompt = kind .. ": " }, function(body)
    if not body or body == "" then
      return
    end
    table.insert(store.comments(), {
      id = tostring(vim.uv.hrtime()),
      kind = kind,
      body = body,
      file = file_of(here.side, old_path, new_path),
      side = here.side,
      line = here.line,
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
  vim.ui.input({ prompt = comment.kind .. ": ", default = comment.body }, function(body)
    if not body then
      return
    end
    if body == "" then
      return M.delete(view, old_path, new_path, on_change)
    end
    comment.body = body
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
      local where = c.side == "old" and string.format("removed line %d", c.line) or string.format("line %d", c.line)
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
