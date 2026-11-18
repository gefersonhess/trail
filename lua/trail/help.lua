local M = {}

local digits = {}
for n = 1, 9 do
  table.insert(digits, { tostring(n), "enter path" })
end

local back = { { "-", "back to paths" }, { "q", "back to paths" } }

---Each screen's keys in groups, with short labels. Keys sharing a group and
---a label are shown together (`]s [s  step`). Only keys mapped on the
---screen are shown; one mapped but missing here still shows, under Other.
local screens = {
  home = {
    { "Open", vim.list_extend({ { "<CR>", "open the line" }, { "gp", "switch path" } }, digits) },
    { "Review", { { "mr", "mark path" }, { "S", "send screen" }, { "T", "threads" } } },
    { "Screen", { { "R", "refresh" }, { "q", "quit" } } },
  },
  tree = {
    { "Move", vim.list_extend({
      { "n", "step" }, { "p", "step" }, { "]c", "change" }, { "[c", "change" },
      { "]t", "thread" }, { "[t", "thread" }, { "gp", "switch path" },
    }, back) },
    { "Tree", { { "<CR>", "open" }, { "a", "every function" }, { "c", "fold back" }, { "K", "peek function" } } },
    { "Review", { { "mr", "mark path" } } },
  },
  diff = {
    { "Move", vim.list_extend({
      { "]s", "step" }, { "[s", "step" }, { "]c", "change" }, { "[c", "change" },
      { "]h", "hunk" }, { "[h", "hunk" }, { "]t", "thread" }, { "[t", "thread" }, { "gp", "switch path" },
    }, back) },
    { "Review", {
      { "cc", "comment" }, { "cb", "as kind" }, { "cq", "as kind" }, { "cn", "as kind" },
      { "ce", "edit / delete" }, { "cd", "edit / delete" }, { "r", "reply to thread" },
      { "mh", "mark hunk" }, { "mr", "mark path" },
    } },
    { "View", {
      { "t", "side by side" }, { "o", "whole file" }, { "K", "peek function" }, { "gd", "open in Neovim" },
      { "<CR>", "open resolved thread" },
    } },
  },
  send = {
    { "Review", { { "v", "verdict" }, { "P", "submit to GitHub" }, { "y", "copy markdown" } } },
    { "Comments", { { "<CR>", "go to comment" }, { "d", "delete" } } },
    { "Screen", back },
  },
  threads = {
    { "Threads", { { "<CR>", "go to thread" }, { "r", "reply" } } },
    { "Screen", back },
  },
}

local function screen_of(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name:match("^trail://diff/") then
    return screens.diff
  elseif name:match("^trail://path$") then
    return screens.tree
  elseif name:match("^trail://send$") then
    return screens.send
  elseif name:match("^trail://threads$") then
    return screens.threads
  end
  return screens.home
end

---"1 2 3 4 5 6 7 8 9" reads as "1-9".
local function join(keys)
  if #keys > 2 and vim.iter(keys):all(function(k)
    return k:match("^%d$")
  end) then
    return keys[1] .. "-" .. keys[#keys]
  end
  return table.concat(keys, " ")
end

---The groups of entries ({ keys, label }) to show for a buffer.
function M.groups(buf)
  local mapped = {}
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    mapped[map.lhs] = map.desc or ""
  end
  mapped["?"] = nil
  local known, groups = {}, {}
  for _, group in ipairs(screen_of(buf)) do
    local entries, by_label = {}, {}
    for _, key in ipairs(group[2]) do
      local lhs, label = key[1], key[2]
      if mapped[lhs] then
        known[lhs] = true
        if by_label[label] then
          table.insert(by_label[label].keys, lhs)
        else
          by_label[label] = { keys = { lhs }, label = label }
          table.insert(entries, by_label[label])
        end
      end
    end
    if #entries > 0 then
      table.insert(groups, { name = group[1], entries = entries })
    end
  end
  local other = {}
  for lhs, desc in pairs(mapped) do
    if not known[lhs] and desc ~= "" then
      table.insert(other, { keys = { lhs }, label = desc })
    end
  end
  table.sort(other, function(a, b)
    return a.keys[1] < b.keys[1]
  end)
  if #other > 0 then
    table.insert(groups, { name = "Other", entries = other })
  end
  for _, group in ipairs(groups) do
    for _, e in ipairs(group.entries) do
      e.text = join(e.keys)
    end
  end
  return groups
end

function M.show()
  local groups = M.groups(vim.api.nvim_get_current_buf())
  local key_width, label_width = 0, 0
  for _, group in ipairs(groups) do
    for _, e in ipairs(group.entries) do
      key_width = math.max(key_width, vim.fn.strdisplaywidth(e.text))
      label_width = math.max(label_width, vim.fn.strdisplaywidth(e.label))
    end
  end
  local cell = key_width + 2 + label_width
  local columns = 2 * cell + 3 + 4 <= vim.o.columns - 4 and 2 or 1
  local function pad(text, width)
    return text .. string.rep(" ", width - vim.fn.strdisplaywidth(text))
  end

  local lines, hls = {}, {}
  for g, group in ipairs(groups) do
    if g > 1 then
      table.insert(lines, "")
    end
    table.insert(lines, " " .. group.name)
    table.insert(hls, { #lines - 1, 1, 1 + #group.name, "Title" })
    for i = 1, #group.entries, columns do
      local line = "   "
      for c = 0, columns - 1 do
        local e = group.entries[i + c]
        if e then
          if c > 0 then
            line = line .. "   "
          end
          local start = #line
          local text = pad(e.text, key_width) .. "  " .. (c < columns - 1 and group.entries[i + c + 1] and pad(e.label, label_width) or e.label)
          line = line .. text
          table.insert(hls, { #lines, start, start + #e.text, "Special" })
        end
      end
      table.insert(lines, line .. " ")
    end
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
  for _, h in ipairs(hls) do
    vim.api.nvim_buf_set_extmark(buf, ns, h[1], h[2], { end_col = h[3], hl_group = h[4] })
  end
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width + 1,
    height = #lines,
    row = math.max(0, math.floor((vim.o.lines - #lines) / 2) - 1),
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
