-- Run from the repo root: nvim --headless -u NONE -l test/plugin.lua
local root = vim.fn.getcwd()
vim.opt.rtp:prepend(root)
vim.cmd.runtime("plugin/trail.lua")
vim.cmd("filetype on")

local failures = 0
local function check(cond, msg)
  if not cond then
    failures = failures + 1
    io.stderr:write("FAIL: " .. msg .. "\n")
  end
end

local repo = vim.fn.tempname()
vim.fn.mkdir(repo, "p")
local function sh(cmd)
  local out = vim.system({ "sh", "-c", cmd }, { cwd = repo, text = true }):wait()
  assert(out.code == 0, cmd .. ": " .. out.stderr)
end
local function write(path, content)
  vim.fn.mkdir(vim.fs.dirname(repo .. "/" .. path), "p")
  vim.fn.writefile(vim.split(content, "\n"), repo .. "/" .. path)
end

sh("git init -q -b main && git config user.email t@t && git config user.name t")
write("auth/auth.go", "package auth\n\nimport \"fmt\"\n\nfunc Login(u string) bool {\n\tGone()\n\treturn VerifyHash(u)\n}\n\nfunc VerifyHash(h string) bool {\n\treturn h != \"\"\n}\n\nfunc Gone() {}\n\nfunc p1() {}\nfunc p2() {}\nfunc p3() {}\nfunc p4() {}\nfunc p5() {}\nfunc p6() {}\nfunc p7() {}\nfunc p8() {}\nfunc p9() {}\nfunc p10() {}\n\nfunc Tidy() { x() }\n\nfunc Squash() {\n\ty()\n}")
sh("git add -A && git commit -qm base && git checkout -qb feature")
write("auth/auth.go", "package auth\n\nimport (\n\t\"fmt\"\n\t\"strings\"\n)\n\nfunc Login(user string) bool {\n\treturn VerifyHash(user)\n}\n\nfunc VerifyHash(h string) bool {\n\treturn hashOf(h) == h\n}\n\nfunc hashOf(h string) string { return strings.ToLower(h) }\n\nfunc p1() {}\nfunc p2() {}\nfunc p3() {}\nfunc p4() {}\nfunc p5() {}\nfunc p6() {}\nfunc p7() {}\nfunc p8() {}\nfunc p9() {}\nfunc p10() {}\n\nfunc Tidy() {\n\tx()\n}\n\nfunc Squash() { y() }")
write("auth/auth_test.go", "package auth\n\nfunc TestLogin(t *testing.T) {\n\tLogin(\"x\")\n}")
sh("git add -A && git commit -qm feature")
sh("git checkout -q main")
local cache = repo .. "-cache"
vim.env.XDG_CACHE_HOME = cache

vim.cmd.cd(repo)
vim.cmd("Trail main..feature")
local buf = vim.api.nvim_get_current_buf()
local loaded = vim.wait(10000, function()
  return vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]:match("^trail  main%.%.feature") ~= nil
end)
check(loaded, "list never loaded: " .. table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))

local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
print(table.concat(lines, "\n"))
local text = table.concat(lines, "\n")
local function line_of(pattern)
  for i, l in ipairs(lines) do
    if l:match(pattern) then
      return i
    end
  end
end

check(line_of("^1 path · 5 functions · 1 test file · 1 hunk not in any path · 0 comments$"), "summary line")
check(line_of("^  1  auth%.Login  4 steps  · 0/4$"), "path listed with its step count and progress")
check(line_of("^     auth/auth_test%.go  1 test · covers 3 functions  · 0/1$"), "test file listed with what it covers")
check(line_of("^     auth/auth%.go:3%-6$"), "import hunk listed as not in any path")
check(not text:match("no test change covers"), "every changed function is covered by the test")
check(line_of("^── auth%.Login") and line_of("^  ~ auth%.Login  ") and line_of("^  ├─ ~ auth%.VerifyHash")
  and line_of("^  │  └─ %+ auth%.hashOf .*%(new call%)") and line_of("^  └─ %- auth%.Gone .*%(call removed%)"),
  "preview shows the path's call graph")
check(not text:match("Tidy") and not text:match("Squash"), "reformatted functions are not listed")

local function help_lines()
  vim.api.nvim_feedkeys("?", "x", false)
  local win = vim.api.nvim_get_current_win()
  local floating = vim.api.nvim_win_get_config(win).relative ~= ""
  local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "x", false)
  return floating, table.concat(lines, "\n"), vim.api.nvim_get_current_win() ~= win
