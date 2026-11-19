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
write("notes.md", "notes")
sh("git add -A && git commit -qm feature")
sh("git checkout -q main")
local cache = repo .. "-cache"
vim.env.XDG_CACHE_HOME = cache

vim.env.TRAIL_GOPLS = repo .. "-no-gopls"
vim.g.trail_ignore = { "*.md" }
vim.cmd.cd(repo)
vim.cmd("Trail main..feature")
local buf = vim.api.nvim_get_current_buf()
local loaded = vim.wait(15000, function()
  return vim.iter(vim.api.nvim_buf_get_lines(buf, 0, -1, false)):any(function(l)
    return l:match("^  1  Login ")
  end)
end)
check(loaded, "the paths never loaded: " .. table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))

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

check(lines[1] == "main..feature", "a branch review's header is its range, with nothing about a pull request: " .. lines[1])
check(lines[2]:find("░", 1, true) == 1 and lines[2]:match("  0/%d+ hunks$"), "a progress bar over every hunk, without a submit status: " .. lines[2])
check(not text:match("Description") and not text:match("Needs attention"),
  "no description for a branch, and nothing needs attention when every change is tested")
check(line_of("^  1  Login  ░░░░░░░░░░  0/3$"), "a path row is its name, a progress bar and done/total")
check(line_of("^▸ Tests %(1%)$") and line_of("^▸ Not in any path %(1%)$") and line_of("^▸ Hidden %(1%)$"),
  "the sections below the paths start folded, with their counts")
check(not text:match("notes%.md") and not text:match("auth_test%.go"), "folded sections list nothing")
check(lines[#lines] == "? keys", "the only key hint is ? at the bottom")
check(not text:match("──") and not text:match("VerifyHash"), "there is no preview tree")
local function home_row(pattern)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if l:match(pattern) then
      return i
    end
  end
end
for _, section in ipairs({ "Tests", "Not in any path", "Hidden" }) do
  vim.api.nvim_win_set_cursor(0, { home_row("^▸ " .. vim.pesc(section)), 0 })
  vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
end
check(home_row("^▾ Tests %(1%)$") and home_row("^    auth/$") and home_row("^      auth_test%.go  covers 3 functions  0/1$"),
  "<CR> opens Tests: Go test files under their package, with what they cover")
check(home_row("^    auth/auth%.go  1 hunk$"), "<CR> opens Not in any path, by file")
check(home_row("^    notes%.md$"), "<CR> opens Hidden, naming the files")
vim.api.nvim_win_set_cursor(0, { home_row("^▾ Hidden"), 0 })
vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
check(home_row("^▸ Hidden %(1%)$") and not home_row("notes%.md"), "<CR> folds a section again")
vim.api.nvim_win_set_cursor(0, { home_row("^  1  Login "), 0 })
vim.api.nvim_feedkeys("mr", "x", false)
check(home_row("^  1  Login  ██████████  3/3 ✓$"), "mr marks the path as reviewed")
check(vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1]:find("█", 1, true) == 1, "the header's bar moves with it")
vim.api.nvim_feedkeys("mr", "x", false)
check(home_row("^  1  Login  ░░░░░░░░░░  0/3$"), "mr on a reviewed path unmarks it")
check(not text:match("Gone"), "a removed function is not a step: its hunk is part of VerifyHash's")
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
check(keys:match("^ Open\n") and keys:match("\n Review\n") and keys:match("\n Screen\n"),
  "the paths screen's keys are grouped: " .. keys)
check(keys:match("<CR>%s+open the line") and keys:match("1%-9%s+enter path") and keys:match("R%s+refresh") and keys:match("q%s+quit"),
  "with short labels, and the path numbers as one range: " .. keys)
check(not keys:match("%?%s"), "? does not list itself")
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
    if vim.api.nvim_buf_get_name(b):match("trail://path$") then
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
local function raw_gutter(win, row)
  return vim.api.nvim_eval_statusline(vim.wo[win].statuscolumn, { winid = win, use_statuscol_lnum = row }).str
end
---The gutter's numbers and marker, without the reviewed-hunk column.
local function gutter(win, row)
  return (raw_gutter(win, row):gsub("▎$", " "))
end
---Whether the gutter marks the row as part of a reviewed hunk.
local function reviewed(win, row)
  return raw_gutter(win, row):match("▎$") ~= nil
end

local function has_span(b, row, hl, from, to)
  return row and has_mark(b, row, function(d, col)
    return d.hl_group == hl and col == from and d.end_col == to
  end)
end

vim.api.nvim_feedkeys("1", "x", false)
check(wait_diff_line("func Login(user string) bool {"), "1 enters the first path at its first step")
check(graph_buf(), "the path view shows the path's tree")
local gbuf, gwin = graph_buf()
check(vim.api.nvim_buf_get_lines(gbuf, 0, 1, false)[1]:match("^ Login  ·  step 1 of 3  ·  3 functions$"), "the tree's header shows the step")
check(current_step_line():match("^▶ ● Login   step 1"), "the current step is marked in the tree")

vim.api.nvim_feedkeys("]s", "x", false)
check(wait_diff_line("func VerifyHash(h string) bool {"), "]s moves to the next step")
check(current_step_line():match("VerifyHash"), "the tree follows the step")

-- ]c and [c move through the path's own changes, across steps.
local function press_until(keys, pred)
  vim.api.nvim_feedkeys(keys, "x", false)
  return vim.wait(10000, function()
    return vim.api.nvim_buf_get_name(0):match("^trail://diff/") and pred()
  end)
end
vim.api.nvim_feedkeys("[s", "x", false)
check(wait_diff_line("func Login(user string) bool {"), "back at Login for ]c")
check(press_until("]c", function()
  return current_step_line():match("VerifyHash") and vim.api.nvim_get_current_line() == '\treturn h != ""'
end), "]c goes to the next step's first change, at its first line: " .. vim.api.nvim_get_current_line())
check(press_until("]c", function()
  return current_step_line():match("hashOf") ~= nil
end), "]c continues into the next step")
vim.api.nvim_feedkeys("]c", "x", false)
check(current_step_line():match("hashOf"), "]c stops at the last change of the path")
check(press_until("[c", function()
  return current_step_line():match("VerifyHash") and vim.api.nvim_get_current_line() == '\treturn h != ""'
end), "[c goes back to the previous step's last change")
check(press_until("[c", function()
  return current_step_line():match("Login") ~= nil
end), "[c goes back to the first step")
vim.api.nvim_feedkeys("[c", "x", false)
vim.wait(300)
check(current_step_line():match("Login") and vim.api.nvim_get_current_line() ~= "import (",
  "[c stops at the first change and skips hunks outside the path")
vim.api.nvim_feedkeys("]s", "x", false)
check(wait_diff_line("func VerifyHash(h string) bool {"), "]s still moves by step")
check(#panes() == 1, "unified is the default layout")
check(vim.go.statuscolumn == "" and vim.go.winbar == "" and not vim.go.scrollbind and vim.go.foldmethod == "manual" and vim.go.number == false,
  "the diff's window options do not leak into the user's global settings")
local uwin, ubuf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
local urow = vim.api.nvim_win_get_cursor(uwin)[1]
check(vim.api.nvim_get_current_line() == "func VerifyHash(h string) bool {", "unified: cursor at VerifyHash")
check(gutter(uwin, urow):match("^%s*10%s+12%s+$"), "unified gutter shows old and new numbers, got " .. gutter(uwin, urow))
check(vim.wo[uwin].winbar:match("difftastic"), "unified winbar names the diff engine")
check(vim.bo[ubuf].filetype == "go", "unified go filetype")
check(has_span(ubuf, urow, "TrailContext", 0, #"func VerifyHash(h string) bool {"), "unchanged text gets one colour whatever else highlights it")
check(vim.bo[ubuf].syntax == "off" and not vim.treesitter.highlighter.active[ubuf], "unchanged code is not syntax highlighted")
check(vim.wo[uwin].winbar:match("%? keys"), "diff winbar hints at ?")
local dfloating, dkeys, dclosed = help_lines()
check(dfloating and dclosed, "? opens and closes a keys window in the diff")
for _, pattern in ipairs({ "^ Move\n", "\n Review\n", "\n View\n", "%]s %[s%s+step", "%]c %[c%s+change", "%]h %[h%s+hunk",
  "%]t %[t%s+thread", "%- q%s+back to paths", "cb cq cn%s+as kind", "ce cd%s+edit / delete", "t%s+side by side",
  "o%s+whole file", "gd%s+open in Neovim" }) do
  check(dkeys:match(pattern), "diff keys list " .. pattern .. ": " .. dkeys)
end
check(dkeys:match("\n   %S.-   %S"), "two columns when there is room: " .. dkeys)
check(not dkeys:match("Other"), "every diff key has a group and a label")
check(vim.api.nvim_get_current_win() == uwin, "focus returns to the diff")
local old_login, new_login = row_with(ubuf, "func Login(u string) bool {"), row_with(ubuf, "func Login(user string) bool {")
check(old_login and new_login and old_login < new_login, "old lines come before new lines")
check(old_login and gutter(uwin, old_login):match("^%s*5%s+%- $"), "removed line has old number and -, got " .. gutter(uwin, old_login or 1))
check(new_login and gutter(uwin, new_login):match("^%s+8 %+ $"), "added line has new number and +, got " .. gutter(uwin, new_login or 1))
check(has_span(ubuf, old_login, "TrailDeleteText", 11, 12), "removed token u is highlighted")
check(has_span(ubuf, new_login, "TrailAddText", 11, 15), "added token user is highlighted")

-- mh marks the hunk under the cursor, or the selected hunks, as reviewed.
local function tree_line(pattern)
  for _, l in ipairs(vim.api.nvim_buf_get_lines((graph_buf()), 0, -1, false)) do
    if l:match(pattern) then
      return l
    end
  end
end
-- Headless Neovim fires no CursorMoved for keys fed in tests; a real session does.
local function moved(keys)
  vim.api.nvim_feedkeys(keys, "x", false)
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = ubuf })
end
check(reviewed(uwin, old_login) and reviewed(uwin, new_login), "a hunk seen by scrolling is marked in the gutter")
check(not reviewed(uwin, urow), "a line outside any hunk is not marked")
check(tree_line("● Login "):match("^✓"), "the seen step is done in the tree")
check(dkeys:match("mh%s+mark hunk"), "diff keys list mh: " .. dkeys)
vim.api.nvim_win_set_cursor(uwin, { new_login, 0 })
vim.api.nvim_feedkeys("mh", "x", false)
check(not reviewed(uwin, old_login) and not reviewed(uwin, new_login), "mh unmarks a reviewed hunk, all its rows")
check(not tree_line("● Login "):match("^✓"), "the step is no longer done once its hunk is unmarked")
moved("k")
check(not reviewed(uwin, new_login), "moving the cursor does not mark a hunk unmarked by hand again")
vim.api.nvim_feedkeys("mh", "x", false)
check(reviewed(uwin, old_login) and reviewed(uwin, new_login) and tree_line("● Login "):match("^✓"), "mh marks the hunk again")
vim.api.nvim_win_set_cursor(uwin, { urow, 0 })
vim.api.nvim_feedkeys("mh", "x", false)
check(reviewed(uwin, new_login), "mh on a line outside any hunk changes nothing")

-- Selecting from Login's hunk down to VerifyHash's covers both.
local verify_row = row_with(ubuf, '\treturn hashOf(h) == h')
check(verify_row and reviewed(uwin, verify_row), "VerifyHash's hunk was seen by scrolling")
vim.api.nvim_win_set_cursor(uwin, { new_login, 0 })
vim.api.nvim_feedkeys("V" .. (verify_row - new_login) .. "jmh", "x", false)
check(vim.fn.mode() == "n", "mh leaves visual mode")
check(not reviewed(uwin, new_login) and not reviewed(uwin, verify_row) and not reviewed(uwin, old_login),
  "mh on a selection unmarks every hunk in it")
vim.api.nvim_win_set_cursor(uwin, { new_login, 0 })
vim.api.nvim_feedkeys("V" .. (verify_row - new_login) .. "jmh", "x", false)
check(reviewed(uwin, new_login) and reviewed(uwin, verify_row), "mh on a selection marks them again")
vim.api.nvim_win_set_cursor(uwin, { new_login, 0 })
vim.api.nvim_feedkeys("Vjmh", "x", false)
check(not reviewed(uwin, new_login) and reviewed(uwin, verify_row), "a selection marks or unmarks only the hunks it touches")

-- A hunk unmarked by hand counts as seen again once it has left the screen
-- and come back, unless scrolling is told not to mark hunks.
vim.api.nvim_feedkeys("o", "x", false)
moved("G")
check(vim.fn.line("w0") > new_login, "the end of the file scrolls Login out of view")
moved("gg")
check(reviewed(uwin, new_login), "scrolling back marks a hand-unmarked hunk once it has left the screen")
vim.g.trail_seen_on_scroll = false
vim.api.nvim_win_set_cursor(uwin, { new_login, 0 })
vim.api.nvim_feedkeys("mh", "x", false)
moved("G")
moved("gg")
check(not reviewed(uwin, new_login), "vim.g.trail_seen_on_scroll = false leaves hunks to be marked by hand")
vim.api.nvim_win_set_cursor(uwin, { new_login, 0 })
vim.api.nvim_feedkeys("mh", "x", false)
check(reviewed(uwin, new_login), "mh marks hunks with scrolling turned off")
vim.g.trail_seen_on_scroll = nil
vim.api.nvim_feedkeys("o", "x", false)
vim.api.nvim_win_set_cursor(uwin, { urow, 0 })
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

-- The editor gd starts is a separate Neovim; keep it away from any real config.
local editor_home = vim.fn.tempname()
vim.env.XDG_CONFIG_HOME, vim.env.XDG_DATA_HOME, vim.env.XDG_STATE_HOME = editor_home, editor_home, editor_home
local function terminal_text(b)
  return table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
end
local function editor_reports(b, expected)
  vim.api.nvim_chan_send(vim.bo[b].channel, ":echo 'at:' .. expand('%:t') .. ':' .. line('.') .. ':' .. (stridx(expand('%:p'), '/trail/worktrees/') >= 0) .. ':' .. exists('$NVIM')\r")
  return wait_for(function()
    return terminal_text(b):find("at:" .. expected, 1, true) ~= nil
  end)
end
local function quit_editor(b)
  vim.api.nvim_chan_send(vim.bo[b].channel, "\27:qa!\r")
  return wait_for(function()
    return float_win() == nil and vim.api.nvim_get_current_win() == uwin
  end)
end

-- Like a config that leaves terminal mode with <Esc>.
vim.keymap.set("t", "<Esc>", "<C-\\><C-n>")
cursor_on(hash_call, "hashOf")
vim.api.nvim_feedkeys("gd", "x", false)
check(wait_for(function()
  local w = float_win()
  return w and vim.bo[vim.api.nvim_win_get_buf(w)].buftype == "terminal"
end), "gd opens a terminal in a float")
local term_win = float_win()
local term_buf = term_win and vim.api.nvim_win_get_buf(term_win)

check(term_win and vim.api.nvim_get_current_win() == term_win, "focus goes to the editor")
check(term_win and title_of(term_win):match("auth/auth%.go:16") and title_of(term_win):match("review worktree"), "the title says what is open and where it comes from")
check(term_buf and wait_for(function()
  return terminal_text(term_buf):match("func hashOf")
end), "the editor shows the definition: " .. (term_buf and terminal_text(term_buf) or ""))
check(term_buf and editor_reports(term_buf, "auth.go:16:1:0"), "the editor is a separate Neovim without $NVIM, at the head file from the review worktree: " .. (term_buf and terminal_text(term_buf) or ""))

check(term_buf and quit_editor(term_buf), "quitting the editor closes the float and returns to the diff")
check(term_buf and not vim.api.nvim_buf_is_valid(term_buf), "the terminal buffer is gone after the editor quits")
vim.keymap.del("t", "<Esc>")

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
  local w = float_win()
  return w and vim.bo[vim.api.nvim_win_get_buf(w)].buftype == "terminal"
end), "<CR> in the popup opens the definition in the editor")
term_buf = float_win() and vim.api.nvim_win_get_buf(float_win())
check(term_buf and editor_reports(term_buf, "auth.go:16:1:0"), "the popup opens the same definition")
check(term_buf and quit_editor(term_buf), "quitting returns to the diff")

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
  if l:match("hashOf") then
    vim.api.nvim_win_set_cursor(gwin, { i, 0 })
  end
