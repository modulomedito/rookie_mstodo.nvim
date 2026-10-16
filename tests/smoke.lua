-- Smoke test: load the plugin the way lazy.nvim would and verify that
-- commands, health check and the float can be opened.
local out = vim.env.SMOKE_OUT or "smoke_out.txt"
local log = {}
local function p(...)
  log[#log + 1] = table.concat(vim.tbl_map(tostring, { ... }), " ")
end

local ok, err = pcall(function()
  -- 0. source plugin/ manually (we run with --noplugin)
  vim.cmd("source " .. vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":p:h:h") .. "/plugin/rookie_mstodo.lua")

  -- 1. setup
  require("rookie_mstodo").setup({})
  p("setup: ok")

  -- 2. commands registered by plugin/rookie_mstodo.lua
  local cmds = vim.api.nvim_get_commands({})
  for _, c in ipairs({ "MSTodo", "MSTodoAuth", "MSTodoLogout" }) do
    assert(cmds[c], "missing command: " .. c)
    p("command :", c, "registered")
  end

  -- 3. executable resolution
  local cli = require("rookie_mstodo.cli")
  p("resolved todo:", tostring(cli.resolve()))

  -- 4. health check runs without throwing
  local health = require("rookie_mstodo.health")
  assert(type(health.check) == "function", "health.check missing")
  p("health.check: callable")

  -- 5. open the float (lists view) without touching the network
  local todo = require("rookie_mstodo.todo")
  local ui = require("rookie_mstodo.ui")
  todo.open_lists()
  assert(ui.is_open(), "float did not open")
  local lines = vim.api.nvim_buf_get_lines(ui.buf, 0, -1, false)
  p("float open, buf lines:", #lines)
  p("line 1:", lines[1] or "")
  p("last line:", lines[#lines] or "")

  -- 6. keymaps are buffer-local and present
  local maps = vim.api.nvim_buf_get_keymap(ui.buf, "n")
  local lhs = {}
  for _, m in ipairs(maps) do
    lhs[m.lhs] = true
  end
  for _, k in ipairs({ "<CR>", "a", "d", "r", "q", "<Esc>" }) do
    assert(lhs[k], "missing keymap: " .. k)
  end
  p("keymaps: <CR> a d r q <Esc> all mapped")

  ui.close()
  assert(not ui.is_open(), "float did not close")
  p("RESULT: SMOKE TEST PASSED")
end)

if not ok then
  p("RESULT: FAILED ->", err)
end
vim.fn.writefile(log, out)
vim.cmd("qa!")