end

local floating, keys, closed = help_lines()
check(floating, "? opens a floating window in the list")
check(keys:match("<CR>%s+Enter the path") and keys:match("R%s+Refresh") and keys:match("q%s+Quit trail") and keys:match("%?%s+Show keys"), "list keys are listed: " .. keys)
check(closed and vim.api.nvim_get_current_buf() == buf, "<Esc> closes the keys window and returns to the list")
check(text:match("%? keys"), "list header hints at ?")

local function panes()
  return vim.tbl_filter(function(w)
    return vim.w[w].trail_pane
  end, vim.api.nvim_tabpage_list_wins(0))
end
local function wait_diff_line(text)
  return vim.wait(10000, function()
    return vim.api.nvim_buf_get_name(0):match("^trail://diff/") and vim.api.nvim_get_current_line() == text
  end)
end
local function graph_buf()
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.api.nvim_buf_get_name(b):match("trail://graph$") then
      return b, w
    end
  end
end
local function current_step_line()
  local b = graph_buf()
  for _, l in ipairs(vim.api.nvim_buf_get_lines(b, 0, -1, false)) do
    if l:match("^▶") then
      return l
    end
  end
end

local function row_with(b, text)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(b, 0, -1, false)) do
    if l == text then
      return i
    end
  end
end
local function marks(b, row)
  return vim.api.nvim_buf_get_extmarks(b, -1, { row - 1, 0 }, { row - 1, -1 }, { details = true })
end
local function has_mark(b, row, pred)
  return vim.iter(marks(b, row)):any(function(m)
    return pred(m[4], m[3])
  end)
end
local function gutter(win, row)
  return vim.api.nvim_eval_statusline(vim.wo[win].statuscolumn, { winid = win, use_statuscol_lnum = row }).str
end

local function has_span(b, row, hl, from, to)
  return row and has_mark(b, row, function(d, col)
    return d.hl_group == hl and col == from and d.end_col == to
  end)
end

vim.api.nvim_feedkeys("1", "x", false)
check(wait_diff_line("func Login(user string) bool {"), "1 enters the first path at its first step")
check(graph_buf(), "the path view shows the call graph")
local gbuf, gwin = graph_buf()
check(vim.api.nvim_buf_get_lines(gbuf, 0, 1, false)[1]:match("auth%.Login  ·  step 1 of 4"), "graph header shows the step")
check(current_step_line():match("^▶ ~ auth%.Login"), "the current step is marked in the graph")

vim.api.nvim_feedkeys("]s", "x", false)
check(wait_diff_line("func VerifyHash(h string) bool {"), "]s moves to the next step")
check(current_step_line():match("auth%.VerifyHash"), "the graph follows the step")
check(#panes() == 1, "unified is the default layout")
check(vim.go.statuscolumn == "" and vim.go.winbar == "" and not vim.go.scrollbind and vim.go.foldmethod == "manual" and vim.go.number == false,
  "the diff's window options do not leak into the user's global settings")
local uwin, ubuf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
local urow = vim.api.nvim_win_get_cursor(uwin)[1]
check(vim.api.nvim_get_current_line() == "func VerifyHash(h string) bool {", "unified: cursor at VerifyHash")
check(gutter(uwin, urow):match("^%s*10%s+12%s+$"), "unified gutter shows old and new numbers, got " .. gutter(uwin, urow))
check(vim.wo[uwin].winbar:match("difftastic"), "unified winbar names the diff engine")
check(vim.bo[ubuf].filetype == "go", "unified go filetype")
check(vim.wo[uwin].winbar:match("%? keys"), "diff winbar hints at ?")
local dfloating, dkeys, dclosed = help_lines()
check(dfloating and dclosed, "? opens and closes a keys window in the diff")
for _, pattern in ipairs({ "%- q%s+Back to the paths screen", "%]s%s+Next step", "%[s%s+Previous step", "gp%s+Switch path", "%[h%s+Previous change", "%]h%s+Next change", "o%s+Show or fold unchanged code", "t%s+Toggle unified and side%-by%-side" }) do
  check(dkeys:match(pattern), "diff keys list " .. pattern .. ": " .. dkeys)
end
check(vim.api.nvim_get_current_win() == uwin, "focus returns to the diff")
local old_login, new_login = row_with(ubuf, "func Login(u string) bool {"), row_with(ubuf, "func Login(user string) bool {")
check(old_login and new_login and old_login < new_login, "old lines come before new lines")
check(old_login and gutter(uwin, old_login):match("^%s*5%s+%- $"), "removed line has old number and -, got " .. gutter(uwin, old_login or 1))
check(new_login and gutter(uwin, new_login):match("^%s+8 %+ $"), "added line has new number and +, got " .. gutter(uwin, new_login or 1))
check(has_span(ubuf, old_login, "TrailDeleteText", 11, 12), "removed token u is highlighted")
check(has_span(ubuf, new_login, "TrailAddText", 11, 15), "added token user is highlighted")
local function peek_on(row, word)
  vim.api.nvim_win_set_cursor(0, { row, vim.api.nvim_get_current_line():len() > 0 and 0 or 0 })
  local col = vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1]:find(word, 1, true)
  vim.api.nvim_win_set_cursor(0, { row, col - 1 })
  local from = vim.api.nvim_get_current_win()
  vim.api.nvim_feedkeys("K", "x", false)
  local float
  vim.wait(10000, function()
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_config(w).relative ~= "" then
        float = w
        return true
      end
    end
  end)
  if not float then
    return nil
  end
  local fbuf = vim.api.nvim_win_get_buf(float)
  local title = table.concat(vim.tbl_map(function(c)
    return c[1]
  end, vim.api.nvim_win_get_config(float).title or {}))
  local result = { lines = vim.api.nvim_buf_get_lines(fbuf, 0, -1, false), filetype = vim.bo[fbuf].filetype, title = title }
  vim.api.nvim_win_close(float, true)
  vim.api.nvim_set_current_win(from)
  return result
