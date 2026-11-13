-- Run from the repo root: nvim --headless -u NONE -l test/plugin.lua
local root = vim.fn.getcwd()
vim.opt.rtp:prepend(root)
vim.cmd.runtime("plugin/trail.lua")

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

local code, login, verify, hash, gone = line_of("^Code$"), line_of("^  ~ auth%.Login"),
  line_of("^    ~ auth%.VerifyHash"), line_of("^      %+ auth%.hashOf"), line_of("^    %- auth%.Gone")
check(code and login and verify and hash and gone, "call tree shape")
check(text:match("auth%.hashOf  auth/auth%.go:16  %(new call%)"), "added edge note")
check(text:match("auth%.Gone  auth/auth%.go:14  %(call removed%)"), "removed edge note")
check(line_of("^Tests$") and line_of("^  %+ auth%.TestLogin"), "tests section")
check(line_of("^    ~ auth%.Login  auth/auth%.go:8  %(new call%)$") and not line_of("^      ~ auth%.VerifyHash"), "test callee shown as a leaf")
check(not text:match("Tidy") and not text:match("Squash"), "reformatted functions are not listed")
check(line_of("^Not in any function$") and line_of("^    auth/auth%.go:3%-6$"), "import hunk listed")

local function open_line(row)
  local tabs = #vim.api.nvim_list_tabpages()
  vim.api.nvim_win_set_cursor(0, { row, 0 })
  vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
  return vim.wait(10000, function()
    return vim.api.nvim_buf_get_name(0):match("^trail://") and vim.api.nvim_get_current_buf() ~= buf
      and #vim.api.nvim_list_tabpages() >= math.min(tabs + 1, 3)
  end)
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

check(open_line(verify), "diff opened")
check(#vim.api.nvim_tabpage_list_wins(0) == 1, "unified is the default layout")
local uwin, ubuf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
local urow = vim.api.nvim_win_get_cursor(uwin)[1]
check(vim.api.nvim_get_current_line() == "func VerifyHash(h string) bool {", "unified: cursor at VerifyHash")
check(gutter(uwin, urow):match("^%s*10%s+12%s+$"), "unified gutter shows old and new numbers, got " .. gutter(uwin, urow))
check(vim.wo[uwin].winbar:match("difftastic"), "unified winbar names the diff engine")
check(vim.bo[ubuf].filetype == "go", "unified go filetype")
local old_login, new_login = row_with(ubuf, "func Login(u string) bool {"), row_with(ubuf, "func Login(user string) bool {")
check(old_login and new_login and old_login < new_login, "old lines come before new lines")
check(old_login and gutter(uwin, old_login):match("^%s*5%s+%- $"), "removed line has old number and -, got " .. gutter(uwin, old_login or 1))
check(new_login and gutter(uwin, new_login):match("^%s+8 %+ $"), "added line has new number and +, got " .. gutter(uwin, new_login or 1))
check(has_span(ubuf, old_login, "TrailDeleteText", 11, 12), "removed token u is highlighted")
check(has_span(ubuf, new_login, "TrailAddText", 11, 15), "added token user is highlighted")
check(vim.fn.foldclosed(row_with(ubuf, "func p6() {}") or 1) > 0, "unified folds long unchanged stretches")
vim.api.nvim_win_set_cursor(uwin, { 1, 0 })
vim.api.nvim_feedkeys("]h", "x", false)
check(vim.api.nvim_get_current_line() == 'import "fmt"', "unified ]h jumps to the first change, got " .. vim.api.nvim_get_current_line())
vim.api.nvim_win_set_cursor(uwin, { urow, 0 })

vim.api.nvim_feedkeys("t", "x", false)
local wins = vim.api.nvim_tabpage_list_wins(0)
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

vim.api.nvim_feedkeys("t", "x", false)
check(#vim.api.nvim_tabpage_list_wins(0) == 1, "t switches back to unified")
check(vim.api.nvim_get_current_line() == "import (", "toggling keeps the cursor on the same line, got " .. vim.api.nvim_get_current_line())

vim.api.nvim_feedkeys("-", "x", false)
check(vim.api.nvim_get_current_buf() == buf, "- returns to the list")

check(open_line(gone), "diff for removed function opened")
check(#vim.api.nvim_tabpage_list_wins(0) == 1, "the last chosen layout is kept for the next file")
check(vim.api.nvim_get_current_line() == "func Gone() {}", "cursor at Gone")
check(gutter(0, vim.api.nvim_win_get_cursor(0)[1]):match("^%s*14%s+%- $"), "removed function line is marked -")
local tidy_body = row_with(0, "\tx()")
check(tidy_body and not gutter(0, tidy_body):match("[%+%-]"), "reformatted code shows as context, got " .. gutter(0, tidy_body or 1))
check(row_with(0, "func Squash() { y() }") and not row_with(0, "\ty()"), "code squashed by reformatting shows only its new layout")
check(#vim.api.nvim_list_tabpages() == 3, "diff tab is reused, got " .. #vim.api.nvim_list_tabpages())

vim.fn.delete(repo, "rf")
if failures > 0 then
  io.stderr:write(failures .. " failures\n")
  os.exit(1)
end
print("ok")
os.exit(0)
