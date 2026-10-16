-- Thin async wrapper around the `todo` CLI (https://github.com/mehmetseckin/todo-cli).
--
-- Data is always read through `-o json`. The process is always spawned with
-- stdin ignored (an inherited stdin makes todo-cli block) and a timeout.
local M = {}

local config = require("rookie_mstodo.config")

local notified_missing = false

local function plugin_root()
  local src = debug.getinfo(1, "S").source:sub(2)
  -- <root>/lua/rookie_mstodo/cli.lua -> <root>
  return vim.fn.fnamemodify(src, ":h:h:h")
end

---Resolve the todo executable.
---Priority: config.cmd -> <plugin>/deps/bin/todo (our own build) -> $PATH.
---@return string|nil
function M.resolve()
  local cfg = config.get()
  if type(cfg.cmd) == "string" and cfg.cmd ~= "" then
    return vim.fn.expand(cfg.cmd)
  end
  for _, name in ipairs({ "todo", "todo.exe" }) do
    local p = plugin_root() .. "/deps/bin/" .. name
    if vim.uv.fs_stat(p) then
      return p
    end
  end
  local in_path = vim.fn.exepath("todo")
  if in_path and in_path ~= "" then
    return in_path
  end
  return nil
end

function M.notify_missing()
  if notified_missing then
    return
  end
  notified_missing = true
  vim.notify(
    "[rookie_mstodo] 找不到 `todo` 可执行文件。\n"
      .. "请先构建依赖：  bash <插件目录>/scripts/install.sh\n"
      .. "或在 setup() 中用 cmd 指定一个已安装的 todo-cli。",
    vim.log.levels.ERROR
  )
end

---vim.fn.json_decode maps JSON null to the vim.NIL sentinel, not to Lua nil.
---Recursively replace it so downstream code can use plain nil checks.
local function sanitize(v)
  if type(v) ~= "table" then
    if v == vim.NIL then
      return nil
    end
    return v
  end
  for k, val in pairs(v) do
    if val == vim.NIL then
      v[k] = nil
    else
      sanitize(val)
    end
  end
  return v
end

---Best-effort JSON decode; returns nil when the output is not JSON.
local function try_json(s)
  if type(s) ~= "string" then
    return nil
  end
  local trimmed = s:gsub("^%s+", ""):gsub("%s+$", "")
  if trimmed == "" then
    return nil
  end
  local ok, data = pcall(vim.fn.json_decode, trimmed)
  if ok and data ~= nil then
    return sanitize(data)
  end
  return nil
end
M.try_json = try_json

---Run the CLI asynchronously.
---@param args string[]
---@param opts table|nil { on_ok = fun(stdout, json), on_json = fun(json), on_error = fun(msg), timeout = int(ms) }
function M.run(args, opts)
  opts = opts or {}
  local bin = M.resolve()
  if not bin then
    M.notify_missing()
    if opts.on_error then
      opts.on_error("todo-cli executable not found")
    end
    return
  end
  local cmd = vim.list_extend({ bin }, args)
  local spawn_opts = { text = true, timeout = opts.timeout or 60000 }
  if opts.env then
    spawn_opts.env = opts.env
  end
  vim.system(cmd, spawn_opts, function(res)
    vim.schedule(function()
      local out = res.stdout or ""
      local err = res.stderr or ""
      -- Business errors (e.g. "No list found") are reported as a JSON
      -- envelope on stderr *with exit code 0*; only crashes use exit != 0.
      if res.code ~= 0 then
        if opts.on_error then
          opts.on_error(err ~= "" and err or out)
        end
        return
      end
      local err_json = try_json(err)
      if type(err_json) == "table" and err_json.success == false then
        if opts.on_error then
          opts.on_error(err_json.message or "unknown error")
        end
        return
      end
      local data = try_json(out)
      if type(data) == "table" and data.success == false then
        if opts.on_error then
          opts.on_error(data.message or "unknown error")
        end
        return
      end
      if data ~= nil and opts.on_json then
        opts.on_json(data)
      elseif opts.on_ok then
        opts.on_ok(out, data)
      end
    end)
  end)
end

local AUTH_PATTERNS = {
  "msaluirequired",
  "interactionrequired",
  "failed to acquire",
  "no accounts",
  "to sign in",
  "sign%-in",
  "device code",
  "unauthorized",
  "401",
  "token",
  "consent",
}

---Does this error message look like an authentication problem?
function M.is_auth_error(msg)
  local m = tostring(msg):lower()
  for _, p in ipairs(AUTH_PATTERNS) do
    if m:find(p) then
      return true
    end
  end
  return false
end

---GitHub release binaries of todo-cli are published with trimming enabled,
---which breaks their JSON output at runtime.
function M.is_broken_build(msg)
  local m = tostring(msg)
  return m:find("Reflection%-based serialization", 1, true) ~= nil
    or m:find("TypeInfoResolver", 1, true) ~= nil
end

---Unpatched `todo remove item` opens an interactive Inquirer.cs prompt,
---which crashes when the process has no console (spawned from Neovim).
function M.is_interactive_error(msg)
  local m = tostring(msg)
  return m:find("InquirerCS", 1, true) ~= nil
    or m:find("CursorVisible", 1, true) ~= nil
    or m:find("ConsolePal", 1, true) ~= nil
end

-- `todo add item` syntax differs between todo-cli versions:
--   >= 0.3 : todo add item <subject> [--list <name>] [--star] [--due-date <d>]
--   <  0.3 : todo add item <list> <subject>
-- Probe once via the command's own help output.
M.add_syntax = nil -- nil | "new" | "old"

function M.probe_add_syntax(cb)
  if M.add_syntax then
    cb(M.add_syntax)
    return
  end
  M.run({ "add", "item", "--help" }, {
    on_ok = function(out)
      M.add_syntax = out:find("%-%-list") and "new" or "old"
      cb(M.add_syntax)
    end,
    on_error = function()
      M.add_syntax = "new"
      cb(M.add_syntax)
    end,
  })
end

-- ---------------------------------------------------------------------------
-- Command wrappers
-- ---------------------------------------------------------------------------

---All tasks across all lists (including completed).
---@param opts table { on_json = fun(items), on_error = fun(msg) }
function M.list_all(opts)
  M.run({ "list", "--all", "-o", "json" }, opts)
end

---Tasks of a single list (including completed).
---@param name string
---@param opts table { on_json = fun({Name,Count,Tasks}), on_error = fun(msg) }
function M.list_named(name, opts)
  M.run({ "list", name, "--all", "-o", "json" }, opts)
end

---@param subject string
---@param list_name string|nil nil = default list
---@param opts table { on_ok, on_error }
function M.add_item(subject, list_name, opts)
  opts = opts or {}
  M.probe_add_syntax(function(syntax)
    local args
    if syntax == "old" then
      args = { "add", "item", list_name or "Tasks", subject }
    else
      args = { "add", "item", subject }
      if list_name and list_name ~= "" then
        vim.list_extend(args, { "--list", list_name })
      end
    end
    M.run(args, {
      on_ok = function(out)
        if opts.on_ok then
          opts.on_ok(out)
        end
      end,
      on_error = opts.on_error,
    })
  end)
end

function M.add_list(name, opts)
  M.run({ "add", "list", name }, opts)
end

function M.remove_list(name, opts)
  M.run({ "remove", "list", name }, opts)
end

function M.complete_item(id, opts)
  M.run({ "complete", id }, opts)
end

function M.remove_item(id, opts)
  -- TODO_CLI_ASSUME_YES=1 skips the interactive confirmation that upstream
  -- `todo remove item` always shows (patched by scripts/install.sh).
  opts = opts or {}
  opts.env = vim.tbl_extend("force", opts.env or {}, { TODO_CLI_ASSUME_YES = "1" })
  M.run({ "remove", "item", id }, opts)
end

return M
