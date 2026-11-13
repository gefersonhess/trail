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
write("auth/auth.go", "package auth\n\nimport \"fmt\"\n\nfunc Login(u string) bool {\n\tGone()\n\treturn VerifyHash(u)\n}\n\nfunc VerifyHash(h string) bool {\n\treturn h != \"\"\n}\n\nfunc Gone() {}\n\nfunc p1() {}\nfunc p2() {}\nfunc p3() {}\nfunc p4() {}\nfunc p5() {}\nfunc p6() {}\nfunc p7() {}\nfunc p8() {}\nfunc p9() {}\nfunc p10() {}")
sh("git add -A && git commit -qm base && git checkout -qb feature")
write("auth/auth.go", "package auth\n\nimport (\n\t\"fmt\"\n\t\"strings\"\n)\n\nfunc Login(user string) bool {\n\treturn VerifyHash(user)\n}\n\nfunc VerifyHash(h string) bool {\n\treturn hashOf(h) == h\n}\n\nfunc hashOf(h string) string { return strings.ToLower(h) }\n\nfunc p1() {}\nfunc p2() {}\nfunc p3() {}\nfunc p4() {}\nfunc p5() {}\nfunc p6() {}\nfunc p7() {}\nfunc p8() {}\nfunc p9() {}\nfunc p10() {}")
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

check(open_line(verify), "diff opened")
local wins = vim.api.nvim_tabpage_list_wins(0)
check(#wins == 2, "diff tab has two windows, got " .. #wins)
local lwin, rwin = wins[1], wins[2]
local lbuf, rbuf = vim.api.nvim_win_get_buf(lwin), vim.api.nvim_win_get_buf(rwin)
for _, w in ipairs(wins) do
  check(vim.wo[w].scrollbind and vim.wo[w].cursorbind and not vim.wo[w].diff, "windows scroll together without diff mode")
end
check(vim.api.nvim_get_current_win() == rwin, "cursor on head side")
local cur_row = vim.api.nvim_win_get_cursor(0)[1]
check(vim.api.nvim_get_current_line() == "func VerifyHash(h string) bool {", "cursor at VerifyHash")
check(vim.api.nvim_buf_get_lines(lbuf, cur_row - 1, cur_row, false)[1] == "func VerifyHash(h string) bool {", "base side aligned on the same row")
check(gutter(rwin, cur_row):match("^%s*12 $"), "head gutter shows the real line number, got " .. gutter(rwin, cur_row))
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
check(login_row and has_mark(rbuf, login_row, function(d)
  return d.hl_group == "TrailAdd" and d.hl_eol and d.priority < 200
end), "changed line has a background under the token highlights")
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

vim.api.nvim_feedkeys("-", "x", false)
check(vim.api.nvim_get_current_buf() == buf, "- returns to the list")

check(open_line(gone), "diff for removed function opened")
check(vim.api.nvim_buf_get_name(0):match("trail://base/auth/auth%.go$"), "removed function opens on base side")
check(vim.api.nvim_get_current_line() == "func Gone() {}", "cursor at Gone on base side")
check(#vim.api.nvim_list_tabpages() == 3, "diff tab is reused, got " .. #vim.api.nvim_list_tabpages())

vim.fn.delete(repo, "rf")
if failures > 0 then
  io.stderr:write(failures .. " failures\n")
  os.exit(1)
end
print("ok")
os.exit(0)