end
vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
check(vim.wait(10000, function()
  return current_step_line():match("hashOf") and vim.api.nvim_get_current_win() == gwin
end), "<CR> on a step in the tree shows it and keeps focus in the tree")
check(vim.wait(10000, function()
  local w = panes()[1]
  return w and vim.api.nvim_win_call(w, function()
    return vim.api.nvim_get_current_line() == "func hashOf(h string) string { return strings.ToLower(h) }"
  end)
end), "the diff below follows the tree to the step")
check(vim.api.nvim_get_current_win() == gwin, "focus stays in the tree after the diff updates")
vim.api.nvim_set_current_win(panes()[1])
check(vim.fn.foldlevel(row_with(0, "func p6() {}") or 1) == 0, "the whole-file choice is kept for the next file")
check(#panes() == 1, "the last chosen layout is kept for the next file")
check(vim.api.nvim_get_current_line() == "func hashOf(h string) string { return strings.ToLower(h) }", "cursor at hashOf")
check(row_with(0, "func Gone() {}") and gutter(0, row_with(0, "func Gone() {}")):match("^%s*14%s+%- $"), "removed function line is marked -")
local tidy_body = row_with(0, "\tx()")
check(tidy_body and not gutter(0, tidy_body):match("[%+%-]"), "reformatted code shows as context, got " .. gutter(0, tidy_body or 1))
check(row_with(0, "func Squash() { y() }") and not row_with(0, "\ty()"), "code squashed by reformatting shows only its new layout")
check(#vim.api.nvim_list_tabpages() == 2, "a path opens in the review tab, got " .. #vim.api.nvim_list_tabpages())

vim.api.nvim_set_current_win(gwin)
vim.api.nvim_feedkeys("p", "x", false)
check(vim.wait(10000, function()
  return current_step_line():match("VerifyHash")
end), "p in the tree moves to the previous step")
vim.api.nvim_feedkeys("n", "x", false)
check(vim.wait(10000, function()
  return current_step_line():match("hashOf")
end), "n in the tree moves to the next step")

local select_items
vim.ui.select = function(items, opts, on_choice)
  select_items = vim.tbl_map(opts.format_item, items)
  on_choice(items[2])
end
vim.api.nvim_feedkeys("gp", "x", false)
check(select_items and select_items[1]:match("^Login") and select_items[2]:match("auth/auth_test%.go")
  and select_items[3]:match("Not in any path"), "gp offers every path: " .. vim.inspect(select_items))
check(vim.wait(10000, function()
  return vim.api.nvim_get_current_line() == "func TestLogin(t *testing.T) {"
end), "choosing a path in gp opens it")

vim.api.nvim_feedkeys("-", "x", false)
vim.api.nvim_win_set_cursor(0, { home_row("^    auth/auth%.go  1 hunk"), 0 })
vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
check(vim.wait(10000, function()
  return vim.api.nvim_buf_get_name(0):match("^trail://diff/") and vim.api.nvim_get_current_line() == "import ("
end), "<CR> on a loose hunk opens it")
check(vim.api.nvim_buf_get_lines(graph_buf(), 0, 1, false)[1]:match("Not in any path"), "loose hunks open as their own path")

vim.o.lines = 12
vim.api.nvim_feedkeys("-1", "x", false)
check(vim.wait(10000, function()
  local _, w = graph_buf()
  return w and current_step_line() and current_step_line():match("hashOf")
end), "re-entering a path resumes at the step it was left at")
local _, small_gwin = graph_buf()
check(vim.api.nvim_win_get_height(small_gwin) <= 4, "the tree takes at most a third of the screen, got " .. vim.api.nvim_win_get_height(small_gwin))

local state_file = require("trail.state").path()
check(state_file and state_file:match("/%.git/trail/main%.%.feature%.json$") and vim.fn.filereadable(state_file) == 1,
  "review state is saved under .git/trail: " .. tostring(state_file))
local saved = vim.json.decode(table.concat(vim.fn.readfile(state_file), "\n"))
check(saved.positions["go:auth.Login"] == 3, "the step each path was left at is saved: " .. vim.inspect(saved.positions))
check(vim.tbl_count(saved.seen) > 0, "seen hunks are saved")

vim.api.nvim_feedkeys("-", "x", false)
local function home_line(pattern)
  for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if l:match(pattern) then
      return l
    end
  end
end
check(home_line("^  1  Login  ██████████  3/3 ✓$"), "a path whose steps were all seen is marked done: " .. tostring(home_line("^  1  Login")))
vim.fn.delete(state_file)
-- vim.g.trail_lsp = false keeps the impact walk off the language server.
local engine_mod = require("trail.engine")
local real_request, sent = engine_mod.request, {}
engine_mod.request = function(method, params, cb)
  sent[method] = params
  return real_request(method, params, cb)
end
vim.g.trail_lsp = false
vim.api.nvim_feedkeys("R", "x", false)

check(vim.wait(10000, function()
  return home_line("^  1  Login  .-  0/3$") ~= nil
end), "progress starts over without saved state")
check(vim.wait(10000, function()
  return sent.impact ~= nil
end) and sent.impact.lsp == false, "vim.g.trail_lsp = false is sent with impact: " .. vim.inspect(sent.impact))
vim.g.trail_lsp = nil
sent = {}
vim.api.nvim_feedkeys("R", "x", false)
check(vim.wait(10000, function()
  return sent.impact ~= nil
end) and sent.impact.lsp == true, "the language server is on by default: " .. vim.inspect(sent.impact))
vim.wait(10000, function()
  return home_line("^  1  Login  .-  0/3$") ~= nil
end)
engine_mod.request = real_request
vim.api.nvim_feedkeys("1", "x", false)
check(wait_diff_line("func Login(user string) bool {"), "a path without a saved step starts at step 1")
vim.api.nvim_feedkeys("-", "x", false)
local partial = home_line("^  1  Login  .-  (%d)/3$")
local done = partial and tonumber(partial:match("  (%d)/3$"))
check(done and done >= 1 and done < 3, "only steps whose hunks were on screen count as done: " .. tostring(partial))
vim.api.nvim_feedkeys("1", "x", false)
vim.wait(10000, function()
  return vim.api.nvim_buf_get_name(0):match("^trail://diff/") ~= nil
end)
vim.api.nvim_feedkeys("]s", "x", false)
vim.wait(10000, function()
  return current_step_line():match("VerifyHash")
end)
local login_row
for _, l in ipairs(vim.api.nvim_buf_get_lines((graph_buf()), 0, -1, false)) do
  if l:match("● Login ") then
    login_row = l
  end
end
check(login_row and login_row:match("^✓"), "a done step is marked in the tree: " .. tostring(login_row))

vim.api.nvim_feedkeys("-", "x", false)
vim.fn.writefile({ vim.json.encode({ version = 1, seen = vim.empty_dict(), positions = { ["go:auth.Login"] = 3 }, comments = {} }) }, state_file)
vim.api.nvim_feedkeys("R", "x", false)
vim.wait(10000, function()
  return home_line("^  1  Login  .-  0/3$") ~= nil
end)
vim.api.nvim_feedkeys("1", "x", false)
check(vim.wait(10000, function()
  return vim.api.nvim_buf_get_name(0):match("^trail://diff/")
    and vim.api.nvim_get_current_line() == "func hashOf(h string) string { return strings.ToLower(h) }"
end), "the saved step is resumed from the state file")
vim.api.nvim_feedkeys("-", "x", false)
local jumped = home_line("^  1  Login  .-  (%d)/3$")
local jumped_done = jumped and tonumber(jumped:match("  (%d)/3$"))
check(jumped_done and jumped_done < 3, "hunks jumped over above the screen do not count as seen: " .. tostring(jumped))

-- Comments and the send screen.
vim.o.lines = 24
local inputs = {}
local compose = require("trail.compose")
local real_compose = compose.open
compose.open = function(opts, on_confirm)
  table.insert(inputs, opts)
  local body = table.remove(inputs.answers or {}, 1)
  if body then
    on_confirm(body, opts.kind)
  end
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
check(inputs[1] and inputs[1].kind == "question", "cq opens the popup on the question kind")
local saved_comments = vim.json.decode(table.concat(vim.fn.readfile(state_file), "\n")).comments
check(#saved_comments == 1 and saved_comments[1].kind == "question" and saved_comments[1].side == "new"
  and saved_comments[1].line == 8 and saved_comments[1].text == "func Login(user string) bool {"
  and saved_comments[1].file == "auth/auth.go" and saved_comments[1].body == "why the rename?",
  "the comment is saved with its kind, side, line and line text: " .. vim.inspect(saved_comments))
local cbuf = vim.api.nvim_get_current_buf()
local notes = notes_on(cbuf, "func Login(user string) bool {")
check(notes and notes[1] and notes[1]:match("question") and notes[1]:match("why the rename%?"), "the comment shows under its line: " .. vim.inspect(notes))
local tinted = false
for _, m in ipairs(vim.api.nvim_buf_get_extmarks(cbuf, -1, 0, -1, { details = true })) do
  for _, vl in ipairs(m[4].virt_lines or {}) do
    for _, chunk in ipairs(vl) do
      tinted = tinted or vim.tbl_contains(type(chunk[2]) == "table" and chunk[2] or { chunk[2] }, "TrailQuestionBlock")
    end
  end
end
local block_bg = vim.api.nvim_get_hl(0, { name = "TrailQuestionBlock" }).bg
check(tinted and block_bg and block_bg ~= vim.api.nvim_get_hl(0, { name = "Normal" }).bg,
  "a saved comment sits on a faint background in its kind's colour")

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

-- A comment on several lines selected in visual mode.
local first = row_with(cbuf, "func Login(user string) bool {")
vim.api.nvim_win_set_cursor(0, { first, 0 })
answer("this pair reads backwards")
vim.api.nvim_feedkeys("Vjcn", "x", false)
local ranged = require("trail.state").comments()
ranged = ranged[#ranged]
check(ranged.kind == "nit" and ranged.line == 8 and ranged.last == 9 and ranged.side == "new"
  and ranged.text == "func Login(user string) bool {", "a visual selection saves the first and last line: " .. vim.inspect(ranged))
check(vim.fn.mode() == "n", "the selection is left after commenting")
check(vim.iter(notes_on(cbuf, "\treturn VerifyHash(user)") or {}):any(function(n)
  return n:match("nit 8%-9") and n:match("this pair reads backwards")
end), "a range comment shows under its last line, with its lines")
check(require("trail.comments").markdown("x"):match("%*%*nit%*%* %(lines 8%-9%): this pair reads backwards"), "markdown names the lines")
vim.api.nvim_win_set_cursor(0, { row_with(cbuf, "\treturn VerifyHash(user)"), 0 })
answer("this pair reads better")
vim.api.nvim_feedkeys("ce", "x", false)
check(ranged.body == "this pair reads better", "ce on any line of the range edits it")
local all = require("trail.state").comments()
table.remove(all)
require("trail.state").save()

compose.open = real_compose
local function popup(opts, body)
  local result
  compose.open(vim.tbl_extend("force", { kinds = require("trail.comments").kinds, highlight = require("trail.comments").highlight }, opts),
    function(b, k)
      result = { body = b, kind = k }
    end)
  local win = vim.api.nvim_get_current_win()
  local pbuf = vim.api.nvim_win_get_buf(win)
  if body then
    vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, vim.split(body, "\n"))
  end
  local function press(lhs, mode)
    vim.fn.maparg(lhs, mode, false, true).callback()
  end
  return win, pbuf, press, function()
    return result
  end
end
local pwin, pbuf, press, result = popup({ kind = "question", body = "first" })
check(vim.api.nvim_win_get_config(pwin).relative ~= "" and vim.inspect(vim.api.nvim_win_get_config(pwin).title):match("question"),
  "the comment popup is a float titled with the kind")
check(vim.deep_equal(vim.api.nvim_buf_get_lines(pbuf, 0, -1, false), { "first" }), "an edited comment opens with its text")
press("<Tab>", "n")
check(vim.inspect(vim.api.nvim_win_get_config(pwin).title):match("nit"), "<Tab> moves to the next kind")
press("<Tab>", "n")
press("<Tab>", "n")
vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, { "line one", "", "line two  " })
press("<C-s>", "n")
check(result() and result().body == "line one\n\nline two" and result().kind == "question",
  "<C-s> saves multi-line text and the chosen kind, cycling back to the start: " .. vim.inspect(result()))
check(not vim.api.nvim_win_is_valid(pwin), "saving closes the popup")
pwin, pbuf, press, result = popup({ kind = "nit" }, "dropped")
press("q", "n")
check(result() == nil and not vim.api.nvim_win_is_valid(pwin), "q cancels without saving")
vim.g.trail_default_comment_kind = "nit"
check(require("trail.comments").default_kind() == "nit", "the default kind is configurable")
vim.g.trail_default_comment_kind = "bogus"
check(require("trail.comments").default_kind() == "blocking", "an unknown default kind falls back to blocking")
vim.g.trail_default_comment_kind = nil

local list = vim.json.decode(table.concat(vim.fn.readfile(state_file), "\n"))
list.comments[1].line = 2
vim.fn.writefile({ vim.json.encode(list) }, state_file)
vim.api.nvim_feedkeys("-", "x", false)
vim.api.nvim_feedkeys("R", "x", false)
vim.wait(15000, function()
  return home_line("^  1  Login ") ~= nil
end)
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
check(#vim.api.nvim_list_tabpages() == 2, "the send screen opens in the review tab, got " .. #vim.api.nvim_list_tabpages())
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
  return b and current_step_line() and current_step_line():match("● Login ")
end), "<CR> on a comment opens its step")

