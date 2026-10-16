-- Configuration for rookie_mstodo.nvim
local M = {}

M.defaults = {
  -- Path to the `todo` executable.
  -- nil -> auto-detect in this order:
  --   1. <plugin>/deps/bin/todo   (built by scripts/install.sh)
  --   2. `todo` found in $PATH
  cmd = nil,

  -- Known To-Do list names. The plugin also learns list names at runtime
  -- (when you create a list or open one) and persists them in
  -- stdpath("data")/rookie_mstodo/state.json.
  lists = {},

  -- Show completed tasks (marked with the done icon) in task views.
  show_completed = true,

  ui = {
    width = 0.62,   -- float width: ratio (<1) of editor width, or absolute columns
    height = 0.72,  -- float height: ratio (<1) of editor height, or absolute lines
    border = "rounded",
    title = " Microsoft To-Do ",
  },

  icons = {
    open = "○",
    done = "✓",
    due = "due",
    done_label = "done",
  },
}

M.options = nil

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", M.defaults, opts or {})
  return M.options
end

---@return table
function M.get()
  if not M.options then
    M.setup({})
  end
  return M.options
end

return M
