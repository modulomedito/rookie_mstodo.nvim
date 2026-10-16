-- Full end-to-end test of rookie_mstodo.nvim against the REAL todo-cli binary
-- and a real Microsoft To-Do account. Only touches a dedicated test list
-- ("rookie-e2e-test"), which must already contain two open tasks
-- ("E2E keep" and "E2E delete").
--
-- Usage:
--   TODO_BIN=/path/to/todo nvim --headless --noplugin -c "luafile tests/e2e_real.lua"
local bin = vim.env.TODO_BIN
assert(bin and bin ~= "", "set TODO_BIN")
local LIST = "rookie-e2e-test"

local log = {}
local function out(...)
  local parts = {}
  for _, a in ipairs({ ... }) do
    table.insert(parts, tostring(a))
  end
  table.insert(log, table.concat(parts, " "))
end

-- silence + capture notifications
local notifications = {}
vim.notify = function(msg, level)
  table.insert(notifications, tostring(msg))
  out("[notify] " .. tostring(msg):gsub("\n", " "))
end

-- stub the interactive prompts
local INPUT_ANSWER = "E2E added by plugin"
vim.ui.input = function(opts, on_confirm)
  out("[ui.input] prompt=" .. tostring(opts.prompt))
  vim.schedule(function()
    on_confirm(INPUT_ANSWER)
  end)
end
local SELECT_ANSWER = "删除"
vim.ui.select = function(items, opts, on_choice)
  out("[ui.select] prompt=" .. tostring(opts.prompt) .. " items=" .. vim.inspect(items))
  vim.schedule(function()
    on_choice(SELECT_ANSWER)
  end)
end

local ui = require("rookie_mstodo.ui")
local todo = require("rookie_mstodo.todo")
local data = require("rookie_mstodo.data")
local cli = require("rookie_mstodo.cli")

require("rookie_mstodo").setup({ cmd = bin, lists = { LIST } })

local function buf_lines()
  if not (ui.buf and vim.api.nvim_buf_is_valid(ui.buf)) then
    return {}
  end
  return vim.api.nvim_buf_get_lines(ui.buf, 0, -1, false)
end

local function dump_view(tag)
  out("---- view: " .. tag .. " ----")
  for i, l in ipairs(buf_lines()) do
    out(string.format("  %2d| %s", i, l))
  end
end

local function wait_loading(timeout)
  vim.wait(timeout or 90000, function()
    return not todo.state.loading and #todo.state.rows > 0
  end, 200)
  return not todo.state.loading and #todo.state.rows > 0
end

local function cursor_to(kind, predicate)
  for line, row in pairs(ui.rowmap) do
    if row.kind == kind and (not predicate or predicate(row)) then
      vim.api.nvim_win_set_cursor(ui.win, { line, 0 })
      return row
    end
  end
  return nil
end

local function wait_cond(desc, timeout, cond)
  local ok = vim.wait(timeout or 90000, cond, 200)
  out(("[wait] %s -> %s"):format(desc, ok and "ok" or "TIMEOUT"))
  return ok
end

local test_ok, test_err = pcall(function()
-- 1. open the lists view -------------------------------------------------
todo.open_lists()
assert(wait_loading(), "lists view did not finish loading")
dump_view("lists")
local lines = table.concat(buf_lines(), "\n")
assert(lines:find("全部任务", 1, true), "lists view missing All Tasks row")
assert(lines:find(LIST, 1, true), "lists view missing test list row")

-- 2. open the test list ---------------------------------------------------
local row = cursor_to("list", function(r)
  return r.name == LIST
end)
assert(row, "test list row not found in view")
ui.handlers.activate()
assert(wait_loading(), "tasks view did not finish loading")
dump_view("tasks:" .. LIST)
local subjects = {}
for _, r in ipairs(todo.state.rows) do
  if r.kind == "task" then
    subjects[r.item.Subject] = r.item
  end
end
assert(subjects["E2E keep"], "E2E keep task missing")
assert(subjects["E2E delete"], "E2E delete task missing")

-- 3. complete "E2E keep" --------------------------------------------------
cursor_to("task", function(r)
  return r.item.Subject == "E2E keep"
end)
ui.handlers.activate()
assert(wait_cond("complete E2E keep", 90000, function()
  for _, it in ipairs(todo.state.items) do
    if it.Subject == "E2E keep" then
      return it.IsCompleted == true
    end
  end
  return false
end), "optimistic complete did not apply")
dump_view("after complete")

-- 4. add a task -----------------------------------------------------------
ui.handlers.add()
assert(wait_cond("add task", 90000, function()
  for _, r in ipairs(todo.state.items) do
    if r.Subject == INPUT_ANSWER then
      return true
    end
  end
  return false
end), "added task not visible")
dump_view("after add")

-- 5. delete "E2E delete" --------------------------------------------------
cursor_to("task", function(r)
  return r.item.Subject == "E2E delete"
end)
ui.handlers.delete()
assert(wait_cond("delete task", 90000, function()
  for _, r in ipairs(todo.state.items) do
    if r.Subject == "E2E delete" then
      return false
    end
  end
  return true
end), "task not removed optimistically")
dump_view("after delete")

-- 6. verify server-side truth via the CLI ---------------------------------
local function cli_json(args)
  local done, res = false, nil
  vim.system(vim.list_extend({ bin }, args), { text = true, timeout = 90000 }, function(r)
    res = r
    done = true
  end)
  vim.wait(100000, function()
    return done
  end, 200)
  return vim.fn.json_decode(res.stdout or "null")
end

local server = cli_json({ "list", LIST, "--all", "-o", "json" })
local server_subjects = {}
for _, t in ipairs(server.Tasks or {}) do
  server_subjects[t.Subject] = t
end
out("[server] tasks: " .. vim.inspect(vim.tbl_keys(server_subjects)))
assert(server_subjects["E2E keep"] and server_subjects["E2E keep"].IsCompleted, "server: E2E keep not completed")
assert(server_subjects[INPUT_ANSWER], "server: added task missing")
assert(not server_subjects["E2E delete"], "server: deleted task still present")

-- 7. back to lists, close -------------------------------------------------
ui.handlers.back() -- tasks -> lists
assert(todo.state.kind == "lists", "back did not return to lists")
ui.handlers.back() -- lists -> close
assert(not ui.is_open(), "view did not close")

out("RESULT: ALL ASSERTIONS PASSED")
end)

if not test_ok then
  out("TEST FAILED, see notifications above")
end
vim.fn.writefile(log, vim.env.E2E_OUT or "e2e_out.txt")
vim.cmd("qa!")