-- GitHub pull requests: a fake gh points at a local "remote" with refs/pull/7/head.
local remote = repo .. "-remote"
vim.system({ "git", "clone", "-q", "--bare", repo, remote }):wait()
vim.system({ "git", "-C", remote, "update-ref", "refs/pull/7/head", "feature" }):wait()
vim.system({ "git", "-C", remote, "branch", "-D", "feature" }):wait()
local head_sha = vim.trim(vim.system({ "git", "-C", repo, "rev-parse", "feature" }, { text = true }):wait().stdout)
local gh = repo .. "-gh"
vim.fn.writefile({
  "#!/bin/sh",
  string.format([[echo '{"baseRefName":"main","headRefName":"feature","headRefOid":"%s","title":"Add hashing","url":"file://%s/pull/7","body":"","author":{"login":"alice"}}']], head_sha, remote),
}, gh)
vim.fn.setfperm(gh, "rwxr-xr-x")
vim.env.TRAIL_GH = gh
require("trail.engine").stop()
vim.cmd("Trail #7")
local prbuf = vim.api.nvim_get_current_buf()
check(vim.wait(10000, function()
  return vim.api.nvim_buf_get_lines(prbuf, 0, 1, false)[1] == "#7 Add hashing · alice → main"
end), "a pull request opens with its title: " .. vim.inspect(vim.api.nvim_buf_get_lines(prbuf, 0, 1, false)))
check(vim.iter(vim.api.nvim_buf_get_lines(prbuf, 0, -1, false)):any(function(l)
  return l:match("^  1  Login  .-  0/3$")
end) or vim.wait(15000, function()
  return vim.iter(vim.api.nvim_buf_get_lines(prbuf, 0, -1, false)):any(function(l)
    return l:match("^  1  Login  .-  0/3$")
  end)
end), "the pull request is reviewed like a branch")
check(require("trail.state").path():match("/trail/pr%-7%.json$"), "its review state is kept per pull request number")
vim.fn.delete(remote, "rf")
vim.fn.delete(gh)

-- A changed type pulls in the unchanged code that uses it.
local types = vim.fn.tempname()
vim.fn.mkdir(types .. "/store", "p")
local function tsh(cmd)
  local out = vim.system({ "sh", "-c", cmd }, { cwd = types, text = true }):wait()
  assert(out.code == 0, cmd .. ": " .. out.stderr)
end
tsh("git init -q -b main && git config user.email t@t && git config user.name t")
vim.fn.writefile(vim.split("package store\n\ntype Store struct {\n\tn int\n}", "\n"), types .. "/store/store.go")
vim.fn.writefile(vim.split("package store\n\nfunc Run(s *Store) int {\n\treturn s.n\n}", "\n"), types .. "/store/run.go")
tsh("git add -A && git commit -qm base && git checkout -qb feature")
vim.fn.writefile(vim.split("package store\n\ntype Store struct {\n\tn    int\n\tname string\n}", "\n"), types .. "/store/store.go")
tsh("git add -A && git commit -qm feature")
vim.cmd.cd(types)
vim.cmd("Trail main..feature")
local tbuf = vim.api.nvim_get_current_buf()
local function tline(pattern)
  return vim.iter(vim.api.nvim_buf_get_lines(tbuf, 0, -1, false)):find(function(l)
    return l:match(pattern)
  end)
end
check(vim.wait(15000, function()
  return tline("^  1  Store  ░░░░░░░░░░  0/1$") ~= nil
end), "a changed type gets a path: " .. table.concat(vim.api.nvim_buf_get_lines(tbuf, 0, -1, false), "\n"))
vim.api.nvim_feedkeys("1", "x", false)
check(vim.wait(10000, function()
  return vim.api.nvim_buf_get_name(0):match("^trail://diff/store/store%.go$") and vim.api.nvim_get_current_line() == "type Store struct {"
end), "the type's step opens its diff: " .. vim.api.nvim_buf_get_name(0))
local type_tree = table.concat(vim.api.nvim_buf_get_lines((graph_buf()), 0, -1, false), "\n")
check(type_tree:match("\n◆ Run   entry ") or type_tree:match("\n  ◆ Run   entry "), "the path starts at the unchanged code using the type: " .. type_tree)
check(type_tree:match("└─ ● Store   step 1"), "and reaches the type")
local _, twin = graph_buf()
vim.api.nvim_set_current_win(twin)
for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
  if l:match("◆ Run") then
    vim.api.nvim_win_set_cursor(twin, { i, 0 })
  end
end
vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
check(vim.wait(10000, function()
  local w = panes()[1]
  return w and vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)):match("^trail://diff/store/run%.go$")
    and vim.api.nvim_win_call(w, function()
      return vim.api.nvim_get_current_line() == "func Run(s *Store) int {"
    end)
end), "<CR> on unchanged code in the tree shows it in its file")
vim.fn.delete(types, "rf")

-- Folds: what leads to no change is folded until opened.
local folds = vim.fn.tempname()
vim.fn.mkdir(folds .. "/a", "p")
local function fsh(cmd)
  local out = vim.system({ "sh", "-c", cmd }, { cwd = folds, text = true }):wait()
  assert(out.code == 0, cmd .. ": " .. out.stderr)
end
local function a_go(n)
  return "package a\n\nfunc Entry() {\n\thop1()\n\tside()\n}\n\nfunc hop1() {\n\thop2()\n}\n\nfunc hop2() {\n\tWork()\n}\n\nfunc side() {\n\tWork()\n}\n\nfunc Other() {\n\tWork()\n}\n\nfunc Work() int {\n\tfirst()\n\tsecond()\n\treturn "
    .. n .. "\n}\n\nfunc first() {}\n\nfunc second() {}\n\nfunc Lone() int {\n\treturn " .. n .. "\n}"
