---The trail app's first screen when no review is named: the open pull
---requests, numbered, those asking for your review first.
local M = {}

local ns = vim.api.nvim_create_namespace("trail_pulls")

local function draw(buf, lines, hls)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, h in ipairs(hls or {}) do
    local stop = h[3] >= 0 and h[3] or #lines[h[1] + 1]
    vim.api.nvim_buf_set_extmark(buf, ns, h[1], h[2], { end_col = stop, hl_group = h[4] })
  end
end

---Shows the screen in the current window and lists the pull requests with
---`list(cb)`, where `cb(err, prs)`. `on_pick(number)` opens the one chosen
---with a number key or <CR>. A number typed while listing picks once listed.
function M.show(list, on_pick)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.b[buf].trail_screen = "pulls"
  vim.api.nvim_win_set_buf(0, buf)
  local prs, wanted, rows = nil, nil, {}
  draw(buf, { "", " Listing open pull requests…" }, { { 1, 0, -1, "Comment" } })

  local function pick(n)
    if not prs then
      wanted = n
    elseif prs[n] then
      on_pick(prs[n].number)
    end
  end
  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true })
  end
  for n = 1, 9 do
    map(tostring(n), function()
      pick(n)
    end)
  end
  map("<CR>", function()
    local n = rows[vim.api.nvim_win_get_cursor(0)[1]]
    if n then
      pick(n)
    end
  end)
  map("q", function()
    vim.cmd("qa")
  end)
  map("?", require("trail.help").show)

  list(function(err, found)
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    if err then
      draw(buf, { "", " Couldn't list the pull requests:", " " .. err.message, "", " Run trail '#123' or trail main..feature instead." },
        { { 1, 0, -1, "ErrorMsg" } })
      return
    end
    prs = found
    if #prs == 0 then
      draw(buf, { "", " No open pull requests.", "", " Run trail main..feature to review a branch." }, { { 1, 0, -1, "Comment" } })
      return
    end
    local lines, hls = { "", " Open pull requests", "" }, { { 1, 0, -1, "Title" } }
    local width = 0
    for _, pr in ipairs(prs) do
      width = math.max(width, vim.fn.strdisplaywidth(pr.title))
    end
    for i, pr in ipairs(prs) do
      local key = i <= 9 and tostring(i) or " "
      local head = string.format(" %s  #%-5d %s", key, pr.number, pr.title)
      head = head .. string.rep(" ", width - vim.fn.strdisplaywidth(pr.title) + 3)
      local meta = pr.author .. " · " .. pr.head_ref_name .. (pr.is_draft and " · draft" or "")
        .. (pr.review_requested and " · review requested" or "")
      table.insert(lines, head .. meta)
      rows[#lines] = i
      table.insert(hls, { #lines - 1, 1, 2, "Number" })
      table.insert(hls, { #lines - 1, #head, -1, "Comment" })
    end
    draw(buf, lines, hls)
    local win = vim.fn.bufwinid(buf)
    if win ~= -1 then
      vim.api.nvim_win_set_cursor(win, { 4, 0 })
    end
    if wanted then
      pick(wanted)
    end
  end)
end

return M
