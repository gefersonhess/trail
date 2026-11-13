local M = {}

local proc, pending, next_id, partial = nil, {}, 1, ""

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
  proc = vim.system({ cmd, "serve" }, {
    stdin = true,
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
  }, function()
    proc = nil
  end)
end

---@param cb fun(err: table|nil, result: any)
function M.request(method, params, cb)
  if not proc then
    start()
  end
  local id = next_id
  next_id = next_id + 1
  pending[id] = cb
  proc:write(vim.json.encode({ jsonrpc = "2.0", id = id, method = method, params = params }) .. "\n")
end

function M.stop()
  if proc then
    proc:write(nil)
    proc = nil
  end
end

vim.api.nvim_create_autocmd("VimLeavePre", { callback = M.stop })

return M