end
fsh("git init -q -b main && git config user.email t@t && git config user.name t")
vim.fn.writefile(vim.split(a_go(1), "\n"), folds .. "/a/a.go")
vim.fn.writefile(vim.split("package a\n\nfunc TestLone(t *testing.T) {\n\tLone()\n}", "\n"), folds .. "/a/a_test.go")
fsh("git add -A && git commit -qm base && git checkout -qb feature")
vim.fn.writefile(vim.split(a_go(2), "\n"), folds .. "/a/a.go")
fsh("git add -A && git commit -qm feature")
vim.cmd.cd(folds)
vim.cmd("Trail main..feature")
local fbuf = vim.api.nvim_get_current_buf()
check(vim.wait(15000, function()
  return vim.iter(vim.api.nvim_buf_get_lines(fbuf, 0, -1, false)):any(function(l)
    return l:match("^  1  Work ")
  end)
end), "the folds review loads: " .. table.concat(vim.api.nvim_buf_get_lines(fbuf, 0, -1, false), "\n"))
check(vim.iter(vim.api.nvim_buf_get_lines(fbuf, 0, -1, false)):any(function(l)
  return l:match("^  2  Lone  ░░░░░░░░░░  0/1$")
end), "a change only tests call gets its own path: " .. table.concat(vim.api.nvim_buf_get_lines(fbuf, 0, -1, false), "\n"))
vim.api.nvim_feedkeys("1", "x", false)
vim.wait(10000, function()
  return vim.api.nvim_buf_get_name(0):match("^trail://diff/") ~= nil
end)
local fold_buf, fold_win = graph_buf()
local function tree_lines()
  return vim.api.nvim_buf_get_lines(fold_buf, 0, -1, false)
end
local function tree_row(pattern)
  for i, l in ipairs(tree_lines()) do
    if l:match(pattern) then
      return i
    end
  end
end
check(tree_row("^  ◆ Entry   entry%s+a$") and tree_row("^  └─ ▸ 2 functions$") and tree_row("^▶    └─ ● Work   step 1$")
  and tree_row("^  ▸ 1 more entry point reaches this path without other changes$") and not tree_row("hop") and not tree_row("first")
  and not tree_row("joins above"),
  "a path opens showing its changes, with the functions between them folded: " .. table.concat(tree_lines(), "\n"))
vim.api.nvim_set_current_win(fold_win)
vim.api.nvim_win_set_cursor(fold_win, { tree_row("▸ 2 functions"), 0 })
vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
check(tree_row("^  └─ ○ hop1$") and tree_row("^     └─ ○ hop2$") and tree_row("^▶       └─ ● Work   step 1$")
  and not tree_row("▸ 2 functions") and not tree_row("first"),
  "<CR> on the link shows the functions between the changes: " .. table.concat(tree_lines(), "\n"))
check(vim.api.nvim_get_current_line():match("hop1"), "the cursor stays where the link was")

vim.api.nvim_feedkeys("a", "x", false)
check(tree_row("^  ├─ ○ hop1$") and tree_row("^▶ │     └─ ● Work   step 1$") and tree_row("^  │        └─ ▸ 2 more$")
  and tree_row("^  └─ ▸ 2 more$"), "a shows every function on the way, stopping at the last change: " .. table.concat(tree_lines(), "\n"))
vim.api.nvim_win_set_cursor(fold_win, { tree_row("^  │        └─ ▸ 2 more$"), 0 })
vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
check(tree_row("^  │        ├─ ○ first$") and tree_row("^  │        └─ ○ second$") and not tree_row("^  │        └─ ▸ 2 more$"),
  "<CR> on a fold opens it: " .. table.concat(tree_lines(), "\n"))
check(vim.api.nvim_get_current_win() == fold_win and vim.api.nvim_get_current_line():match("first"),
  "the cursor stays where the fold was")
vim.api.nvim_win_set_cursor(fold_win, { tree_row("▸ 1 more entry point"), 0 })
vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
check(tree_row("^  ◆ Other   entry") and tree_row("^  └─ ● Work   modified · ↑ joins above$"),
  "<CR> on the entry points line shows the trees that only join: " .. table.concat(tree_lines(), "\n"))
vim.api.nvim_feedkeys("c", "x", false)
check(tree_row("▸ 2 functions") and tree_row("▸ 1 more entry point") and not tree_row("Other") and not tree_row("hop"),
  "c folds back to the changes: " .. table.concat(tree_lines(), "\n"))
vim.api.nvim_win_set_cursor(fold_win, { tree_row("◆ Entry"), 0 })
vim.api.nvim_feedkeys("K", "x", false)
check(vim.wait(10000, function()
  local w = vim.iter(vim.api.nvim_tabpage_list_wins(0)):find(function(w)
    return vim.api.nvim_win_get_config(w).relative ~= ""
  end)
  return w and vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, 1, false)[1] == "func Entry() {"
end), "K on a row shows that function's code")
vim.fn.delete(folds, "rf")