end

local hash_call = row_with(ubuf, "\treturn hashOf(h) == h")
local peeked = hash_call and peek_on(hash_call, "hashOf")
check(peeked, "K opens a peek window")
check(peeked and peeked.lines[1] == "func hashOf(h string) string { return strings.ToLower(h) }", "peek shows the function at head: " .. vim.inspect(peeked and peeked.lines))
check(peeked and peeked.filetype == "go", "peek is highlighted as go")
check(peeked and peeked.title:match("auth/auth%.go:16") and peeked.title:match("changed in this review"), "peek title has the location and marks changed functions: " .. (peeked and peeked.title or ""))
local to_lower = row_with(ubuf, "func hashOf(h string) string { return strings.ToLower(h) }")
vim.api.nvim_win_set_cursor(0, { to_lower, ({ vim.api.nvim_get_current_line():find("Lower") })[1] or 0 })
vim.api.nvim_win_set_cursor(0, { to_lower, vim.api.nvim_buf_get_lines(0, to_lower - 1, to_lower, false)[1]:find("Lower") - 1 })
local word, qualifier = require("trail.peek").word_at_cursor()
check(word == "ToLower" and qualifier == "strings", "peek reads the whole name and its qualifier: " .. tostring(word) .. " " .. tostring(qualifier))
local gone_call = row_with(ubuf, "\tGone()")
local peeked_old = gone_call and peek_on(gone_call, "Gone")
check(peeked_old and peeked_old.lines[1] == "func Gone() {}", "K on a removed line peeks the base version: " .. vim.inspect(peeked_old and peeked_old.lines))
check(peeked_old and peeked_old.title:match("auth/auth%.go:14"), "base peek title has the base location")

local function float_win()
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then
      return w
    end
  end
end
local function wait_for(pred)
  vim.wait(10000, pred)
  return pred()
end
local function title_of(w)
  return table.concat(vim.tbl_map(function(c)
    return c[1]
  end, vim.api.nvim_win_get_config(w).title or {}))
end
local function cursor_on(row, word)
  vim.api.nvim_win_set_cursor(uwin, { row, vim.api.nvim_buf_get_lines(ubuf, row - 1, row, false)[1]:find(word, 1, true) - 1 })
end

