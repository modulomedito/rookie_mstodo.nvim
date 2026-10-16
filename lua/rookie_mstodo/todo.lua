-- Business logic: view state, data fetching and task/list actions.
local M = {}

local cli = require("rookie_mstodo.cli")
local data = require("rookie_mstodo.data")
local config = require("rookie_mstodo.config")
local ui = require("rookie_mstodo.ui")

-- View state:
--   kind   : "lists" | "tasks"
--   list   : list name for the tasks view (nil = all tasks)
--   rows   : rendered rows ({ kind = "all"|"list"|"task", ... })
--   items  : tasks backing the current tasks view
M.state = {
  kind = "lists",
  list = nil,
  rows = {},
  items = {},
  loading = false,
  error = nil,
  title = "Microsoft To-Do",
  subtitle = "",
  hint = "",
}

ui.handlers = {
  activate = function()
    M.activate()
  end,
  add = function()
    M.add()
  end,
  delete = function()
    M.delete()
  end,
  refresh = function()
    M.refresh()
  end,
  back = function()
    M.back()
  end,
}

local HINTS = {
  lists = "<CR> 打开   a 新建列表   d 删除列表   r 刷新   q 关闭",
  tasks = "<CR> 完成   a 添加任务   d 删除任务   r 刷新   q 返回列表",
}