-- An engine that stops while working out the impact: the screen says so instead of waiting forever.
-- Submitting a pull request review to GitHub from the send screen.
do
  local eng = require("trail.engine")
  local real_request = eng.request
  local function rev(ref)
    return vim.trim(vim.fn.system({ "git", "-C", repo, "rev-parse", ref }))
  end
  local base_sha, head_sha = rev("main"), rev("feature")
  local submitted
  local thread_reads = 0
  local function comment(author, body)
    return { author = author, body = body, created_at = "2026-11-17T10:00:00Z", url = "https://github.com/owner/repo/pull/7#c" }
  end
  local pr_threads = {
    { id = "T4", path = "auth/auth.go", side = "new", line = 9, resolved = false, outdated = false, diff_hunk = "",
      comments = { comment("alice", "start here: " .. string.rep("every word of this note should wrap ", 6)) } },
    { id = "T1", path = "auth/auth.go", side = "new", line = 13, resolved = false, outdated = false, diff_hunk = "",
      comments = { comment("alice", "why compare?"), comment("bob", "**question:** it guards\r\nreally") } },
    { id = "T2", path = "auth/auth.go", side = "new", line = 16, resolved = true, outdated = false, diff_hunk = "",
      comments = { comment("carol", "lowercase ok?") } },
    { id = "T3", path = "auth/auth.go", side = "old", line = vim.NIL, original_line = 6, resolved = false, outdated = true,
      diff_hunk = "@@ -5,3 +5,1 @@\n func Login(u string) bool {\n-\tGone()", comments = { comment("dave", "gone?") } },
  }
  local pr_numbers = {}
  local updates = {}
  eng.request = function(method, params, cb)
    if method == "pull_request" then
      table.insert(pr_numbers, params.number)
    end
    if method == "pull_requests" then
      return vim.schedule(function()
        cb(nil, {
          { number = 7, title = "Add hashing", author = "alice", head_ref_name = "feature", is_draft = false, review_requested = true },
          { number = 3, title = "Fix docs", author = "bob", head_ref_name = "docs", is_draft = true, review_requested = false },
        })
      end)
    elseif method == "update_thread" then
      table.insert(updates, params)
      return vim.schedule(function()
        cb(nil, {})
      end)
    elseif method == "review_threads" then
      thread_reads = thread_reads + 1
      return vim.schedule(function()
        cb(nil, pr_threads)
      end)
    elseif method == "pull_request" then
      return vim.schedule(function()
        cb(nil, { number = 7, title = "Add hashing", url = "https://github.com/owner/repo/pull/7", base = base_sha, head = head_sha,
          author = "alice", description = "Hashes passwords.\r\nSecond line.", base_branch = "main", head_branch = "feature" })
      end)
    elseif method == "submit_review" then
      submitted = params
      return vim.schedule(function()
        cb(nil, { url = "https://github.com/owner/repo/pull/7#pullrequestreview-1", inline = 1, in_body = #params.comments - 1,
          inline_comments = #params.comments > 0 and { 0 } or {} })
      end)
    end
    return real_request(method, params, cb)
  end
  vim.cmd.cd(repo)
  vim.cmd("Trail  #7 ")
  local prbuf = vim.api.nvim_get_current_buf()
  check(vim.wait(15000, function()
    return vim.iter(vim.api.nvim_buf_get_lines(prbuf, 0, -1, false)):any(function(l)
      return l:match("^  1  Login ")
    end)
  end), "the pull request review opens")
  check(vim.wait(5000, function()
    return vim.iter(vim.api.nvim_buf_get_lines(prbuf, 0, -1, false)):any(function(l)
      return l:match("^  1  Login  ░░░░░░░░░░  0/3  3 threads$")
    end)
  end), "a path row counts the threads on its functions, outdated ones aside")
  local function prlines()
    return vim.api.nvim_buf_get_lines(prbuf, 0, -1, false)
  end
  local function pr_row(pattern)
    for k, l in ipairs(prlines()) do
      if l:match(pattern) then
        return k
      end
    end
  end
  check(prlines()[1] == "#7 Add hashing · alice → main" and prlines()[2]:find("░", 1, true) == 1
    and prlines()[2]:match("  0/%d+ hunks · not submitted$"),
    "a pull request's header names it, its author and base, and whether it was submitted: " .. table.concat(prlines(), " | "))
  check(pr_row("^▸ Description$") and not pr_row("Hashes passwords"), "the description starts folded")
  vim.api.nvim_win_set_cursor(0, { pr_row("^▸ Description$"), 0 })
  vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
  check(pr_row("^  Hashes passwords%.$") and pr_row("^  Second line%.$"), "<CR> opens the description")
  check(pr_row("^Needs attention$") and pr_row("^  ● 3 unresolved threads$"),
    "Needs attention counts the unresolved threads, outdated ones included")
  vim.api.nvim_win_set_cursor(0, { pr_row("^  ● 3 unresolved threads$"), 0 })
  vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
  check(vim.api.nvim_buf_get_name(0):match("trail://threads$"), "<CR> on the unresolved threads opens the thread list")
  vim.api.nvim_feedkeys("-", "x", false)
  local astore = require("trail.state")
  table.insert(astore.comments(), { id = "b", kind = "blocking", body = "stop", file = "auth/auth.go", side = "new", line = 9,
    text = "\treturn VerifyHash(user)" })
  require("trail").refresh_home()
  check(pr_row("^  ● 1 blocking comment$"), "Needs attention counts your blocking comments")
  vim.api.nvim_win_set_cursor(0, { pr_row("^  ● 1 blocking comment$"), 0 })
  vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
  check(vim.api.nvim_buf_get_name(0):match("trail://send$"), "<CR> on the blocking comments opens the send screen")
  table.remove(astore.comments())
  astore.save()
  vim.api.nvim_feedkeys("-", "x", false)
  check(thread_reads == 1, "the threads are read once when the pull request opens")

  vim.api.nvim_feedkeys("T", "x", false)
  local tbuf = vim.api.nvim_get_current_buf()
  local ttext = table.concat(vim.api.nvim_buf_get_lines(tbuf, 0, -1, false), "\n")
  check(vim.api.nvim_buf_get_name(tbuf):match("trail://threads$") and ttext:match("auth/auth%.go")
    and ttext:match("\n +~6  outdated  dave  gone%?") and ttext:match("\n +16  ✓ +carol  lowercase ok%?")
    and ttext:match("\n +13  ● +alice  why compare%?  · 2 comments") and ttext:match("%-\tGone%(%)"),
    "T lists every thread, outdated ones with their old code: " .. ttext)
  local trow, outdated_row
  for k, l in ipairs(vim.api.nvim_buf_get_lines(tbuf, 0, -1, false)) do
    if l:match("why compare") then
      trow = k
    elseif l:match("gone%?") then
      outdated_row = k
    end
  end
  local function write_reply(lines, tabs)
    local box = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(box, 0, -1, false, lines)
    for _ = 1, tabs do
      vim.fn.maparg("<Tab>", "n", false, true).callback()
    end
    vim.fn.maparg("<C-s>", "n", false, true).callback()
  end
  vim.api.nvim_win_set_cursor(0, { outdated_row, 0 })
  vim.api.nvim_feedkeys("r", "x", false)
  check(vim.inspect(vim.api.nvim_win_get_config(0).title):match("reply"), "r in the list opens the box on reply")
  write_reply({ "Still needed, see Tidy." }, 0)
  check(vim.wait(3000, function()
    return #updates == 1
  end) and updates[1].thread == "T3" and updates[1].body == "Still needed, see Tidy." and updates[1].state == nil
    and updates[1].url == "https://github.com/owner/repo/pull/7" and updates[1].number == 7,
    "an outdated thread can be replied to from the list: " .. vim.inspect(updates))
  check(vim.wait(3000, function()
    return thread_reads == 2
  end), "the threads are read again after a reply")
  thread_reads = 1
  vim.api.nvim_win_set_cursor(0, { trow, 0 })
  vim.api.nvim_feedkeys("\r", "x", false)
  check(wait_diff_line("\treturn hashOf(h) == h") and current_step_line():match("VerifyHash"),
    "<CR> on a thread opens its step at its line")
  vim.api.nvim_feedkeys("r", "x", false)
  write_reply({ "Fair, it guards.", "Resolving." }, 1)
  check(vim.wait(3000, function()
    return #updates == 2
  end) and updates[2].thread == "T1" and updates[2].body == "Fair, it guards.\nResolving." and updates[2].state == "resolve",
    "r on a thread's line replies, and <Tab> resolves it too: " .. vim.inspect(updates[2]))
  check(vim.api.nvim_buf_get_name(0):match("^trail://diff/"), "the diff has the focus again after replying")
  vim.api.nvim_feedkeys("r", "x", false)
  write_reply({}, 1)
  check(vim.wait(3000, function()
    return #updates == 3
  end) and updates[3].body == "" and updates[3].state == "resolve", "resolving needs no text")
  vim.api.nvim_feedkeys("r", "x", false)
  write_reply({}, 0)
  vim.wait(300)
  check(#updates == 3, "an empty reply posts nothing")
  vim.wait(300)
  thread_reads = 1
  local dbuf = vim.api.nvim_get_current_buf()
  local function notes_text(text)
    return table.concat(notes_on(vim.api.nvim_get_current_buf(), text) or {}, "\n")
  end
  local function popup_open()
    vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
    local win = vim.api.nvim_get_current_win()
    local config = vim.api.nvim_win_get_config(win)
    local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), "\n")
    return config.relative ~= "" and win, text, vim.inspect(config.title)
  end
  local function press(lhs)
    vim.fn.maparg(lhs, "n", false, true).callback()
  end
  check(notes_text("\treturn hashOf(h) == h"):match("^┃ ● alice: why compare%?  · 2 comments  <CR> opens%s*$"),
    "a thread takes one line in the diff: " .. notes_text("\treturn hashOf(h) == h"))
  local pwin, ptext, ptitle = popup_open()
  check(pwin and ptitle:match("● auth/auth%.go:13"), "<CR> on a thread's line opens it in a popup: " .. ptitle)
  check(ptext:match("alice · 2026%-11%-17 *\n +why compare%? *\n *\n +bob · 2026%-11%-17 *\n +question  it guards *\n +really"),
    "the popup shows each comment's author, date and text: " .. ptext)
  check(not ptext:match("\r") and not ptext:match("%*%*"), "with the kind as a tag, and no markdown or carriage returns")
  press("r")
  check(not vim.api.nvim_win_is_valid(pwin) and vim.inspect(vim.api.nvim_win_get_config(0).title):match("reply"),
    "r in the popup closes it and opens the reply box")
  press("q")
  check(vim.api.nvim_buf_get_name(0):match("^trail://diff/") and #updates == 3, "cancelling the reply posts nothing")
  pwin = popup_open()
  press("q")
  check(pwin and not vim.api.nvim_win_is_valid(pwin) and vim.api.nvim_buf_get_name(0):match("^trail://diff/"),
    "q closes the popup and returns to the diff")
  vim.api.nvim_feedkeys("]t", "x", false)
  check(wait_diff_line("func hashOf(h string) string { return strings.ToLower(h) }") and current_step_line():match("hashOf"),
    "]t goes to the next thread, in the next step")
  local hash_line = "func hashOf(h string) string { return strings.ToLower(h) }"
  check(notes_text(hash_line):match("✓ resolved · carol: lowercase ok%?  <CR> opens"), "a resolved thread takes one line too: " .. notes_text(hash_line))
  pwin, ptext, ptitle = popup_open()
  check(pwin and ptitle:match("✓ resolved") and ptext:match("carol · 2026"), "<CR> opens a resolved thread the same way")
  press("<Esc>")
  vim.api.nvim_feedkeys("]t", "x", false)
  vim.wait(300)
  check(vim.api.nvim_get_current_line() == hash_line, "]t stops at the last thread of the path")
  vim.api.nvim_feedkeys("[t", "x", false)
  check(wait_diff_line("\treturn hashOf(h) == h"), "[t goes back to the previous thread")
  vim.api.nvim_feedkeys("[t", "x", false)
  check(wait_diff_line("\treturn VerifyHash(user)") and current_step_line():match("Login"), "[t continues into the step before")
  local summary = notes_text("\treturn VerifyHash(user)")
  check(not summary:match("\n") and summary:match("…") and vim.fn.strdisplaywidth(summary) < 100,
    "a long comment is cut short on its line: " .. summary)
  pwin, ptext = popup_open()
  local plines = vim.split(ptext, "\n")
  check(pwin and #plines >= 4 and vim.iter(plines):all(function(l)
    return vim.fn.strdisplaywidth(vim.trim(l)) <= 84
  end), "and wraps at 80 columns in the popup: " .. ptext)
  press("q")
  vim.api.nvim_feedkeys("-", "x", false)
  check(vim.wait(3000, function()
    return vim.api.nvim_get_current_buf() == prbuf
  end), "- goes back to the paths screen")

  local pstore = require("trail.state")
  table.insert(pstore.comments(), { id = "1", kind = "nit", body = "name it user", file = "auth/auth.go", side = "new",
    line = 8, last = 9, text = "func Login(user string) bool {" })
  table.insert(pstore.comments(), { id = "2", kind = "question", body = "far from the diff", file = "auth/auth.go", side = "new",
    line = 30, text = "func Tidy() {" })
  pstore.save()
  vim.api.nvim_feedkeys("S", "x", false)
  local pbuf = vim.api.nvim_get_current_buf()
  local function ptext()
    return table.concat(vim.api.nvim_buf_get_lines(pbuf, 0, -1, false), "\n")
  end
  check(ptext():match("P submits it to GitHub"), "the send screen offers submitting on a pull request")
  vim.api.nvim_feedkeys("P", "x", false)
  local box = vim.api.nvim_get_current_buf()
  check(vim.api.nvim_win_get_config(0).relative ~= "" and vim.inspect(vim.api.nvim_win_get_config(0).title):match("comment"),
    "P opens the overall comment box on the verdict")
  vim.api.nvim_buf_set_lines(box, 0, -1, false, { "Ship it" })
  vim.fn.maparg("<Tab>", "n", false, true).callback()
  vim.fn.maparg("<C-s>", "n", false, true).callback()
  check(vim.wait(5000, function()
    return submitted ~= nil
  end), "the review is submitted")
  check(submitted and submitted.url == "https://github.com/owner/repo/pull/7" and submitted.number == 7
    and submitted.commit == head_sha and submitted.event == "APPROVE" and submitted.body == "Ship it"
    and #submitted.comments == 2 and submitted.comments[1].path == "auth/auth.go" and submitted.comments[1].side == "new"
    and submitted.comments[1].line == 8 and submitted.comments[1].last == 9
    and submitted.comments[1].body == "**nit:** name it user", "the review carries the verdict, body and comments: " .. vim.inspect(submitted))
  check(vim.wait(2000, function()
    return ptext():match("far from the diff  · sent") ~= nil and ptext():match("Last submitted at " .. head_sha:sub(1, 7)) ~= nil
  end), "a comment that went into the overall comment stays, marked sent: " .. ptext())
  check(not ptext():match("name it user") and not vim.iter(pstore.comments()):any(function(c)
    return c.body == "name it user"
  end), "a comment posted inline is a GitHub thread now, not a trail comment")
  check(vim.wait(2000, function()
    return thread_reads == 2
  end), "the threads are read again after submitting")
  check(pstore.verdict() == "approve", "the verdict chosen is kept")
  submitted = nil
  vim.api.nvim_feedkeys("P", "x", false)
  vim.fn.maparg("<C-s>", "n", false, true).callback()
  check(vim.wait(5000, function()
    return submitted ~= nil
  end) and #submitted.comments == 0 and submitted.event == "APPROVE", "a second submit leaves out comments already sent")
  vim.wait(200)
  table.insert(pstore.comments(), { id = "skip", kind = "nit", body = "later", file = "auth/auth.go", side = "new",
    line = 8, text = "func Login(user string) bool {", unselected = true })
  table.insert(pstore.comments(), { id = "send", kind = "nit", body = "now", file = "auth/auth.go", side = "new",
    line = 8, text = "func Login(user string) bool {" })
  table.insert(pstore.comments(), { id = "re", kind = "reply", body = "then test it", file = "auth/auth.go", side = "new",
    line = 9, text = "", reply_to = "T1" })
  pstore.save()
  submitted, updates = nil, {}
  vim.api.nvim_feedkeys("P", "x", false)
  vim.fn.maparg("<C-s>", "n", false, true).callback()
  check(vim.wait(5000, function()
    return submitted ~= nil and #updates == 1
  end) and #submitted.comments == 1 and submitted.comments[1].body == "**nit:** now"
    and updates[1].thread == "T1" and updates[1].body == "then test it" and not updates[1].state,
    "sending takes only the selected comments, and posts replies to their threads: " .. vim.inspect({ submitted, updates }))
  check(vim.wait(2000, function()
    return not vim.iter(pstore.comments()):any(function(c)
      return c.id == "re"
    end)
  end) and vim.iter(pstore.comments()):any(function(c)
    return c.id == "skip" and not c.sent
  end), "a reply sent is the thread's now; a comment left out stays to send later")
  local dstore = require("trail.state")
  table.insert(dstore.comments(), { id = "old", kind = "question", body = "it guards\nreally", file = "auth/auth.go", side = "new",
    line = 13, text = "\treturn hashOf(h) == h", sent = true })
  table.insert(dstore.comments(), { id = "unsent", kind = "question", body = "it guards\nreally", file = "auth/auth.go", side = "new",
    line = 13, text = "\treturn hashOf(h) == h" })
  dstore.save()
  vim.cmd.tabnext()
  vim.cmd("Trail #7")
  check(vim.wait(5000, function()
    return not vim.iter(require("trail.state").comments()):any(function(c)
      return c.id == "old"
    end)
  end), "a sent comment GitHub already has as a thread comment is dropped once threads load")
  check(vim.iter(require("trail.state").comments()):any(function(c)
    return c.id == "unsent"
  end), "an unsent comment with the same text stays")
  vim.cmd("Trail https://github.com/owner/repo/pull/7/files")
  check(vim.wait(5000, function()
    return #pr_numbers == 3 and pr_numbers[3] == 7
  end) and vim.wait(5000, function()
    return (vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] or ""):match("^#7 Add hashing · alice → main$") ~= nil
  end), "a pull request's url opens it like #7, and so does #7 with spaces around it: " .. vim.inspect(pr_numbers))
  local real_select, offered = vim.ui.select, nil
  vim.ui.select = function(items, opts, on_choice)
    offered = { prompt = opts.prompt, items = vim.tbl_map(opts.format_item, items) }
    on_choice(items[1])
  end
  vim.cmd("Trail")
  check(vim.wait(5000, function()
    return offered ~= nil
  end) and offered.prompt == "Pull request to review"
    and offered.items[1] == "#7  Add hashing  · alice · feature · review requested"
    and offered.items[2] == "#3  Fix docs  · bob · docs · draft",
    ":Trail alone offers the open pull requests, those asking for your review first: " .. vim.inspect(offered))
  check(vim.wait(5000, function()
    return #pr_numbers == 4 and pr_numbers[4] == 7
  end) and vim.wait(5000, function()
    return (vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] or "") == "#7 Add hashing · alice → main"
  end), "picking one opens it")
  vim.ui.select = real_select

  vim.g.trail_app = true
  vim.cmd("tabnew")
  require("trail").open("")
  local function screen_text()
    return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  end
  check(screen_text():match("Listing open pull requests") and require("trail.help").screen(0) == "pulls",
    "the app shows a pull request screen at once, saying it is listing them: " .. screen_text())
  local pulls_tabs = vim.api.nvim_eval_statusline(require("trail").tabline(), { use_tabline = true }).str
  check(vim.trim(pulls_tabs) == "trail  Pull requests", "its tabline names only that screen: " .. pulls_tabs)
  vim.api.nvim_feedkeys("2", "x", false)
  check(vim.wait(5000, function()
    return #pr_numbers == 5
  end) and pr_numbers[5] == 3, "a number typed while listing picks that pull request once they are listed")
  vim.cmd("tabnew")
  require("trail").open("")
  check(vim.wait(5000, function()
    return screen_text():match("#3")
  end) and screen_text():match("\n *1 +#7 +Add hashing +alice · feature · review requested")
    and screen_text():match("\n *2 +#3 +Fix docs +bob · docs · draft"),
    "the screen lists them numbered, those asking for your review first: " .. screen_text())
  vim.api.nvim_win_set_cursor(0, { vim.fn.search("#7", "n"), 0 })
  vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
  check(vim.wait(5000, function()
    return #pr_numbers == 6
  end) and pr_numbers[6] == 7, "<CR> opens the one under the cursor")
  vim.g.trail_app = nil
  vim.cmd("silent! tabonly")
  eng.request = real_request