cursor_on(hash_call, "hashOf")
vim.api.nvim_feedkeys("gd", "x", false)
check(wait_for(function()
  local w = float_win()
  return w and vim.api.nvim_get_current_win() == w and vim.bo[vim.api.nvim_win_get_buf(w)].buftype == ""
end), "gd opens the definition as a real buffer in a float")
local worktree_file = vim.fs.normalize(cache .. "/trail/worktrees/" .. vim.fn.resolve(repo):gsub("[/\\:]", "-") .. "/auth/auth.go")
check(vim.fs.normalize(vim.api.nvim_buf_get_name(0)) == worktree_file, "head definitions open from the review worktree: " .. vim.api.nvim_buf_get_name(0) .. " vs " .. worktree_file)
check(vim.api.nvim_win_get_cursor(0)[1] == 16 and vim.api.nvim_get_current_line():match("^func hashOf"), "the buffer opens at the function")
check(vim.bo.filetype == "go", "the opened buffer is a go file")
check(title_of(0):match("review worktree"), "the title says where the file comes from: " .. title_of(0))
check(vim.wo.statuscolumn == vim.go.statuscolumn and not vim.wo.scrollbind and not vim.wo.cursorbind and vim.wo.winbar == vim.go.winbar,
  "the definition window uses the user's settings, not the diff's gutter and scroll binding")
vim.cmd("q")
check(vim.api.nvim_get_current_win() == uwin, ":q returns to the diff")

cursor_on(hash_call, "hashOf")
vim.api.nvim_feedkeys("K", "x", false)
check(wait_for(function()
  return float_win() ~= nil
end), "K opens the peek popup")
vim.api.nvim_feedkeys("K", "x", false)
check(wait_for(function()
  return vim.api.nvim_get_current_win() == float_win()
end), "K again moves into the popup")
vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
check(wait_for(function()
  return vim.fs.normalize(vim.api.nvim_buf_get_name(0)) == worktree_file
end), "<CR> in the popup opens the definition as a buffer")
vim.cmd("q")

cursor_on(gone_call, "Gone")
vim.api.nvim_feedkeys("gd", "x", false)
check(wait_for(function()
  return float_win() and vim.api.nvim_get_current_win() == float_win()
end), "gd on a removed line opens a float")
check(vim.api.nvim_get_current_line() == "func Gone() {}" and not vim.bo.modifiable, "removed lines open the base version read-only")
check(title_of(0):match("read%-only"), "the base title says it is read-only")
check(vim.wo.statuscolumn == vim.go.statuscolumn and not vim.wo.scrollbind and not vim.wo.cursorbind, "the read-only window does not inherit the diff's gutter and scroll binding")
vim.cmd("q")
vim.fn.delete(cache, "rf")
vim.system({ "git", "-C", repo, "worktree", "prune" }):wait()


check(vim.fn.foldclosed(row_with(ubuf, "func p6() {}") or 1) > 0, "unified folds long unchanged stretches")
vim.api.nvim_win_set_cursor(uwin, { 1, 0 })
vim.api.nvim_feedkeys("]h", "x", false)
check(vim.api.nvim_get_current_line() == 'import "fmt"', "unified ]h jumps to the first change, got " .. vim.api.nvim_get_current_line())
local p6_row = row_with(ubuf, "func p6() {}")
vim.api.nvim_feedkeys("o", "x", false)
check(vim.fn.foldclosed(p6_row) == -1 and vim.fn.foldlevel(p6_row) == 0, "o shows the whole file")
check(vim.api.nvim_get_current_line() == 'import "fmt"', "o keeps the cursor where it was")
vim.api.nvim_win_set_cursor(uwin, { 1, 0 })
vim.api.nvim_feedkeys("]h]h", "x", false)
check(vim.api.nvim_get_current_line() == "func Login(u string) bool {", "]h moves hunk by hunk with the whole file shown, got " .. vim.api.nvim_get_current_line())
vim.api.nvim_feedkeys("[h", "x", false)
check(vim.api.nvim_get_current_line() == 'import "fmt"', "[h moves back a hunk, got " .. vim.api.nvim_get_current_line())
vim.api.nvim_feedkeys("o", "x", false)
check(vim.fn.foldclosed(p6_row) > 0, "o folds unchanged code again")
vim.api.nvim_win_set_cursor(uwin, { urow, 0 })

