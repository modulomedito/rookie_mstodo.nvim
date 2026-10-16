if vim.g.loaded_rookie_mstodo then
  return
end
vim.g.loaded_rookie_mstodo = 1

if vim.fn.has("nvim-0.10") == 0 then
  vim.notify("[rookie_mstodo] 需要 Neovim 0.10 或更高版本", vim.log.levels.ERROR)
  return
end

vim.api.nvim_create_user_command("MSTodo", function()
  require("rookie_mstodo").open()
end, { desc = "Open Microsoft To-Do browser" })

vim.api.nvim_create_user_command("MSTodoAuth", function()
  require("rookie_mstodo").auth()
end, { desc = "Sign in to Microsoft To-Do" })

vim.api.nvim_create_user_command("MSTodoLogout", function()
  require("rookie_mstodo").logout()
end, { desc = "Sign out of Microsoft To-Do" })
