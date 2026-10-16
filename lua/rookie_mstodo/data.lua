-- Persisted plugin state:
--   lists    : known To-Do list names (seeded from config, extended at runtime)
--   list_ids : ListId -> list name, learned from `todo list <name>` responses
--   queried  : list name -> true once successfully queried at least once
local M = {}

M.state = { lists = {}, list_ids = {}, queried = {} }

local function path()
  return vim.fn.stdpath("data") .. "/rookie_mstodo/state.json"
end

local function save()
  local p = path()
  pcall(vim.fn.mkdir, vim.fn.fnamemodify(p, ":h"), "p")
  pcall(vim.fn.writefile, { vim.fn.json_encode(M.state) }, p)
end

---Load persisted state and seed it with lists from the user config.
function M.load()
  local ok, lines = pcall(vim.fn.readfile, path())
  if ok and type(lines) == "table" and #lines > 0 then
    local ok2, decoded = pcall(vim.fn.json_decode, table.concat(lines, "\n"))
    if ok2 and type(decoded) == "table" then
      if type(decoded.lists) == "table" then
        M.state.lists = decoded.lists
      end
      if type(decoded.list_ids) == "table" then
        M.state.list_ids = decoded.list_ids
      end
      if type(decoded.queried) == "table" then
        M.state.queried = decoded.queried
      end
    end
  end
  local cfg = require("rookie_mstodo.config").get()
  for _, name in ipairs(cfg.lists or {}) do
    M.add_list(name)
  end
end

function M.add_list(name)
  if type(name) ~= "string" or name == "" then
    return
  end
  if not vim.tbl_contains(M.state.lists, name) then
    table.insert(M.state.lists, name)
    save()
  end
end

function M.remove_list(name)
  local kept = {}
  for _, n in ipairs(M.state.lists) do
    if n ~= name then
      table.insert(kept, n)
    end
  end
  M.state.lists = kept
  save()
end

---@return string[] copy of known list names
function M.known_lists()
  return vim.list_extend({}, M.state.lists)
end

---Remember which list a task belongs to (for labels in the "all tasks" view).
function M.set_list_id(id, name)
  if not id or not name then
    return
  end
  if M.state.list_ids[id] ~= name then
    M.state.list_ids[id] = name
    save()
  end
end

function M.list_name(id)
  if not id then
    return nil
  end
  return M.state.list_ids[id]
end

---Reverse lookup: list name -> ListId (nil when not learned yet).
function M.list_id_for_name(name)
  for id, n in pairs(M.state.list_ids) do
    if n == name then
      return id
    end
  end
  return nil
end

---Has this list been successfully queried at least once?
function M.is_queried(name)
  return M.state.queried[name] == true
end

function M.mark_queried(name)
  if not name or M.state.queried[name] then
    return
  end
  M.state.queried[name] = true
  save()
end

return M