vim.api.nvim_feedkeys("t", "x", false)
local wins = panes()
check(#wins == 2, "t switches to side by side, got " .. #wins .. " windows")
local lwin, rwin = wins[1], wins[2]
local lbuf, rbuf = vim.api.nvim_win_get_buf(lwin), vim.api.nvim_win_get_buf(rwin)
for _, w in ipairs(wins) do
  check(vim.wo[w].scrollbind and vim.wo[w].cursorbind and not vim.wo[w].diff, "windows scroll together without diff mode")
end
check(vim.api.nvim_get_current_win() == rwin, "cursor on head side")
local cur_row = vim.api.nvim_win_get_cursor(0)[1]
check(vim.api.nvim_get_current_line() == "func VerifyHash(h string) bool {", "side by side keeps the cursor at VerifyHash")
check(vim.api.nvim_buf_get_lines(lbuf, cur_row - 1, cur_row, false)[1] == "func VerifyHash(h string) bool {", "base side aligned on the same row")
check(gutter(rwin, cur_row):match("^%s*12%s+$"), "head gutter shows the real line number, got " .. gutter(rwin, cur_row))
check(vim.bo[rbuf].filetype == "go", "go filetype")
check(vim.wo[rwin].winbar:match("difftastic"), "winbar names the diff engine: " .. vim.wo[rwin].winbar)

local strings_row = row_with(rbuf, '\t"strings"')
check(strings_row and vim.api.nvim_buf_get_lines(lbuf, strings_row - 1, strings_row, false)[1] == "", "added import line has filler on the left")
check(strings_row and has_mark(lbuf, strings_row, function(d)
  return d.virt_text and d.virt_text[1][2] == "TrailFiller"
end), "filler row is marked")
check(strings_row and gutter(lwin, strings_row):match("^%s*$"), "filler row has no line number")

local login_row = row_with(rbuf, "func Login(user string) bool {")
check(login_row and has_mark(rbuf, login_row, function(d, col)
  return d.hl_group == "TrailAddText" and col == 11 and d.end_col == 15
end), "changed token user is highlighted")
check(login_row and gutter(rwin, login_row):match("^%s*8 %+ $"), "changed line has a + marker, got " .. gutter(rwin, login_row or 1))
check(login_row and gutter(lwin, login_row):match("^%s*5 %- $"), "changed base line has a - marker, got " .. gutter(lwin, login_row or 1))
check(login_row and not has_mark(rbuf, login_row, function(d)
  return d.hl_eol or d.line_hl_group
end), "changed line is not tinted")
local marker_hl = vim.api.nvim_eval_statusline(vim.wo[rwin].statuscolumn, { winid = rwin, use_statuscol_lnum = login_row, highlights = true }).highlights
check(vim.iter(marker_hl):any(function(h)
  return h.group == "TrailAdd"
end), "marker uses the TrailAdd color")
check(login_row and vim.api.nvim_buf_get_lines(lbuf, login_row - 1, login_row, false)[1] == "func Login(u string) bool {", "Login lines aligned")

local p6 = row_with(rbuf, "func p6() {}")
check(p6 and vim.api.nvim_win_call(lwin, function()
  return vim.fn.foldclosed(p6)
end) > 0 and vim.api.nvim_win_call(rwin, function()
  return vim.fn.foldclosed(p6)
end) > 0, "long unchanged stretch is folded on both sides")

vim.api.nvim_win_set_cursor(rwin, { 1, 0 })
vim.api.nvim_feedkeys("]h", "x", false)
local first_change = vim.api.nvim_win_get_cursor(rwin)[1]
check(first_change > 1 and first_change <= strings_row, "]h jumps to the first change, got " .. first_change)

vim.api.nvim_feedkeys("o", "x", false)
check(vim.iter(panes()):all(function(w)
  return vim.api.nvim_win_call(w, function()
    return vim.fn.foldlevel(p6) == 0
  end)
end), "o shows the whole file on both sides")
vim.api.nvim_feedkeys("t", "x", false)
check(#panes() == 1, "t switches back to unified")
check(vim.api.nvim_get_current_line() == "import (", "toggling keeps the cursor on the same line, got " .. vim.api.nvim_get_current_line())

vim.api.nvim_feedkeys("-", "x", false)
check(vim.api.nvim_get_current_buf() == buf, "- returns to the paths screen")

vim.api.nvim_feedkeys("1", "x", false)
vim.wait(10000, function()
  return vim.api.nvim_buf_get_name(0):match("^trail://diff/") ~= nil
end)
gbuf, gwin = graph_buf()
vim.api.nvim_set_current_win(gwin)
for i, l in ipairs(vim.api.nvim_buf_get_lines(gbuf, 0, -1, false)) do
  if l:match("auth%.Gone") then
    vim.api.nvim_win_set_cursor(gwin, { i, 0 })
  end
end
vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
check(vim.wait(10000, function()
  return current_step_line():match("auth%.Gone") and vim.api.nvim_get_current_win() == gwin
end), "<CR> on a graph node shows that step and keeps focus in the graph")
check(vim.wait(10000, function()
  local w = panes()[1]
  return w and vim.api.nvim_win_call(w, function()
    return vim.api.nvim_get_current_line() == "func Gone() {}"
  end)
end), "the diff below follows the graph to the removed function")
check(vim.api.nvim_get_current_win() == gwin, "focus stays in the graph after the diff updates")
vim.api.nvim_set_current_win(panes()[1])
check(vim.fn.foldlevel(row_with(0, "func p6() {}") or 1) == 0, "the whole-file choice is kept for the next file")
check(#panes() == 1, "the last chosen layout is kept for the next file")
check(vim.api.nvim_get_current_line() == "func Gone() {}", "cursor at Gone")
check(gutter(0, vim.api.nvim_win_get_cursor(0)[1]):match("^%s*14%s+%- $"), "removed function line is marked -")
local tidy_body = row_with(0, "\tx()")
check(tidy_body and not gutter(0, tidy_body):match("[%+%-]"), "reformatted code shows as context, got " .. gutter(0, tidy_body or 1))
check(row_with(0, "func Squash() { y() }") and not row_with(0, "\ty()"), "code squashed by reformatting shows only its new layout")
check(#vim.api.nvim_list_tabpages() == 3, "the path tab is reused, got " .. #vim.api.nvim_list_tabpages())

vim.api.nvim_set_current_win(gwin)
vim.api.nvim_feedkeys("p", "x", false)
check(vim.wait(10000, function()
  return current_step_line():match("auth%.hashOf")
end), "p in the graph moves to the previous step")
vim.api.nvim_feedkeys("n", "x", false)
check(vim.wait(10000, function()
  return current_step_line():match("auth%.Gone")
end), "n in the graph moves to the next step")

local select_items
vim.ui.select = function(items, opts, on_choice)
  select_items = vim.tbl_map(opts.format_item, items)
  on_choice(items[2])
end
vim.api.nvim_feedkeys("gp", "x", false)
check(select_items and select_items[1]:match("auth%.Login") and select_items[2]:match("auth/auth_test%.go")
  and select_items[3]:match("Not in any path"), "gp offers every path: " .. vim.inspect(select_items))
check(vim.wait(10000, function()
  return vim.api.nvim_get_current_line() == "func TestLogin(t *testing.T) {"
end), "choosing a path in gp opens it")

vim.api.nvim_feedkeys("-", "x", false)
vim.api.nvim_win_set_cursor(0, { line_of("^     auth/auth%.go:3%-6$"), 0 })
vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
check(vim.wait(10000, function()
  return vim.api.nvim_buf_get_name(0):match("^trail://diff/") and vim.api.nvim_get_current_line() == "import ("
end), "<CR> on a loose hunk opens it")
check(vim.api.nvim_buf_get_lines(graph_buf(), 0, 1, false)[1]:match("Not in any path"), "loose hunks open as their own path")

vim.o.lines = 12
vim.api.nvim_feedkeys("-1", "x", false)
check(vim.wait(10000, function()
  local _, w = graph_buf()
  return w and current_step_line() and current_step_line():match("auth%.Gone")
end), "re-entering a path resumes at the step it was left at")
local _, small_gwin = graph_buf()
check(vim.api.nvim_win_get_height(small_gwin) <= 4, "the graph takes at most a third of the screen, got " .. vim.api.nvim_win_get_height(small_gwin))

local state_file = require("trail.state").path()
check(state_file and state_file:match("/%.git/trail/main%.%.feature%.json$") and vim.fn.filereadable(state_file) == 1,
  "review state is saved under .git/trail: " .. tostring(state_file))
local saved = vim.json.decode(table.concat(vim.fn.readfile(state_file), "\n"))
check(saved.positions["path:go:auth.Login"] == 4, "the step each path was left at is saved: " .. vim.inspect(saved.positions))
check(vim.tbl_count(saved.seen) > 0, "seen hunks are saved")

vim.api.nvim_feedkeys("-", "x", false)
local function home_line(pattern)
  for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if l:match(pattern) then
      return l
    end
  end
end
check(home_line("^  1  auth%.Login  4 steps  ✓ 4/4$"), "a path whose steps were all seen is marked done: " .. tostring(home_line("auth%.Login  4")))
vim.fn.delete(state_file)
vim.api.nvim_feedkeys("R", "x", false)

check(vim.wait(10000, function()
  return home_line("^  1  auth%.Login  4 steps  · 0/4$") ~= nil
end), "progress starts over without saved state")
vim.api.nvim_feedkeys("1", "x", false)
check(wait_diff_line("func Login(user string) bool {"), "a path without a saved step starts at step 1")
vim.api.nvim_feedkeys("-", "x", false)
local partial = home_line("^  1  auth%.Login  4 steps  · (%d)/4$")
local done = partial and tonumber(partial:match("· (%d)/4$"))
check(done and done >= 1 and done < 4, "only steps whose hunks were on screen count as done: " .. tostring(partial))
vim.api.nvim_feedkeys("1", "x", false)
vim.wait(10000, function()
  return vim.api.nvim_buf_get_name(0):match("^trail://diff/") ~= nil
end)
vim.api.nvim_feedkeys("]s", "x", false)
vim.wait(10000, function()
  return current_step_line():match("auth%.VerifyHash")
end)
local login_row
for _, l in ipairs(vim.api.nvim_buf_get_lines((graph_buf()), 0, -1, false)) do
  if l:match("auth%.Login  ") then
    login_row = l
  end
end
check(login_row and login_row:match("^✓"), "a done step is marked in the graph: " .. tostring(login_row))

vim.api.nvim_feedkeys("-", "x", false)
vim.fn.writefile({ vim.json.encode({ version = 1, seen = vim.empty_dict(), positions = { ["path:go:auth.Login"] = 4 }, comments = {} }) }, state_file)
vim.api.nvim_feedkeys("R", "x", false)
vim.wait(10000, function()
  return home_line("^  1  auth%.Login  4 steps  · 0/4$") ~= nil
end)
vim.api.nvim_feedkeys("1", "x", false)
check(vim.wait(10000, function()
  return vim.api.nvim_buf_get_name(0):match("^trail://diff/") and vim.api.nvim_get_current_line() == "func Gone() {}"
end), "the saved step is resumed from the state file")
vim.api.nvim_feedkeys("-", "x", false)
local jumped = home_line("^  1  auth%.Login  4 steps  · (%d)/4$")
local jumped_done = jumped and tonumber(jumped:match("· (%d)/4$"))
check(jumped_done and jumped_done < 4, "hunks jumped over above the screen do not count as seen: " .. tostring(jumped))

-- Comments and the send screen.
vim.o.lines = 24
local inputs = {}
vim.ui.input = function(opts, on_confirm)
  table.insert(inputs, opts)
  on_confirm(table.remove(inputs.answers or {}, 1))
end
local function answer(...)
  inputs.answers = { ... }
end
vim.api.nvim_feedkeys("1", "x", false)
vim.wait(10000, function()
  return vim.api.nvim_buf_get_name(0):match("^trail://diff/") ~= nil
end)
vim.api.nvim_feedkeys("[s[s[s", "x", false)
check(wait_diff_line("func Login(user string) bool {"), "back at the Login step")
local function notes_on(b, text)
  local row = row_with(b, text)
  if not row then
    return nil
  end
  local found = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(b, -1, { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
    for _, vl in ipairs(m[4].virt_lines or {}) do
      table.insert(found, table.concat(vim.tbl_map(function(c)
        return c[1]
      end, vl)))
    end
  end
  return found
end
answer("why the rename?")
vim.api.nvim_feedkeys("cq", "x", false)
check(inputs[1] and inputs[1].prompt == "question: ", "cq asks for a question")
local saved_comments = vim.json.decode(table.concat(vim.fn.readfile(state_file), "\n")).comments
check(#saved_comments == 1 and saved_comments[1].kind == "question" and saved_comments[1].side == "new"
  and saved_comments[1].line == 8 and saved_comments[1].text == "func Login(user string) bool {"
  and saved_comments[1].file == "auth/auth.go" and saved_comments[1].body == "why the rename?",
  "the comment is saved with its kind, side, line and line text: " .. vim.inspect(saved_comments))
local cbuf = vim.api.nvim_get_current_buf()
local notes = notes_on(cbuf, "func Login(user string) bool {")
check(notes and notes[1] and notes[1]:match("question") and notes[1]:match("why the rename%?"), "the comment shows under its line: " .. vim.inspect(notes))

vim.api.nvim_win_set_cursor(0, { row_with(cbuf, "\tGone()"), 0 })
answer("keep the audit")
vim.api.nvim_feedkeys("cb", "x", false)
check(vim.iter(notes_on(cbuf, "\tGone()") or {}):any(function(n)
  return n:match("blocking") and n:match("keep the audit")
end), "a comment on a removed line shows there")

vim.api.nvim_feedkeys("t", "x", false)
local sbs = panes()
check(#sbs == 2 and vim.iter(notes_on(vim.api.nvim_win_get_buf(sbs[2]), "func Login(user string) bool {") or {}):any(function(n)
  return n:match("why the rename")
end) and vim.iter(notes_on(vim.api.nvim_win_get_buf(sbs[1]), "\tGone()") or {}):any(function(n)
  return n:match("keep the audit")
end), "comments follow their side in the side-by-side layout")
vim.api.nvim_feedkeys("t", "x", false)
cbuf = vim.api.nvim_get_current_buf()

vim.api.nvim_win_set_cursor(0, { row_with(cbuf, "func Login(user string) bool {"), 0 })
answer("why rename u to user?")
vim.api.nvim_feedkeys("ce", "x", false)
check(vim.iter(notes_on(cbuf, "func Login(user string) bool {") or {}):any(function(n)
  return n:match("why rename u to user%?")
end), "ce edits the comment on the line")

local list = vim.json.decode(table.concat(vim.fn.readfile(state_file), "\n"))
list.comments[1].line = 2
vim.fn.writefile({ vim.json.encode(list) }, state_file)
vim.api.nvim_feedkeys("-", "x", false)
vim.api.nvim_feedkeys("R", "x", false)
vim.wait(10000, function()
  return home_line("2 comments$") ~= nil
end)
check(home_line("· 2 comments$"), "the paths screen counts comments")
vim.api.nvim_feedkeys("1", "x", false)
vim.wait(10000, function()
  return vim.api.nvim_buf_get_name(0):match("^trail://diff/") ~= nil and vim.api.nvim_get_current_buf() ~= cbuf
    and vim.api.nvim_get_current_line() == "func Login(user string) bool {"
end)
check(vim.iter(notes_on(vim.api.nvim_get_current_buf(), "func Login(user string) bool {") or {}):any(function(n)
  return n:match("why rename u to user")
end), "a comment whose line moved finds its line again by its text")

vim.api.nvim_feedkeys("-", "x", false)
vim.api.nvim_feedkeys("S", "x", false)
local sbuf = vim.api.nvim_get_current_buf()
local function send_text()
  return table.concat(vim.api.nvim_buf_get_lines(sbuf, 0, -1, false), "\n")
end
check(vim.api.nvim_buf_get_name(sbuf):match("trail://send$"), "S opens the send screen")
check(send_text():match("Review of main%.%.feature") and send_text():match("Verdict: none")
  and send_text():match("auth/auth%.go") and send_text():match("question%s+why rename u to user%?")
  and send_text():match("blocking%s+keep the audit"), "the send screen lists comments by file: " .. send_text())
vim.api.nvim_feedkeys("v", "x", false)
check(send_text():match("Verdict: approve"), "v sets the verdict")
vim.api.nvim_feedkeys("v", "x", false)
check(send_text():match("Verdict: request changes"), "v cycles the verdict")
check(vim.json.decode(table.concat(vim.fn.readfile(state_file), "\n")).verdict == "request changes", "the verdict is saved")
vim.api.nvim_feedkeys("y", "x", false)
local md = vim.fn.getreg('"')
check(md:match("^## Review of main%.%.feature") and md:match("%*%*Verdict:%*%* request changes")
  and md:match("### auth/auth%.go") and md:match("%- %*%*question%*%* %(line 8%): why rename u to user%?")
  and md:match("%- %*%*blocking%*%* %(removed line 6%): keep the audit") and md:match("> `Gone%(%)`"),
  "y copies the review as markdown: " .. md)
for i, l in ipairs(vim.api.nvim_buf_get_lines(sbuf, 0, -1, false)) do
  if l:match("question") then
    vim.api.nvim_win_set_cursor(0, { i, 0 })
  end
end
vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
check(vim.wait(10000, function()
  local b = graph_buf()
  return b and current_step_line() and current_step_line():match("auth%.Login")
end), "<CR> on a comment opens its step")

vim.fn.delete(repo, "rf")
if failures > 0 then
  io.stderr:write(failures .. " failures\n")
  os.exit(1)
end
print("ok")
os.exit(0)
