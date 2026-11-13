local comments = require("trail.comments")
local help = require("trail.help")
local store = require("trail.state")

local M = {}

local ns = vim.api.nvim_create_namespace("trail.send")
local verdicts = { "approve", "request changes", "comment" }
local screen

local function render()
  local ctx = screen.ctx
  local lines, hls, items = {}, {}, {}
  local function add(text, hl, item)
    table.insert(lines, text)
    if hl then
      table.insert(hls, { #lines - 1, hl[1], hl[2], hl[3] })
    end
    items[#lines] = item
  end
  local title = "Review of " .. ctx.title
  add(title, { 0, #title, "Title" })
  local verdict = "Verdict: " .. (store.verdict() or "none")
  add(verdict .. "   (v changes it, y copies the review as markdown)", { 0, #verdict, store.verdict() and "Special" or "Comment" })
  local unseen = ctx.unseen()
  if #unseen > 0 then
    local text = string.format("! %d %s not seen yet: %s", #unseen, #unseen == 1 and "hunk" or "hunks", table.concat(unseen, ", "))
    add(text, { 0, 1, "WarningMsg" })
  end
  local order, groups = comments.by_file()
  if #order == 0 then
    add("")
    add("No comments yet. Add them in a diff with cb, cq or cn.", { 0, -1, "Comment" })
  end
  for _, file in ipairs(order) do
    add("")
    add(file, { 0, #file, "Directory" })
    for _, c in ipairs(groups[file]) do
      local where = c.side == "old" and string.format("-%d", c.line) or string.format("%d", c.line)
      local body = vim.split(c.body, "\n", { plain = true })
      local head = string.format("  %5s  %-8s  %s", where, c.kind, body[1])
      add(head, { 9, 9 + #c.kind, comments.highlight(c.kind) }, c)
      for i = 2, #body do
        add(string.rep(" ", 19) .. body[i], nil, c)
      end
      add(string.rep(" ", 19) .. "> " .. vim.trim(c.text), { 19, -1, "Comment" }, c)
    end
  end
  local buf = screen.buf
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, h in ipairs(hls) do
    vim.api.nvim_buf_set_extmark(buf, ns, h[1], h[2], { end_col = h[3] < 0 and #lines[h[1] + 1] or h[3], hl_group = h[4] })
  end
  screen.items = items
end

---Opens the send screen: comments grouped by file, a verdict, and a warning
---for hunks not seen yet.
---@param ctx { title: string, unseen: fun(): string[], jump: fun(comment: table), home: fun() }
function M.open(ctx)
  if screen and vim.api.nvim_buf_is_valid(screen.buf) and vim.fn.bufwinid(screen.buf) ~= -1 then
    vim.api.nvim_set_current_win(vim.fn.bufwinid(screen.buf))
  else
    vim.cmd("tabnew")
    local buf = vim.api.nvim_get_current_buf()
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.api.nvim_buf_set_name(buf, "trail://send")
    screen = { buf = buf }
    local function map(lhs, fn, desc)
      vim.keymap.set("n", lhs, fn, { buffer = buf, desc = desc, nowait = true })
    end
    map("v", function()
      local current = store.verdict()
      local next_verdict = verdicts[1]
      for i, v in ipairs(verdicts) do
        if v == current then
          next_verdict = verdicts[i + 1]
        end
      end
      store.set_verdict(next_verdict)
      render()
    end, "Change the verdict")
    map("y", function()
      local text = comments.markdown(screen.ctx.title)
      vim.fn.setreg('"', text)
      pcall(vim.fn.setreg, "+", text)
      vim.notify("trail: review copied as markdown", vim.log.levels.INFO)
    end, "Copy the review as markdown")
    map("<CR>", function()
      local c = screen.items[vim.api.nvim_win_get_cursor(0)[1]]
      if c then
        screen.ctx.jump(c)
      end
    end, "Go to the comment")
    map("d", function()
      local c = screen.items[vim.api.nvim_win_get_cursor(0)[1]]
      if c then
        for i, other in ipairs(store.comments()) do
          if other == c then
            table.remove(store.comments(), i)
            break
          end
        end
        store.save()
        render()
      end
    end, "Delete the comment")
    for _, key in ipairs({ "-", "q" }) do
      map(key, function()
        screen.ctx.home()
      end, "Back to the paths screen")
    end
    map("?", help.show, "Show keys")
  end
  screen.ctx = ctx
  render()
end

return M
