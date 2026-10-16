-- Floating window UI. Pure rendering + input; all logic lives in todo.lua.
local M = {}

local ns = vim.api.nvim_create_namespace("rookie_mstodo")

M.buf = nil
M.win = nil
M.rowmap = {} -- 1-based buffer line -> row table
M.handlers = {} -- set by todo.lua

local function cfg()
  return require("rookie_mstodo.config").get()
end

local function dim(ratio_or_abs, total)
  if ratio_or_abs > 1 then
    return math.floor(ratio_or_abs)
  end
  return math.max(8, math.floor(total * ratio_or_abs))
end

local function win_valid()
  return M.win ~= nil and vim.api.nvim_win_is_valid(M.win)
end

---Content width inside the float (excluding borders).
local function content_width()
  if not win_valid() then
    return 60
  end
  return math.max(20, vim.api.nvim_win_get_width(M.win) - 2)
end

-- ---------------------------------------------------------------------------
-- Window
-- ---------------------------------------------------------------------------

function M.open()
  if win_valid() then
    return
  end
  M.buf = vim.api.nvim_create_buf(false, true)
  local c = cfg().ui
  local width = dim(c.width, vim.o.columns)
  local height = dim(c.height, vim.o.lines)
  M.win = vim.api.nvim_open_win(M.buf, true, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    border = c.border,
    title = c.title,
    title_pos = "center",
    style = "minimal",
  })
  for opt, val in pairs({
    bufhidden = "wipe",
    buftype = "nofile",
    swapfile = false,
    modifiable = false,
  }) do
    vim.bo[M.buf][opt] = val
  end
  vim.bo[M.buf].filetype = "rookie_mstodo"
  vim.wo[M.win].cursorline = true
  vim.wo[M.win].wrap = false
  M.set_keymaps()
end

function M.close()
  if win_valid() then
    vim.api.nvim_win_close(M.win, true)
  end
  M.win = nil
  M.buf = nil
  M.rowmap = {}
end

function M.is_open()
  return win_valid()
end

local function map(lhs, fn, desc)
  vim.keymap.set("n", lhs, fn, { buffer = M.buf, nowait = true, desc = desc })
end

function M.set_keymaps()
  if not (M.buf and vim.api.nvim_buf_is_valid(M.buf)) then
    return
  end
  map("<CR>", function()
    M.handlers.activate()
  end, "打开列表 / 完成任务")
  map("a", function()
    M.handlers.add()
  end, "新建")
  map("d", function()
    M.handlers.delete()
  end, "删除")
  map("r", function()
    M.handlers.refresh()
  end, "刷新")
  map("q", function()
    M.handlers.back()
  end, "返回 / 关闭")
  map("<Esc>", function()
    M.handlers.back()
  end, "返回 / 关闭")
end

---The row under the cursor (nil when on a header/separator/hint line).
function M.current()
  if not win_valid() then
    return nil
  end
  local line = vim.api.nvim_win_get_cursor(M.win)[1]
  return M.rowmap[line]
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

local function fmt_date(d)
  if not d or d == "" then
    return nil
  end
  if d:sub(1, 4) == os.date("%Y") then
    return d:sub(6) -- strip the current year: 2026-05-20 -> 05-20
  end
  return d
end

