local M = {}

local function special_first(a, b)
  local sa, sb = a:sub(1, 1) == "<", b:sub(1, 1) == "<"
  if sa ~= sb then
    return sa
  end
  return a:lower() < b:lower()
end

---Lists the buffer's own normal-mode mappings, merging keys that share a description.
local function entries(buf)
  local by_desc, order = {}, {}
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if map.desc then
      if not by_desc[map.desc] then
        by_desc[map.desc] = {}
        table.insert(order, map.desc)
      end
      table.insert(by_desc[map.desc], map.lhs)
    end
  end
  local rows = {}
  for _, desc in ipairs(order) do
    local keys = by_desc[desc]
    table.sort(keys, special_first)
    table.insert(rows, { keys = table.concat(keys, " "), desc = desc })
  end
  table.sort(rows, function(a, b)
    return special_first(a.keys, b.keys)
  end)
  return rows
end

function M.show()
  local source = vim.api.nvim_get_current_buf()
  local rows = entries(source)
  local key_width = 0
  for _, r in ipairs(rows) do
    key_width = math.max(key_width, vim.fn.strdisplaywidth(r.keys))
  end
  local lines = {}
  for _, r in ipairs(rows) do
    table.insert(lines, string.format(" %-" .. key_width .. "s   %s ", r.keys, r.desc))
  end
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  local ns = vim.api.nvim_create_namespace("trail.help")
  for i = 1, #lines do
    vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 1, { end_col = 1 + key_width, hl_group = "Special" })
  end
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = #lines,
    row = math.floor((vim.o.lines - #lines) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " keys ",
    title_pos = "center",
  })
  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  for _, key in ipairs({ "q", "<Esc>", "?" }) do
    vim.keymap.set("n", key, close, { buffer = buf, nowait = true })
  end
  vim.api.nvim_create_autocmd("WinLeave", { buffer = buf, once = true, callback = close })
end

return M
