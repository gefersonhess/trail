---Picks one of a list, narrowed by fuzzy matching as you type. The plugin
---hands the list to `vim.ui.select`, so a picker plugin the user has takes
---over; the trail app loads none, so it draws its own.
local M = {}

local ns = vim.api.nvim_create_namespace("trail.finder")

local function float(items, opts, on_choice)
  local texts = vim.tbl_map(opts.format, items)
  local width = math.min(vim.o.columns - 4, math.max(40, unpack(vim.tbl_map(vim.fn.strdisplaywidth, texts)) + 4))
  local height = math.min(#items, math.max(1, math.floor(vim.o.lines / 3)))
  local col = math.floor((vim.o.columns - width) / 2)
  local row = math.max(1, math.floor(vim.o.lines / 5))

  local list_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[list_buf].bufhidden = "wipe"
  local list_win = vim.api.nvim_open_win(list_buf, false, {
    relative = "editor", row = row + 3, col = col, width = width, height = height,
    style = "minimal", border = "rounded", focusable = false,
    footer = " j k move  ⏎ pick  i search  q close ", footer_pos = "right",
  })
  local input_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[input_buf].bufhidden = "wipe"
  local input_win = vim.api.nvim_open_win(input_buf, true, {
    relative = "editor", row = row, col = col, width = width, height = 1,
    style = "minimal", border = "rounded", title = " " .. opts.prompt .. " ", title_pos = "left",
  })

  local shown, selected = {}, 1
  for i, item in ipairs(items) do
    if item == opts.current then
      selected = i
    end
  end
  local function draw()
    local lines = {}
    for i, k in ipairs(shown) do
      lines[i] = " " .. texts[k]
    end
    vim.api.nvim_buf_set_lines(list_buf, 0, -1, false, #lines > 0 and lines or { " no match" })
    vim.api.nvim_buf_clear_namespace(list_buf, ns, 0, -1)
    if #shown == 0 then
      vim.api.nvim_buf_set_extmark(list_buf, ns, 0, 0, { end_col = 9, hl_group = "Comment" })
      return
    end
    vim.api.nvim_buf_set_extmark(list_buf, ns, selected - 1, 0, { line_hl_group = "TrailCurrentStep" })
    vim.api.nvim_win_set_cursor(list_win, { selected, 0 })
  end
  local query
  local function filter()
    query = vim.api.nvim_get_current_line()
    shown = {}
    if query == "" then
      for i = 1, #items do
        shown[i] = i
      end
    else
      local entries = {}
      for i, text in ipairs(texts) do
        entries[i] = { text = text, index = i }
      end
      for _, e in ipairs(vim.fn.matchfuzzy(entries, query, { key = "text" })) do
        table.insert(shown, e.index)
      end
      selected = 1
    end
    selected = math.max(1, math.min(selected, #shown))
    draw()
  end

  local closed = false
  local function close(choice)
    if closed then
      return
    end
    closed = true
    vim.cmd.stopinsert()
    pcall(vim.api.nvim_win_close, input_win, true)
    pcall(vim.api.nvim_win_close, list_win, true)
    vim.schedule(function()
      on_choice(choice)
    end)
  end
  local function key(modes, lhs, fn)
    vim.keymap.set(modes, lhs, fn, { buffer = input_buf, nowait = true })
  end
  local function move(delta)
    return function()
      if #shown > 0 then
        selected = (selected - 1 + delta) % #shown + 1
        draw()
      end
    end
  end
  local function to(index)
    return function()
      if #shown > 0 then
        selected = index < 0 and #shown or index
        draw()
      end
    end
  end
  local function pick()
    if vim.api.nvim_get_current_line() ~= query then
      filter()
    end
    close(shown[selected] and items[shown[selected]] or nil)
  end
  local function cancel()
    close(nil)
  end
  local function typing()
    vim.cmd.startinsert({ bang = true })
  end
  key({ "i", "n" }, "<CR>", pick)
  key({ "i", "n" }, "<C-c>", cancel)
  key({ "i", "n" }, "<C-n>", move(1))
  key({ "i", "n" }, "<Down>", move(1))
  key({ "i", "n" }, "<C-p>", move(-1))
  key({ "i", "n" }, "<Up>", move(-1))
  key("i", "<Esc>", function()
    vim.cmd.stopinsert()
  end)
  key("n", "<Esc>", cancel)
  key("n", "q", cancel)
  key("n", "j", move(1))
  key("n", "k", move(-1))
  key("n", "gg", to(1))
  key("n", "G", to(-1))
  for _, lhs in ipairs({ "i", "a", "I", "A", "/" }) do
    key("n", lhs, typing)
  end
  vim.api.nvim_create_autocmd("TextChangedI", { buffer = input_buf, callback = filter })
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = input_buf,
    once = true,
    callback = function()
      close(nil)
    end,
  })
  filter()
  vim.cmd.startinsert()
end

---Calls `on_choice` with the item picked from `items`, or nil.
---In the app the list opens typing; `<Esc>` goes to Normal mode, where `j`/`k`
---move, `<CR>` picks and `q` or `<Esc>` closes.
---@param opts { prompt: string, format: fun(item): string, current: any }
function M.pick(items, opts, on_choice)
  if #items == 0 then
    return
  end
  if vim.g.trail_app then
    return float(items, opts, on_choice)
  end
  vim.ui.select(items, { prompt = opts.prompt, format_item = opts.format }, function(choice)
    on_choice(choice)
  end)
end

return M