---@param state table see todo.lua
function M.render(state)
  if not (M.buf and vim.api.nvim_buf_is_valid(M.buf)) or not win_valid() then
    return
  end
  local c = cfg()
  local icons = c.icons
  local width = content_width()
  local lines, marks, rowmap = {}, {}, {}

  local function push(text, line_marks)
    table.insert(lines, text)
    if line_marks then
      for _, mk in ipairs(line_marks) do
        table.insert(marks, { row = #lines - 1, s = mk[1], e = mk[2], hl = mk[3] })
      end
    end
  end

  -- header
  local title = state.title or "Microsoft To-Do"
  local subtitle = state.subtitle or ""
  if subtitle ~= "" then
    push(title .. "   " .. subtitle, {
      { 0, #title, "Title" },
      { #title + 3, #title + 3 + #subtitle, "Comment" },
    })
  else
    push(title, { { 0, #title, "Title" } })
  end
  push(string.rep("─", width), { { 0, width, "NonText" } })

  if state.loading then
    push("  加载中…", { { 0, -1, "Comment" } })
  elseif state.error then
    local msg = tostring(state.error):gsub("\n.*", "")
    if #msg > width - 6 then
      msg = msg:sub(1, width - 9) .. "..."
    end
    push("  ⚠ " .. msg, { { 0, -1, "ErrorMsg" } })
    push("  按 r 重试 · :MSTodoAuth 重新登录", { { 0, -1, "Comment" } })
  else
    for _, row in ipairs(state.rows or {}) do
      if row.kind == "list" or row.kind == "all" then
        local name = row.kind == "all" and "全部任务" or row.name
        local left = "  " .. name
        local right = tostring(row.open or 0)
        local pad = math.max(1, width - #left - #right)
        local text = left .. string.rep(" ", pad) .. right
        local line_marks = { { width - #right, width, "Number" } }
        if row.kind == "all" then
          line_marks[#line_marks + 1] = { 0, #left, "Title" }
        end
        rowmap[#lines + 1] = row
        push(text, line_marks)
      elseif row.kind == "task" then
        local it = row.item
        local icon = it.IsCompleted and icons.done or icons.open
        local left = "  " .. icon .. " " .. (it.Subject or "")
        local parts = {}
        local lname = require("rookie_mstodo.data").list_name(it.ListId)
        if lname and state.list == nil then
          table.insert(parts, "[" .. lname .. "]")
        end
        if it.IsCompleted then
          local d = fmt_date(it.Completed)
          if d then
            table.insert(parts, icons.done_label .. " " .. d)
          end
        elseif it.DueDate then
          table.insert(parts, icons.due .. " " .. fmt_date(it.DueDate))
        end
        local right = table.concat(parts, " ")
        local text
        if right ~= "" then
          local pad = math.max(1, width - #left - #right)
          text = left .. string.rep(" ", pad) .. right
        else
          text = left
        end
        local line_marks = {}
        if it.IsCompleted then
          line_marks[#line_marks + 1] = { 0, #text, "Comment" }
        end
        if it.DueDate and not it.IsCompleted then
          local marker = icons.due .. " " .. fmt_date(it.DueDate)
          local s, e = text:find(marker, 1, true)
          if s then
            local overdue = it.DueDate < os.date("%Y-%m-%d")
            line_marks[#line_marks + 1] = { s - 1, e, overdue and "Error" or "DiagnosticWarn" }
          end
        end
        if lname and state.list == nil then
          local s, e = text:find("[" .. lname .. "]", 1, true)
          if s then
            line_marks[#line_marks + 1] = { s - 1, e, "Identifier" }
          end
        end
        rowmap[#lines + 1] = row
        push(text, line_marks)
      end
    end
  end

  push(string.rep("─", width), { { 0, width, "NonText" } })
  push("  " .. (state.hint or ""), { { 0, -1, "Comment" } })

  vim.api.nvim_buf_set_option(M.buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(M.buf, ns, 0, -1)
  for _, mk in ipairs(marks) do
    local end_col = mk.e
    if end_col == -1 then
      end_col = #lines[mk.row + 1]
    end
    vim.api.nvim_buf_set_extmark(M.buf, ns, mk.row, mk.s, {
      end_col = math.max(end_col, mk.s + 1),
      hl_group = mk.hl,
    })
  end
  vim.api.nvim_buf_set_option(M.buf, "modifiable", false)
  M.rowmap = rowmap

  -- keep the cursor on a selectable row
  local cursor = vim.api.nvim_win_get_cursor(M.win)[1]
  if rowmap[cursor] == nil then
    local best, best_dist = nil, math.huge
    for line in pairs(rowmap) do
      local dist = math.abs(line - cursor)
      if dist < best_dist then
        best, best_dist = line, dist
      end
    end
    cursor = best or 3
  end
  cursor = math.max(1, math.min(cursor, #lines))
  vim.api.nvim_win_set_cursor(M.win, { cursor, 0 })
end

-- ---------------------------------------------------------------------------
-- Terminal float (interactive commands: sign-in, manual delete confirmation)
-- ---------------------------------------------------------------------------

---@param args string[] full command (executable + arguments)
---@param opts table|nil { title = string, on_done = fun() }
function M.run_terminal(args, opts)
  opts = opts or {}
  local buf = vim.api.nvim_create_buf(false, true)
  local width = math.min(vim.o.columns - 4, 110)
  local height = math.min(vim.o.lines - 4, 30)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    border = "rounded",
    title = opts.title or " Microsoft To-Do ",
    title_pos = "center",
  })
  vim.bo[buf].bufhidden = "wipe"
  vim.fn.termopen(args, {
    on_exit = function()
      vim.schedule(function()
        if vim.api.nvim_win_is_valid(win) then
          vim.api.nvim_win_close(win, true)
        end
        if opts.on_done then
          opts.on_done()
        end
      end)
    end,
  })
end

---Sign in to Microsoft (opens an interactive terminal float).
---@param bin string todo executable
---@param on_done fun()|nil
function M.auth_terminal(bin, on_done)
  M.run_terminal({ bin, "list" }, { title = " Microsoft To-Do 登录 ", on_done = on_done })
end

return M
