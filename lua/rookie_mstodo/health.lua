-- :checkhealth rookie_mstodo
local M = {}

function M.check()
  vim.health.start("rookie_mstodo")

  local cli = require("rookie_mstodo.cli")
  local bin = cli.resolve()
  if not bin then
    vim.health.error("`todo` executable not found", {
      "Build the dependency:  bash <plugin>/scripts/install.sh",
      "Or set `cmd` in setup() to an existing todo-cli install",
    })
  else
    vim.health.ok("todo executable: " .. bin)
    local done = false
    cli.run({ "--version" }, {
      timeout = 15000,
      on_ok = function(out)
        vim.health.info("version: " .. vim.trim(out))
        done = true
      end,
      on_error = function(msg)
        vim.health.warn("could not run `todo --version`: " .. vim.trim(tostring(msg)))
        done = true
      end,
    })
    vim.wait(20000, function()
      return done
    end, 100)
  end

  if vim.fn.executable("dotnet") == 1 then
    local out = vim.fn.system({ "dotnet", "--list-sdks" })
    if vim.v.shell_error == 0 and vim.trim(out) ~= "" then
      vim.health.ok(".NET SDK installed")
    else
      vim.health.info(".NET runtime found but no SDK (only needed to rebuild todo-cli)")
    end
  else
    vim.health.info("dotnet not found (only needed to rebuild todo-cli)")
  end
end

return M
