local M = {}

---The running engine: its process and the ids of the requests sent to it.
local proc
local pending, next_id = {}, 1

---Where the engine's own messages go: progress, timings, errors.
M.log_path = vim.fn.stdpath("log") .. "/trail.log"

local function plugin_root()
  local source = debug.getinfo(1, "S").source:sub(2)
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
end

local function command()
  if vim.g.trail_engine then
    return vim.g.trail_engine
  end
  for _, profile in ipairs({ "release", "debug" }) do
    local built = plugin_root() .. "/engine/target/" .. profile .. "/trail"
    if vim.fn.executable(built) == 1 then
      return built
    end
  end
  return "trail"
end

local function on_line(line)
  local ok, msg = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
  if not ok then
    vim.notify("trail: bad engine output: " .. line, vim.log.levels.ERROR)
    return
  end
  local cb = pending[msg.id]
  pending[msg.id] = nil
  if cb then
    cb(msg.error, msg.result)
  end
end

local function start()
  local cmd = command()
  if vim.fn.executable(cmd) == 0 then
    error("trail engine not found: build it with `cargo build --release` in engine/, or set vim.g.trail_engine")
  end
  local log_path = M.log_path
  local mine = { ids = {} }
  local partial = ""
  mine.handle = vim.system({ cmd, "serve" }, {
    stdin = true,
    stderr = function(_, data)
      local file = data and io.open(log_path, "a")
      if file then
        file:write(data)
        file:close()
      end
    end,
    stdout = function(_, data)
      if not data then
        return
      end
      partial = partial .. data
      while true do
        local nl = partial:find("\n", 1, true)
        if not nl then
          break
        end
        local line = partial:sub(1, nl - 1)
        partial = partial:sub(nl + 1)
        vim.schedule(function()
          on_line(line)
        end)
      end
    end,
  }, function(result)
    vim.schedule(function()
      if proc == mine then
        proc = nil
      end
      -- Its requests still waiting would never be answered.
      local message = string.format("the engine stopped (exit code %d); see %s", result.code,
        vim.fn.fnamemodify(log_path, ":~"))
      for id in pairs(mine.ids) do
        local cb = pending[id]
        pending[id] = nil
        if cb then
          cb({ message = message })
        end
      end
    end)
  end)
  proc = mine
end

---@param cb fun(err: table|nil, result: any)
function M.request(method, params, cb)
  if not proc then
    start()
  end
  local id = next_id
  next_id = next_id + 1
  pending[id] = cb
  proc.ids[id] = true
  proc.handle:write(vim.json.encode({ jsonrpc = "2.0", id = id, method = method, params = params }) .. "\n")
end

function M.stop()
  if proc then
    proc.handle:write(nil)
    proc = nil
  end
end

vim.api.nvim_create_autocmd("VimLeavePre", { callback = M.stop })

return M