end

-- A review that can't be opened says why instead of loading forever.
vim.cmd("Trail no-such-branch..feature")
local failed = vim.api.nvim_get_current_buf()
check(vim.wait(10000, function()
  local text = table.concat(vim.api.nvim_buf_get_lines(failed, 0, -1, false), "\n")
  return text:match("^trail: could not open no%-such%-branch%.%.feature\n\n.*no%-such%-branch.*\n\nR tries again") ~= nil
end), "a failed open shows the error in place of the loading text: "
  .. table.concat(vim.api.nvim_buf_get_lines(failed, 0, -1, false), " | "))

local stopping = repo .. "-stopping-engine"
vim.fn.writefile({
  "#!/bin/sh",
  "while IFS= read -r line; do",
  "  id=$(printf '%s' \"$line\" | sed -n 's/.*\"id\":\\([0-9]*\\).*/\\1/p')",
  "  case \"$line\" in",
  "    *'\"method\":\"open\"'*)",
  "      printf '{\"jsonrpc\":\"2.0\",\"id\":%s,\"result\":{\"base_commit\":\"aaaaaaa1\",\"head_commit\":\"bbbbbbb2\",\"files\":[],\"hunks\":[],\"nodes\":[],\"edges\":[],\"tests\":[],\"paths\":[],\"unassigned\":[],\"uncovered\":[]}}\\n' \"$id\" ;;",
  "    *'\"method\":\"impact\"'*)",
  "      echo 'fake engine: walking' >&2",
  "      sleep 2",
  "      exit 3 ;;",
  "  esac",
  "done",
}, stopping)
vim.fn.setfperm(stopping, "rwxr-xr-x")
require("trail.engine").stop()
vim.g.trail_engine = stopping
vim.cmd.cd(repo)
vim.cmd("Trail main..feature")
local sbuf2 = vim.api.nvim_get_current_buf()
local log_path = require("trail.engine").log_path
local function stop_line(pattern)
  return vim.iter(vim.api.nvim_buf_get_lines(sbuf2, 0, -1, false)):find(function(l)
    return l:match(pattern)
  end)
end
check(vim.wait(5000, function()
  return stop_line("^  Working out the paths… %d+s") ~= nil
end), "while waiting, the screen shows how long it has been: " .. table.concat(vim.api.nvim_buf_get_lines(sbuf2, 0, -1, false), "\n"))
check(stop_line("engine log: " .. vim.pesc(vim.fn.fnamemodify(log_path, ":~"))), "and where the engine's log is")
check(vim.wait(10000, function()
  return stop_line("^  The impact could not be worked out: the engine stopped") ~= nil
end), "an engine that stops is reported instead of waiting forever: " .. table.concat(vim.api.nvim_buf_get_lines(sbuf2, 0, -1, false), "\n"))
check(vim.iter(vim.fn.readfile(log_path)):any(function(l)
  return l:match("fake engine: walking")
end), "the engine's output goes to the log file")
vim.g.trail_engine = nil
vim.fn.delete(stopping)

-- The trail app: the tree on the left, a tabline of screens, a status line
-- with the mode and keys, and threads in a pane on the right.
vim.g.trail_app, vim.g.trail_tree = true, "left"
vim.cmd.cd(repo)
vim.cmd("Trail main..feature")
local app = require("trail")
local abuf = vim.api.nvim_get_current_buf()
check(vim.wait(15000, function()
  return vim.iter(vim.api.nvim_buf_get_lines(abuf, 0, -1, false)):any(function(l)
    return l:match("^  1  Login ")
  end)
end), "the app opens the review")
check(#vim.api.nvim_list_tabpages() == 1, "the app keeps a single tab")
local function evaluated(expr, opts)
  return vim.api.nvim_eval_statusline(expr, opts or {}).str
end
local tabline = evaluated(app.tabline(), { use_tabline = true })
check(tabline:match("^ trail  Overview  Paths  Commits  Send ") and tabline:match("main%.%.feature $"),
  "the tabline names the screens and the review: " .. tabline)
local function selected_tab()
  local hl = vim.api.nvim_eval_statusline(app.tabline(), { use_tabline = true, highlights = true })
  for k, h in ipairs(hl.highlights) do
    if h.group == "TabLineSel" then
      local stop = hl.highlights[k + 1] and hl.highlights[k + 1].start or #hl.str
      return vim.trim(hl.str:sub(h.start + 1, stop))
    end
  end
end
check(selected_tab() == "Overview", "the overview's tab is marked: " .. tostring(selected_tab()))
local status = evaluated(app.statusline(), { maxwidth = 200 })
check(status:match("^ NORMAL  overview") and status:match("⏎ open  1%-9 path  C commits  S send"), "the status line shows the mode and the screen's keys: " .. status)
vim.api.nvim_feedkeys("1", "x", false)
check(vim.wait(10000, function()
  return vim.api.nvim_buf_get_name(0):match("^trail://diff/")
end), "a path opens from the app's overview")
local tree_win = vim.fn.bufwinid("trail://path")
local diff_win = vim.api.nvim_get_current_win()
check(tree_win ~= -1 and vim.api.nvim_win_get_position(tree_win)[2] == 0
  and vim.api.nvim_win_get_width(tree_win) == 38 and vim.api.nvim_win_get_position(diff_win)[2] > 38
  and vim.api.nvim_win_get_position(tree_win)[1] == vim.api.nvim_win_get_position(diff_win)[1],
  "the tree sits on the left of the diff, at a fixed width")
check(selected_tab() == "Login" and evaluated(app.tabline(), { use_tabline = true }):match("step 1/3  [█░]+ %d/3 $"),
  "inside a path the tabline marks it and shows the step and progress: " .. evaluated(app.tabline(), { use_tabline = true }))
local dstatus = evaluated(app.statusline(), { maxwidth = 200 })
check(dstatus:match("^ NORMAL  auth/auth%.go") and dstatus:match("%]c change"), "in the diff the status line names the file and the diff's keys: " .. dstatus)
local narrow = evaluated(app.statusline(), { maxwidth = 40 })
check(narrow:match("^ NORMAL  auth/auth%.go"), "a narrow status line cuts the keys, not the mode and file: " .. narrow)
local athreads = require("trail.threads")
athreads.set({ { id = "A", path = "auth/auth.go", side = "new", line = 9, resolved = false, outdated = false, diff_hunk = "",
  comments = { { author = "bob", body = "why?", created_at = "2026-11-18T10:00:00Z", url = "u" } } } })
athreads.show(athreads.all()[1], function() end)
local pane = vim.iter(vim.api.nvim_tabpage_list_wins(0)):find(function(w)
  return vim.wo[w].winbar:match("auth/auth%.go:9") ~= nil
end)
check(pane and vim.api.nvim_win_get_position(pane)[2] > vim.api.nvim_win_get_position(diff_win)[2]
  and vim.api.nvim_get_current_win() == diff_win, "a thread opens in a pane on the right, and the focus stays in the diff")
check(pane and table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(pane), 0, -1, false), "\n"):match("bob · 2026%-11%-18.*why%?.*r reply.*q close"),
  "the pane shows the thread and its keys")
vim.api.nvim_set_current_win(pane)
check(evaluated(app.statusline(), { maxwidth = 200 }):match("^ NORMAL  thread .*r reply.*q close"), "in the pane the status line shows its keys")
vim.api.nvim_set_current_win(diff_win)
require("trail.compose").open({ kind = "nit", kinds = { "nit" }, highlight = function() return "Comment" end }, function() end)
check(evaluated(app.statusline(), { maxwidth = 200 }):match("^ %u+  comment .*<C%-s> save"), "in the comment box it shows the box's keys: "
  .. evaluated(app.statusline(), { maxwidth = 200 }))
vim.cmd.stopinsert()
vim.fn.maparg("q", "n", false, true).callback()
athreads.show(athreads.all()[1], function() end)
check(#vim.tbl_filter(function(w)
  return vim.wo[w].winbar:match("auth/auth%.go:9") ~= nil
end, vim.api.nvim_tabpage_list_wins(0)) == 1, "showing another thread reuses the pane")
local function pane_win()
  return vim.iter(vim.api.nvim_tabpage_list_wins(0)):find(function(w)
    return vim.api.nvim_win_get_config(w).relative == "" and vim.api.nvim_win_get_position(w)[2] > vim.api.nvim_win_get_position(diff_win)[2]
  end)
end
vim.api.nvim_set_current_win(diff_win)
local wrote
require("trail.compose").open({ kind = "nit", kinds = { "nit", "question" }, highlight = function() return "Comment" end },
  function(body, kind) wrote = { body, kind } end)
local box = vim.api.nvim_get_current_win()
check(box == pane_win() and vim.api.nvim_win_get_config(box).relative == "" and vim.wo[box].winbar:match("nit"),
  "in the app the comment box opens in the side pane, named by its kind")
vim.cmd.stopinsert()
vim.api.nvim_set_current_win(diff_win)
vim.api.nvim_win_set_cursor(diff_win, { 1, 0 })
app.follow_thread()
check(vim.api.nvim_win_get_buf(pane_win()) == vim.api.nvim_win_get_buf(box), "moving in the diff leaves the comment being written alone")
athreads.show(athreads.all()[1], function() end)
check(vim.api.nvim_win_get_buf(pane_win()) == vim.api.nvim_win_get_buf(box), "opening a thread while writing keeps the comment too")
for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  if vim.api.nvim_win_get_config(w).relative ~= "" then
    vim.api.nvim_win_close(w, true)
  end
end
vim.api.nvim_set_current_win(box)
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "rename this" })
vim.api.nvim_feedkeys(vim.keycode("<Tab>"), "x", false)
check(vim.wo[box].winbar:match("question"), "<Tab> changes the kind in the pane's title")
vim.fn.maparg("<C-s>", "n", false, true).callback()
check(wrote and wrote[1] == "rename this" and wrote[2] == "question", "<C-s> saves the comment from the pane")
check(vim.api.nvim_get_current_win() == diff_win, "saving goes back to the diff")
check(pane_win() and vim.wo[pane_win()].winbar:match("auth/auth%.go:9"), "and the pane shows the thread it showed before")
vim.api.nvim_win_close(pane_win(), true)
require("trail.compose").open({ kind = "nit", kinds = { "nit" }, highlight = function() return "Comment" end }, function() end)
vim.cmd.stopinsert()
vim.fn.maparg("q", "n", false, true).callback()
check(not pane_win() and vim.api.nvim_get_current_win() == diff_win, "cancelling a box opened without a pane closes the pane")
athreads.show(athreads.all()[1], function() end)
local replied = vim.deepcopy(athreads.all()[1])
table.insert(replied.comments, { author = "me", body = "because", created_at = "2026-11-19T10:00:00Z", url = "u" })
athreads.set({ replied })
check(table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(pane_win()), 0, -1, false), "\n"):match("because")
  and vim.api.nvim_get_current_win() == diff_win, "when threads load again the pane shows the thread's new replies")
