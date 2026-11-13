---The user's own review data, kept apart from what the engine computes:
---seen hunks, the step each path was left at, and comments. Stored as JSON
---under the repository's git directory, one file per base..head.
local M = {}

local data, file

local function empty()
  return { version = 1, seen = vim.empty_dict(), positions = vim.empty_dict(), comments = {}, verdict = nil }
end

local function git_dir(repo)
  local out = vim.system({ "git", "-C", repo, "rev-parse", "--git-common-dir" }, { text = true }):wait()
  if out.code ~= 0 then
    return nil
  end
  local dir = vim.trim(out.stdout)
  if not dir:match("^/") then
    dir = repo .. "/" .. dir
  end
  return vim.fs.normalize(dir)
end

function M.load(repo, base, head)
  local dir = git_dir(repo)
  local key = (base .. ".." .. head):gsub("[^%w%.%-_]", "_")
  file = dir and (dir .. "/trail/" .. key .. ".json") or nil
  data = empty()
  if file and vim.fn.filereadable(file) == 1 then
    local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(file), "\n"))
    if ok and type(decoded) == "table" then
      data.seen = next(decoded.seen or {}) and decoded.seen or vim.empty_dict()
      data.positions = next(decoded.positions or {}) and decoded.positions or vim.empty_dict()
      data.comments = decoded.comments or {}
      data.verdict = decoded.verdict
    end
  end
end

function M.path()
  return file
end

function M.save()
  if not file then
    return
  end
  vim.fn.mkdir(vim.fs.dirname(file), "p")
  vim.fn.writefile({ vim.json.encode(data) }, file)
end

function M.seen(hunk_id)
  return data.seen[hunk_id] == true
end

---Marks hunks as seen; returns whether anything changed.
function M.mark_seen(ids)
  local changed = false
  for _, id in ipairs(ids) do
    if not data.seen[id] then
      data.seen[id] = true
      changed = true
    end
  end
  if changed then
    M.save()
  end
  return changed
end

function M.position(path_id)
  return data.positions[path_id]
end

function M.set_position(path_id, step)
  if data.positions[path_id] ~= step then
    data.positions[path_id] = step
    M.save()
  end
end

function M.comments()
  return data.comments
end

function M.verdict()
  return data.verdict
end

function M.set_verdict(verdict)
  data.verdict = verdict
  M.save()
end

return M
