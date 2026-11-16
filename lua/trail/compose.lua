local M = {}

local WIDTH, HEIGHT = 64, 6

---Opens a floating box under the cursor to write a comment in. `<C-s>` saves,
---`<Tab>` (`<C-t>` while typing) cycles the kind, `q` or `<Esc>` in normal mode
---cancels. `on_confirm` gets the text, possibly empty, and the kind chosen.
---@param opts { kind: string, kinds: string[], highlight: fun(kind: string): string, body?: string }
---@param on_confirm fun(body: string, kind: string)
function M.open(opts, on_confirm)
  local kind = opts.kind
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local lines = opts.body and vim.split(opts.body, "\n", { plain = true }) or { "" }
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local function title()
    return { { " " .. kind .. " ", opts.highlight(kind) } }
  end
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = math.min(WIDTH, vim.o.columns - 4),
    height = HEIGHT,
    style = "minimal",
    border = "rounded",
    title = title(),
    title_pos = "left",
    footer = " <C-s> save  <Tab> kind  q cancel ",
    footer_pos = "left",
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  local function submit()
    local body = vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
    vim.cmd.stopinsert()
    close()
    on_confirm(body, kind)
  end
  local function cycle()
    for i, k in ipairs(opts.kinds) do
      if k == kind then
        kind = opts.kinds[i % #opts.kinds + 1]
        break
      end
    end
    vim.api.nvim_win_set_config(win, { title = title() })
  end
  local function cancel()
    vim.cmd.stopinsert()
    close()
  end
  vim.keymap.set({ "n", "i" }, "<C-s>", submit, { buffer = buf })
  vim.keymap.set("n", "<Tab>", cycle, { buffer = buf })
  vim.keymap.set("i", "<C-t>", cycle, { buffer = buf })
  vim.keymap.set("n", "q", cancel, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Esc>", cancel, { buffer = buf, nowait = true })
  vim.api.nvim_create_autocmd("WinLeave", { buffer = buf, once = true, callback = close })

  vim.api.nvim_win_set_cursor(win, { #lines, #lines[#lines] })
  vim.cmd.startinsert({ bang = true })
end

return M