local function win_of(name_pattern)
  return vim.iter(vim.api.nvim_tabpage_list_wins(0)):find(function(w)
    return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)):match(name_pattern) ~= nil
  end)
end
local function the_pane()
  return vim.iter(vim.api.nvim_tabpage_list_wins(0)):find(function(w)
    return vim.wo[w].winbar:match("auth/auth%.go:9") ~= nil
  end)
end
vim.api.nvim_set_current_win(diff_win)
vim.api.nvim_feedkeys("t", "x", false)
local base_win, head_win = win_of("^trail://base/"), win_of("^trail://head/")
tree_win = vim.fn.bufwinid("trail://path")
local full = vim.o.columns
check(base_win and head_win and vim.api.nvim_win_get_position(tree_win)[1] < vim.api.nvim_win_get_position(base_win)[1]
  and vim.api.nvim_win_get_width(tree_win) == full
  and vim.api.nvim_win_get_height(tree_win) == math.min(8, vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(tree_win))),
  "side by side puts the tree across the top at a fixed height")
check(vim.fn.line("w0", tree_win) == 1, "a tree that fits shows from its header")
check(the_pane() and vim.api.nvim_win_get_width(the_pane()) == full
  and vim.api.nvim_win_get_position(the_pane())[1] > vim.api.nvim_win_get_position(head_win)[1],
  "side by side puts the thread pane across the bottom")
check(math.abs(vim.api.nvim_win_get_width(base_win) - vim.api.nvim_win_get_width(head_win)) <= 1
  and vim.api.nvim_win_get_width(base_win) >= math.floor(full / 2) - 1, "the two halves share the full width")
local head_title = evaluated((vim.wo[head_win].winbar:gsub("%%=.*", "")), { winid = head_win, maxwidth = 1000 })
local head_bar = evaluated(vim.wo[head_win].winbar, { winid = head_win, maxwidth = vim.fn.strdisplaywidth(head_title) + 7 })
check(not head_bar:match("%S%? keys"), "a narrow title keeps a gap before its keys: " .. head_bar)
vim.api.nvim_set_current_win(head_win)
check(evaluated(app.statusline(), { maxwidth = 200 }):match("^ NORMAL  auth/auth%.go .*%]c change"),
  "in side by side the status line names the file and the diff's keys: " .. evaluated(app.statusline(), { maxwidth = 200 }))
vim.api.nvim_feedkeys("t", "x", false)
diff_win = win_of("^trail://diff/")
tree_win = vim.fn.bufwinid("trail://path")
check(vim.api.nvim_win_get_position(tree_win)[2] == 0 and vim.api.nvim_win_get_width(tree_win) == 38
  and vim.api.nvim_win_get_position(tree_win)[1] == vim.api.nvim_win_get_position(diff_win)[1],
  "back in unified the tree returns to the left")
check(the_pane() and vim.api.nvim_win_get_position(the_pane())[2] > vim.api.nvim_win_get_position(diff_win)[2]
  and vim.api.nvim_win_get_position(the_pane())[1] == vim.api.nvim_win_get_position(diff_win)[1],
  "and the thread pane to the right")

