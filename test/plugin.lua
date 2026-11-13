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
write("auth/auth.go", "package auth\n\nimport \"fmt\"\n\nfunc Login(u string) bool {\n\tGone()\n\treturn VerifyHash(u)\n}\n\nfunc VerifyHash(h string) bool {\n\treturn h != \"\"\n}\n\nfunc Gone() {}")
sh("git add -A && git commit -qm base && git checkout -qb feature")
write("auth/auth.go", "package auth\n\nimport (\n\t\"fmt\"\n\t\"strings\"\n)\n\nfunc Login(u string) bool {\n\treturn VerifyHash(u)\n}\n\nfunc VerifyHash(h string) bool {\n\treturn hashOf(h) == h\n}\n\nfunc hashOf(h string) string { return strings.ToLower(h) }")
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

vim.api.nvim_win_set_cursor(0, { verify, 0 })
vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
local wins = vim.api.nvim_tabpage_list_wins(0)
check(#wins == 2, "diff tab has two windows, got " .. #wins)
for _, w in ipairs(wins) do
  check(vim.wo[w].diff, "window is in diff mode")
end
local cur = vim.api.nvim_get_current_buf()
check(vim.api.nvim_buf_get_name(cur):match("trail://head/auth/auth%.go$"), "cursor on head side")
check(vim.api.nvim_win_get_cursor(0)[1] == 12, "cursor at VerifyHash on head side")
check(vim.bo[cur].filetype == "go", "go filetype")
local left = vim.api.nvim_win_get_buf(wins[1])
check(vim.api.nvim_buf_get_lines(left, 9, 10, false)[1] == "func VerifyHash(h string) bool {", "base side content")

vim.api.nvim_feedkeys("-", "x", false)
check(vim.api.nvim_get_current_buf() == buf, "- returns to the list")

vim.api.nvim_win_set_cursor(0, { gone, 0 })
vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
check(vim.api.nvim_buf_get_name(0):match("trail://base/auth/auth%.go$"), "removed function opens on base side")
check(vim.api.nvim_win_get_cursor(0)[1] == 14, "cursor at Gone on base side")
check(#vim.api.nvim_list_tabpages() == 3, "diff tab is reused, got " .. #vim.api.nvim_list_tabpages())

vim.fn.delete(repo, "rf")
if failures > 0 then
  io.stderr:write(failures .. " failures\n")
  os.exit(1)
end
print("ok")
os.exit(0)
