-- rookie_mstodo.nvim — manage Microsoft To-Do from Neovim.
local M = {}

---@param opts table|nil see config.lua for defaults
function M.setup(opts)
  require("rookie_mstodo.config").setup(opts)
  require("rookie_mstodo.data").load()
end

---Open the To-Do browser (lists overview).
function M.open()
  local cli = require("rookie_mstodo.cli")
  if not cli.resolve() then
    cli.notify_missing()
    return
  end
  require("rookie_mstodo.todo").open_lists()
end

---Sign in to Microsoft (opens an interactive terminal float).
function M.auth()
  local cli = require("rookie_mstodo.cli")
  local bin = cli.resolve()
  if not bin then
    cli.notify_missing()
    return
  end
  require("rookie_mstodo.ui").auth_terminal(bin, function()
    local todo = require("rookie_mstodo.todo")
    if todo.is_open() then
      todo.refresh()
    end
  end)
end

---Sign out (removes the token cache written by todo-cli).
function M.logout()
  local path = vim.fn.expand("~/.todo-cli/token.cache")
  if not vim.uv.fs_stat(path) then
    vim.notify("[rookie_mstodo] 当前没有保存的登录令牌", vim.log.levels.INFO)
    return
  end
  vim.ui.select({ "取消", "退出登录" }, { prompt = "删除保存的 Microsoft 登录令牌?" }, function(choice)
    if choice ~= "退出登录" then
      return
    end
    os.remove(path)
    vim.notify("[rookie_mstodo] 已退出登录", vim.log.levels.INFO)
  end)
end

return M