-- Calls between a path's functions show where they are made; ]] follows one
-- into the function it calls and [[ goes back.
local pathview = require("trail.pathview")
local function step_now()
  return select(2, pathview.current())
end
local function diff_text_row(text)
  local buf = vim.api.nvim_win_get_buf(win_of("^trail://diff/"))
  for r, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if l == text then
      return r
    end
  end
end
local calls_ns = vim.api.nvim_get_namespaces()["trail.diffview.notes"]
local function hint_on(text)
  local buf = vim.api.nvim_win_get_buf(win_of("^trail://diff/"))
  local row = diff_text_row(text)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, calls_ns, { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
    for _, chunk in ipairs(m[4].virt_text or {}) do
      table.insert(out, chunk[1])
    end
  end
  return table.concat(out)
end
local function cursor_text()
  return vim.api.nvim_get_current_line()
end
check(step_now() == 1 and hint_on("\treturn VerifyHash(user)"):match("→ VerifyHash · step 2"),
  "a call to another step shows where it goes: " .. hint_on("\treturn VerifyHash(user)"))
vim.api.nvim_set_current_win(win_of("^trail://diff/"))
vim.api.nvim_win_set_cursor(0, { diff_text_row("\treturn VerifyHash(user)"), 0 })
vim.api.nvim_feedkeys("]]", "x", false)
check(vim.wait(5000, function()
  return step_now() == 2 and cursor_text() == "func VerifyHash(h string) bool {"
end), "]] on a call follows it into the step it calls: step " .. tostring(step_now()) .. ", " .. cursor_text())
check(hint_on("func VerifyHash(h string) bool {"):match("← called by Login line 9"),
  "the function says where it is called from: " .. hint_on("func VerifyHash(h string) bool {"))
vim.api.nvim_feedkeys("]]", "x", false)
check(step_now() == 2 and cursor_text() == "\treturn hashOf(h) == h", "]] off a call moves to the next call: " .. cursor_text())
vim.api.nvim_feedkeys("]]", "x", false)
check(vim.wait(5000, function()
  return step_now() == 3
end), "and ]] again follows it")
vim.api.nvim_feedkeys("[[", "x", false)
check(vim.wait(5000, function()
  return step_now() == 2 and cursor_text() == "\treturn hashOf(h) == h"
end), "[[ goes back to the call it came from: " .. cursor_text())
vim.api.nvim_feedkeys("[[", "x", false)
check(vim.wait(5000, function()
  return step_now() == 1 and cursor_text() == "\treturn VerifyHash(user)"
end), "and again, further back: " .. cursor_text())
vim.api.nvim_feedkeys("]s", "x", false)
vim.wait(5000, function()
  return step_now() == 2 and cursor_text() == "func VerifyHash(h string) bool {"
end)
vim.api.nvim_feedkeys("[[", "x", false)
check(vim.wait(5000, function()
  return step_now() == 1 and cursor_text() == "\treturn VerifyHash(user)"
end), "with nothing to go back to, [[ goes up to the call of the function: " .. cursor_text())
diff_win = win_of("^trail://diff/")
tree_win = vim.fn.bufwinid("trail://path")

-- Sizes the user sets survive the app laying its windows out again.
-- Headless Neovim has no screen to send WinResized after a drag; it is sent here.
vim.api.nvim_win_set_width(tree_win, 30)
vim.api.nvim_win_set_width(the_pane(), 20)
vim.api.nvim_exec_autocmds("WinResized", {})
vim.api.nvim_set_current_win(diff_win)
vim.api.nvim_feedkeys("t", "x", false)
tree_win = vim.fn.bufwinid("trail://path")
vim.api.nvim_win_set_height(tree_win, 3)
vim.api.nvim_win_set_height(the_pane(), 6)
vim.api.nvim_exec_autocmds("WinResized", {})
vim.api.nvim_set_current_win(win_of("^trail://head/"))
vim.api.nvim_feedkeys("t", "x", false)
diff_win = win_of("^trail://diff/")
tree_win = vim.fn.bufwinid("trail://path")
check(vim.api.nvim_win_get_width(tree_win) == 30 and vim.api.nvim_win_get_width(the_pane()) == 20,
  "the tree and pane keep the widths set on them: " .. vim.api.nvim_win_get_width(tree_win) .. ", " .. vim.api.nvim_win_get_width(the_pane()))
vim.api.nvim_feedkeys("t", "x", false)
tree_win = vim.fn.bufwinid("trail://path")
check(vim.api.nvim_win_get_height(tree_win) == 3 and vim.api.nvim_win_get_height(the_pane()) == 6,
  "and in side by side the heights set there: " .. vim.api.nvim_win_get_height(tree_win) .. ", " .. vim.api.nvim_win_get_height(the_pane()))
vim.api.nvim_win_close(the_pane(), true)
local halves = vim.api.nvim_win_get_width(win_of("^trail://head/"))
athreads.show(athreads.all()[1], function() end)
check(vim.api.nvim_win_get_height(tree_win) == 3 and the_pane() and vim.api.nvim_win_get_height(the_pane()) == 6
  and math.abs(vim.api.nvim_win_get_width(win_of("^trail://head/")) - halves) <= 1,
  "opening the pane leaves the other windows as they were: tree " .. vim.api.nvim_win_get_height(tree_win)
  .. ", pane " .. (the_pane() and vim.api.nvim_win_get_height(the_pane()) or "none"))
vim.api.nvim_set_current_win(win_of("^trail://head/"))
vim.api.nvim_feedkeys("t", "x", false)
diff_win = win_of("^trail://diff/")
vim.api.nvim_win_close(the_pane(), true)
athreads.show(athreads.all()[1], function() end)
check(vim.api.nvim_win_get_width(the_pane()) == 20, "a pane closed and opened again keeps its width")
vim.api.nvim_set_current_win(diff_win)
vim.api.nvim_feedkeys("]s", "x", false)
check(vim.wait(5000, function()
  return vim.fn.bufwinid("trail://path") ~= -1 and vim.api.nvim_win_get_width(vim.fn.bufwinid("trail://path")) == 30
end), "and moving to another step keeps the tree's")
vim.api.nvim_feedkeys("[s", "x", false)
vim.wait(2000, function()
  return win_of("^trail://diff/") ~= nil
end)
diff_win = win_of("^trail://diff/")
tree_win = vim.fn.bufwinid("trail://path")

-- In the app every comment, the user's own included, is a hint at the end of
-- its line and a mark in the gutter; the pane is where it is read and acted on.
local cstore = require("trail.state")
local newfile = vim.fn.systemlist({ "git", "-C", repo, "show", "feature:auth/auth.go" })
local dbuf = vim.api.nvim_win_get_buf(diff_win)
local notes_ns = vim.api.nvim_get_namespaces()["trail.diffview.notes"]
local function row_of(text)
  for r, l in ipairs(vim.api.nvim_buf_get_lines(dbuf, 0, -1, false)) do
    if l == text then
      return r
    end
  end
end
local function hint_at(row)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(dbuf, notes_ns, { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
    check(not m[4].virt_lines, "no lines are drawn under the code in the app")
    for _, chunk in ipairs(m[4].virt_text or {}) do
      table.insert(out, chunk[1])
    end
  end
  return table.concat(out)
end
local function gutter_at(row)
  return evaluated(vim.wo[diff_win].statuscolumn, { winid = diff_win, use_statuscol_lnum = row })
end
local function pane_text()
  return table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(pane_win()), 0, -1, false), "\n")
end
local function save_box(text)
  vim.cmd.stopinsert()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { text })
  vim.fn.maparg("<C-s>", "n", false, true).callback()
end
local acomments = require("trail.comments")
local before = #acomments.to_send()
vim.api.nvim_set_current_win(diff_win)
local mine_row = row_of("\treturn hashOf(h) == h")
vim.api.nvim_win_set_cursor(diff_win, { mine_row, 0 })
vim.api.nvim_feedkeys("cb", "x", false)
save_box("hashOf lowercases")
check(hint_at(mine_row):match("◆ blocking · not sent: hashOf lowercases ☑"),
  "a comment shows as a hint at the end of its line, selected for sending: " .. hint_at(mine_row))
check(gutter_at(mine_row):match("^◆ "), "and as a mark in the gutter: " .. gutter_at(mine_row))
local thread_row = row_of(newfile[9])
check(hint_at(thread_row):match("● bob: why%?") and gutter_at(thread_row):match("^● "),
  "a GitHub thread shows the same way: " .. hint_at(thread_row) .. " / " .. gutter_at(thread_row))
check(gutter_at(row_of(newfile[1])):match("^  "), "lines without one keep the gutter aligned")
check(evaluated(app.tabline(), { use_tabline = true }):match(" Send " .. before + 1 .. " "), "the tabline counts the comments to send")
vim.api.nvim_win_set_cursor(diff_win, { mine_row, 0 })
app.follow_thread()
check(pane_win() and pane_text():match("☑ you · blocking · not sent\n +hashOf lowercases") and pane_text():match("e edit")
  and pane_text():match("s select") and pane_text():match("S send " .. before + 1 .. " selected"),
  "on its line the pane shows the comment with what can be done to it: " .. (pane_win() and pane_text() or "no pane"))
vim.api.nvim_set_current_win(pane_win())
vim.api.nvim_feedkeys("s", "x", false)
check(cstore.comments()[#cstore.comments()].unselected and pane_text():match("☐ you") and hint_at(mine_row):match("☐")
  and evaluated(app.tabline(), { use_tabline = true }):match(" Send " .. (before > 0 and before .. " " or "")),
  "s in the pane takes it out of what is sent: " .. pane_text())
vim.api.nvim_feedkeys("s", "x", false)
check(not cstore.comments()[#cstore.comments()].unselected and pane_text():match("☑ you"), "and s again puts it back")
vim.api.nvim_win_close(pane_win(), true)
vim.api.nvim_set_current_win(diff_win)
vim.api.nvim_win_set_cursor(diff_win, { thread_row, 0 })
athreads.show(athreads.all()[1], function() end)
check(pane_text():match("bob") and pane_text():match("r reply") and pane_text():match("R resolve"), "on a thread's line the pane shows the thread")
check(vim.wo[pane_win()].linebreak and vim.wo[pane_win()].wrap, "the pane wraps at words whatever it shows")
vim.api.nvim_set_current_win(pane_win())
vim.api.nvim_feedkeys("r", "x", false)
save_box("then test it")
local reply = cstore.comments()[#cstore.comments()]
check(reply.reply_to == "A" and reply.body == "then test it" and not reply.sent, "r writes a reply to send later, not posted at once")
check(pane_text():match("bob.*☑ you · reply · not sent\n +then test it"), "the reply shows under the thread in the pane: " .. pane_text())
check(hint_at(thread_row):match("● bob: why%?.*↳ reply ☑"), "and on the thread's line: " .. hint_at(thread_row))
check(evaluated(app.tabline(), { use_tabline = true }):match(" Send " .. before + 2 .. " "), "replies count as comments to send")
vim.api.nvim_set_current_win(pane_win())
vim.api.nvim_win_set_cursor(0, { vim.fn.search("then test it", "n"), 0 })
vim.api.nvim_feedkeys("d", "x", false)
check(not vim.iter(cstore.comments()):any(function(c)
  return c.reply_to == "A"
end) and not pane_text():match("then test it"), "d in the pane deletes the comment under the cursor")
vim.api.nvim_set_current_win(diff_win)
vim.api.nvim_win_set_cursor(diff_win, { mine_row, 0 })
app.follow_thread()
vim.api.nvim_set_current_win(pane_win())
vim.api.nvim_feedkeys("e", "x", false)
save_box("hashOf lowercases both")
check(cstore.comments()[#cstore.comments()].body == "hashOf lowercases both" and pane_text():match("hashOf lowercases both"),
  "e in the pane edits it")
vim.api.nvim_set_current_win(pane_win())
vim.api.nvim_feedkeys("S", "x", false)
check(require("trail.help").screen(0) == "send", "S in the pane sends; on a branch review that is the send screen")
for k = #cstore.comments(), 1, -1 do
  table.remove(cstore.comments(), k)
end
cstore.save()
athreads.set({})
vim.g.trail_app, vim.g.trail_tree = nil, nil

-- The Commits screen narrows a review to some of its commits, keeping its
-- comments, and widens it back.
local crepo = repo .. "-commits"
vim.fn.mkdir(crepo, "p")
local function csh(cmd)
  local out = vim.system({ "sh", "-c", cmd }, { cwd = crepo, text = true }):wait()
  assert(out.code == 0, cmd .. ": " .. out.stderr)
end
csh("git init -q -b main && git config user.email t@t && git config user.name t")
csh("printf 'package a\\n\\nfunc A() int { return 1 }\\n' > a.go && printf 'package a\\n\\nfunc B() int { return 1 }\\n' > b.go"
  .. " && git add -A && git commit -qm base && git checkout -qb feature")
csh("printf 'package a\\n\\nfunc A() int { return 2 }\\n' > a.go && git commit -qam 'Change A'")
csh("printf 'package a\\n\\nfunc B() int { return 2 }\\n' > b.go && git commit -qam 'Change B'")
csh("printf 'package a\\n\\nfunc A() int { return 3 }\\n' > a.go && git commit -qam 'Change A again'")
vim.cmd.cd(crepo)
vim.cmd("tabnew")
vim.cmd("Trail main..feature")
local chome = vim.api.nvim_get_current_buf()
local function ctext(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf or 0, 0, -1, false), "\n")
end
check(vim.wait(15000, function()
  return ctext(chome):match("2 hunks") ~= nil
end), "the whole branch opens: " .. ctext(chome))
local cstate = require("trail.state")
table.insert(cstate.comments(), { id = "kept", kind = "nit", body = "kept across ranges", file = "a.go", side = "new",
  line = 3, text = "func A() int { return 3 }" })
cstate.save()
vim.api.nvim_feedkeys("C", "x", false)
check(vim.wait(5000, function()
  return ctext():match("Change A again")
end) and require("trail.help").screen(0) == "commits", "C opens the Commits screen: " .. ctext())
local listed = vim.split(ctext(), "\n")
local subjects = {}
for _, l in ipairs(listed) do
  local s = l:match("^▎ +%d+  %x+  (.-)  +t · ")
  if s then
    table.insert(subjects, s)
  end
end
check(vim.deep_equal(subjects, { "Change A", "Change B", "Change A again" }) and ctext():match("reviewing all"),
  "it lists the commits oldest first, all of them reviewed: " .. ctext())
vim.api.nvim_win_set_cursor(0, { vim.fn.search("Change B", "n"), 0 })
vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
check(vim.wait(15000, function()
  local t = ctext(chome)
  return vim.api.nvim_get_current_buf() == chome and t:match("1 hunks") and t:match("commit 2 of 3")
end), "<CR> on a commit reviews just that commit: " .. ctext(chome))
check(vim.iter(cstate.comments()):any(function(c)
  return c.id == "kept"
end), "comments stay with the review")
vim.api.nvim_feedkeys("C", "x", false)
vim.wait(5000, function()
  return ctext():match("Change A again")
end)
check(ctext():match("reviewing commit 2 of 3") and ctext():match("\n  +1  %x+  Change A"),
  "the screen shows which commits are reviewed: " .. ctext())
vim.api.nvim_win_set_cursor(0, { vim.fn.search("Change B", "n"), 0 })
vim.api.nvim_feedkeys("Vj" .. vim.keycode("<CR>"), "x", false)
check(vim.wait(15000, function()
  return ctext(chome):match("commits 2%-3 of 3") and ctext(chome):match("2 hunks")
end), "a visual selection reviews a run of commits: " .. ctext(chome))
vim.api.nvim_feedkeys("C", "x", false)
vim.wait(5000, function()
  return ctext():match("Change A again")
end)
vim.api.nvim_feedkeys("a", "x", false)
check(vim.wait(15000, function()
  return not ctext(chome):match("commits? %d") and ctext(chome):match("2 hunks")
end), "a goes back to all of them: " .. ctext(chome))
vim.cmd("silent! tabonly")
vim.cmd.cd(root)
vim.fn.delete(crepo, "rf")

-- The bundled startup file the trail command runs.
local started = vim.system({ vim.v.progpath, "--headless", "-u", root .. "/app/init.lua",
  "+lua vim.defer_fn(function() io.stdout:write(vim.api.nvim_eval_statusline(vim.o.tabline, { use_tabline = true }).str .. '|' .. (vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] or '') .. '|' .. tostring(vim.g.trail_app) .. '|' .. vim.o.laststatus .. '\\n'); vim.cmd('qa!') end, 8000)" },
  { cwd = repo, text = true, env = { NVIM_APPNAME = "trail-test", TRAIL_ARGS = "main..feature", XDG_CACHE_HOME = repo .. "-appcache",
    TRAIL_GOPLS = repo .. "-no-gopls" } }):wait(30000)
check(started.stdout:match("^ trail  Overview  Paths  Commits  Send .*main%.%.feature |main%.%.feature|true|3"),
  "app/init.lua opens the review from TRAIL_ARGS with trail's own settings: " .. vim.inspect(started))

-- The app takes on the colors of the user's own Neovim, overrides included.
local configs = repo .. "-configs"
vim.fn.mkdir(configs .. "/mine", "p")
vim.fn.writefile({ 'vim.cmd.colorscheme("blue")', 'vim.api.nvim_set_hl(0, "Normal", { fg = "#eeeeee", bg = "#123456" })' },
  configs .. "/mine/init.lua")
vim.fn.mkdir(configs .. "/broken", "p")
vim.fn.writefile({ "os.exit(1)" }, configs .. "/broken/init.lua")
local function app_colors(user_appname, before)
  return vim.system({ vim.v.progpath, "--headless", "-u", root .. "/app/init.lua", before or "+lua _ = 1",
    "+lua io.stdout:write(string.format('%s|%06x|%s|%s', vim.g.colors_name, vim.api.nvim_get_hl(0, { name = 'Normal' }).bg or 0, vim.api.nvim_get_hl(0, { name = 'TrailModeNORMAL' }).bg and 'mode' or 'none', vim.fn.execute('messages'):gsub('\\n', ' '))); vim.cmd('qa!')" },
    { cwd = repo, text = true, env = { NVIM_APPNAME = "trail-test", TRAIL_USER_APPNAME = user_appname, XDG_CONFIG_HOME = configs,
      XDG_CACHE_HOME = repo .. "-appcache", TRAIL_ARGS = "main..feature", TRAIL_GOPLS = repo .. "-no-gopls" } }):wait(30000).stdout
end
local inherited = app_colors("mine")
check(inherited:match("^blue|123456|mode|"), "the app uses the colors of the user's Neovim, their overrides included: " .. inherited)
check(not inherited:match("own colors"), "and says nothing about it: " .. inherited)
local fallback = app_colors("broken")
check(fallback:match("|0e1116|mode|") and fallback:match("own colors.*exited with code 1"),
  "without them it keeps its own and says why: " .. fallback)
vim.fn.mkdir(configs .. "/noisy", "p")
vim.fn.writefile({ 'vim.cmd.colorscheme("blue")', 'vim.api.nvim_create_autocmd("VimLeavePre", { callback = function() vim.cmd("cquit 3") end })' },
  configs .. "/noisy/init.lua")
local noisy = app_colors("noisy")
check(noisy:match("^blue|"), "colors written by a Neovim that then exits with an error still count: " .. noisy)
vim.fn.mkdir(configs .. "/later", "p")
vim.fn.writefile({ 'vim.defer_fn(function() vim.cmd.colorscheme("blue") end, 50)' }, configs .. "/later/init.lua")
local later = app_colors("later")
check(later:match("^blue|"), "a colorscheme the user's config applies a little after startup counts: " .. later)
vim.fn.mkdir(configs .. "/ui", "p")
vim.fn.writefile({ 'vim.api.nvim_create_autocmd("UIEnter", { callback = function() vim.cmd.colorscheme("blue") end })' },
  configs .. "/ui/init.lua")
local on_ui = app_colors("ui")
check(on_ui:match("^blue|"), "so does one applied once the screen opens, as with LazyVim's VeryLazy: " .. on_ui)
vim.fn.mkdir(configs .. "/switch", "p")
vim.fn.writefile({ "blue" }, configs .. "/scheme")
vim.fn.writefile({ 'vim.cmd.colorscheme(vim.fn.readfile("' .. configs .. '/scheme")[1])' }, configs .. "/switch/init.lua")
local switched = app_colors("switch", "+lua vim.fn.writefile({ 'evening' }, '" .. configs .. "/scheme'); "
  .. "vim.api.nvim_exec_autocmds('FocusGained', {}); vim.wait(5000, function() return vim.g.colors_name == 'evening' end)")
check(switched:match("^evening|"), "regaining focus picks up a theme switched meanwhile: " .. switched)
vim.fn.delete(configs, "rf")

vim.fn.delete(repo, "rf")
if failures > 0 then
  io.stderr:write(failures .. " failures\n")
  os.exit(1)
end
print("ok")
os.exit(0)