local function strip(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function notify_err(msg)
  if cli.is_broken_build(msg) then
    vim.notify(
      "[rookie_mstodo] todo-cli 的 JSON 输出已损坏（release 构建开启了 trimming）。\n"
        .. "请从源码重新构建：bash <插件目录>/scripts/install.sh",
      vim.log.levels.ERROR
    )
  elseif cli.is_auth_error(msg) then
    vim.notify("[rookie_mstodo] 尚未登录或登录已过期，请运行 :MSTodoAuth", vim.log.levels.WARN)
  else
    vim.notify("[rookie_mstodo] " .. strip(msg):gsub("\n", " "), vim.log.levels.ERROR)
  end
end

---Open (or completed-last) sorting; due dates first, then subject.
local function sorted_tasks(items, show_completed)
  local open, done = {}, {}
  for _, it in ipairs(items or {}) do
    if it.IsCompleted then
      if show_completed then
        table.insert(done, it)
      end
    else
      table.insert(open, it)
    end
  end
  table.sort(open, function(a, b)
    local ad, bd = a.DueDate or "~", b.DueDate or "~"
    if ad ~= bd then
      return ad < bd
    end
    return (a.Subject or "") < (b.Subject or "")
  end)
  table.sort(done, function(a, b)
    return (a.Completed or "") > (b.Completed or "")
  end)
  local out = {}
  vim.list_extend(out, open)
  vim.list_extend(out, done)
  return out, #open, #done
end

local function render()
  ui.render(M.state)
end

-- ---------------------------------------------------------------------------
-- Navigation
-- ---------------------------------------------------------------------------

function M.open_lists()
  M.state.kind = "lists"
  M.state.list = nil
  M.state.hint = HINTS.lists
  ui.open()
  M.refresh()
end

function M.open_tasks(list_name)
  M.state.kind = "tasks"
  M.state.list = list_name
  M.state.title = list_name or "全部任务"
  M.state.hint = HINTS.tasks
  ui.open()
  M.refresh()
end

---Switch back to the lists view without refetching.
function M.show_lists()
  M.state.kind = "lists"
  M.state.list = nil
  M.state.hint = HINTS.lists
  M.state.title = "Microsoft To-Do"
  render()
end

function M.is_open()
  return ui.is_open()
end

function M.back()
  if M.state.kind == "tasks" then
    M.show_lists()
  else
    ui.close()
  end
end

function M.refresh()
  if M.state.kind == "lists" then
    M.refresh_lists()
  else
    M.refresh_tasks()
  end
end

-- ---------------------------------------------------------------------------
-- Data fetching
-- ---------------------------------------------------------------------------

---Build rows for the lists view.
---`results` holds freshly-queried open counts; `pending_set` lists that are
---still being queried (shown as "..."); everything else falls back to the
---count derived from the flat listing via the learned ListId.
local function build_list_rows(counts, open_all, pending_set, results)
  local rows = { { kind = "all", open = open_all } }
  for _, name in ipairs(data.known_lists()) do
    if results[name] ~= nil then
      table.insert(rows, { kind = "list", name = name, open = results[name] })
    elseif pending_set[name] then
      table.insert(rows, { kind = "list", name = name, open = "..." })
    else
      local id = data.list_id_for_name(name)
      table.insert(rows, { kind = "list", name = name, open = (id and counts[id]) or 0 })
    end
  end
  return rows
end

local function to_set(names)
  local set = {}
  for _, n in ipairs(names or {}) do
    set[n] = true
  end
  return set
end

---Lists overview.
---Strategy: one flat `todo list` call returns every task (with its ListId).
---Lists whose ListId is already known get their counts from that call alone.
---Only lists that were never successfully queried need an extra named call;
---those run with a small concurrency cap and the view renders progressively.
function M.refresh_lists()
  M.state.loading = true
  M.state.error = nil
  M.state.title = "Microsoft To-Do"
  M.state.hint = HINTS.lists
  render()

  cli.list_all({
    on_json = function(items)
      M.state.loading = false
      local all_items = items or {}
      local counts = {} -- ListId -> open task count
      local open_all = 0
      for _, it in ipairs(all_items) do
        if not it.IsCompleted then
          open_all = open_all + 1
          counts[it.ListId] = (counts[it.ListId] or 0) + 1
        end
      end
      local pending = {}
      for _, name in ipairs(data.known_lists()) do
        if not data.is_queried(name) then
          table.insert(pending, name)
        end
      end
      M.state.rows = build_list_rows(counts, open_all, to_set(pending), {})
      M.state.subtitle = string.format("%d open · %d lists", open_all, math.max(0, #M.state.rows - 1))
      render()
      M.query_pending_lists(pending, counts, open_all)
    end,
    on_error = function(msg)
      M.state.loading = false
      M.state.error = msg
      notify_err(msg)
      render()
    end,
  })
end

---Query not-yet-known lists (concurrency-capped), updating the view
---progressively as results arrive.
function M.query_pending_lists(pending, counts, open_all)
  if #pending == 0 then
    return
  end
  local pending_set = to_set(pending)
  local results = {} -- name -> open count
  local next_i, active = 1, 0
  local MAX_PARALLEL = 8

  local function rerender()
    M.state.rows = build_list_rows(counts, open_all, pending_set, results)
    render()
  end

  local function pump()
    while active < MAX_PARALLEL and next_i <= #pending do
      local name = pending[next_i]
      next_i = next_i + 1
      active = active + 1
      cli.list_named(name, {
        on_json = function(res)
          active = active - 1
          data.mark_queried(name)
          for _, t in ipairs(res.Tasks or {}) do
            data.set_list_id(t.ListId, res.Name or name)
          end
          local open_n = 0
          for _, t in ipairs(res.Tasks or {}) do
            if not t.IsCompleted then
              open_n = open_n + 1
            end
          end
          results[name] = open_n
          rerender()
          pump()
        end,
        on_error = function(msg)
          active = active - 1
          if tostring(msg):find("No list found", 1, true) then
            data.remove_list(name)
            vim.notify("[rookie_mstodo] list not found, removed from cache: " .. name, vim.log.levels.INFO)
          else
            notify_err(msg)
          end
          rerender()
          pump()
        end,
      })
    end
  end

  pump()
end

function M.refresh_tasks()
  M.state.loading = true
  M.state.error = nil
  M.state.hint = HINTS.tasks
  render()

  local opts = {
    on_json = function(res)
      M.state.loading = false
      local items = res.Tasks or res or {}
      local show = config.get().show_completed
      local sorted, open_n, done_n = sorted_tasks(items, show)
      M.state.items = sorted
      M.state.rows = {}
      for _, it in ipairs(sorted) do
        table.insert(M.state.rows, { kind = "task", item = it })
      end
      M.state.subtitle = string.format("%d open · %d done", open_n, done_n)
      render()
    end,
    on_error = function(msg)
      M.state.loading = false
      M.state.error = msg
      notify_err(msg)
      render()
    end,
  }
  if M.state.list then
    cli.list_named(M.state.list, opts)
  else
    cli.list_all(opts)
  end
end

-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------

local function current_row()
  return ui.current()
end

function M.activate()
  local row = current_row()
  if not row then
    return
  end
  if row.kind == "all" then
    M.open_tasks(nil)
  elseif row.kind == "list" then
    M.open_tasks(row.name)
  elseif row.kind == "task" then
    local it = row.item
    if it.IsCompleted then
      vim.notify("[rookie_mstodo] todo-cli 不支持将已完成任务改回未完成", vim.log.levels.INFO)
      return
    end
    cli.complete_item(it.Id, {
      on_ok = function()
        it.IsCompleted = true
        it.Status = "Completed"
        it.Completed = os.date("%Y-%m-%d")
        M.rebuild_task_rows()
        vim.notify("[rookie_mstodo] 已完成: " .. (it.Subject or ""), vim.log.levels.INFO)
      end,
      on_error = notify_err,
    })
  end
end

---Re-derive task rows from M.state.items (after an optimistic mutation).
function M.rebuild_task_rows()
  local sorted = sorted_tasks(M.state.items, config.get().show_completed)
  M.state.items = sorted
  M.state.rows = {}
  for _, it in ipairs(sorted) do
    table.insert(M.state.rows, { kind = "task", item = it })
  end
  local open_n, done_n = 0, 0
  for _, x in ipairs(sorted) do
    if x.IsCompleted then
      done_n = done_n + 1
    else
      open_n = open_n + 1
    end
  end
  M.state.subtitle = string.format("%d open · %d done", open_n, done_n)
  render()
end

function M.add()
  if M.state.kind == "lists" then
    vim.ui.input({ prompt = "新建列表名称: " }, function(name)
      name = strip(name)
      if name == "" then
        return
      end
      cli.add_list(name, {
        on_ok = function()
          data.add_list(name)
          vim.notify("[rookie_mstodo] 已创建列表: " .. name, vim.log.levels.INFO)
          M.refresh_lists()
        end,
        on_error = notify_err,
      })
    end)
    return
  end

  local function do_add(list_name)
    local prompt = list_name and ("新任务 (" .. list_name .. "): ") or "新任务 (默认清单): "
    vim.ui.input({ prompt = prompt }, function(subject)
      subject = strip(subject)
      if subject == "" then
        return
      end
      cli.add_item(subject, list_name, {
        on_ok = function()
          vim.notify("[rookie_mstodo] 已添加: " .. subject, vim.log.levels.INFO)
          M.refresh_tasks()
        end,
        on_error = notify_err,
      })
    end)
  end

  if M.state.list then
    do_add(M.state.list)
    return
  end
  local known = data.known_lists()
  if #known == 0 then
    do_add(nil)
    return
  end
  local choices = { "默认清单" }
  vim.list_extend(choices, known)
  vim.ui.select(choices, { prompt = "添加到哪个列表?" }, function(choice)
    if not choice then
      return
    end
    do_add(choice == "默认清单" and nil or choice)
  end)
end

function M.delete()
  if M.state.kind == "lists" then
    local row = current_row()
    if not row or row.kind ~= "list" then
      return
    end
    vim.ui.select({ "取消", "删除" }, { prompt = "删除列表 '" .. row.name .. "' 及其中所有任务?" }, function(choice)
      if choice ~= "删除" then
        return
      end
      cli.remove_list(row.name, {
        on_ok = function()
          data.remove_list(row.name)
          vim.notify("[rookie_mstodo] 已删除列表: " .. row.name, vim.log.levels.INFO)
          M.refresh_lists()
        end,
        on_error = notify_err,
      })
    end)
    return
  end

  local row = current_row()
  if not row or row.kind ~= "task" then
    return
  end
  local it = row.item
  vim.ui.select({ "取消", "删除" }, { prompt = "删除任务: " .. (it.Subject or "") .. " ?" }, function(choice)
    if choice ~= "删除" then
      return
    end
    cli.remove_item(it.Id, {
      on_ok = function()
        for i, x in ipairs(M.state.items) do
          if x.Id == it.Id then
            table.remove(M.state.items, i)
            break
          end
        end
        M.rebuild_task_rows()
        vim.notify("[rookie_mstodo] 已删除: " .. (it.Subject or ""), vim.log.levels.INFO)
      end,
      on_error = function(msg)
        if cli.is_interactive_error(msg) then
          -- Unpatched todo-cli build: its confirmation prompt needs a real
          -- console. Fall back to a terminal float for manual confirmation.
          vim.notify(
            "[rookie_mstodo] todo-cli 需要交互确认，请在终端浮窗中按 y 确认删除",
            vim.log.levels.WARN
          )
          ui.run_terminal(vim.list_extend({ cli.resolve() }, { "remove", "item", it.Id }), {
            title = " 确认删除 ",
            on_done = function()
              M.refresh()
            end,
          })
          return
        end
        notify_err(msg)
      end,
    })
  end)
end

return M
