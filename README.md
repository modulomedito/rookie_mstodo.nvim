# rookie_mstodo.nvim

在 Neovim 里操作 Microsoft To-Do 的浮动窗口插件。后端是
[todo-cli](https://github.com/mehmetseckin/todo-cli)，安装时自动从源码构建，
所以不需要你手动装 .NET 工具或配置 PATH。

界面只有两层：列表总览 → 任务列表。所有操作都是键位，不用记命令。

```
全部任务              245
工作                  12
购物                   3
rookie-e2e-test        ...
```

---

## 要求

- Neovim **0.10+**
- 首次构建需要 [.NET 8 SDK](https://dotnet.microsoft.com/download)（脚本会在
  PATH 里找 `dotnet`；找不到时可先跑一次 `scripts/install.sh`，它会给出提示）
- 一次性：微软账号设备码登录（`todo-cli` 自己走 WAM 流程）

## 安装（lazy.nvim）

```lua
{
  "your-name/rookie_mstodo.nvim",
  build = "bash scripts/install.sh",
  config = function()
    require("rookie_mstodo").setup()
  end,
}
```

`build` 会把 `todo` 编译到 `deps/bin/todo`。如果你已经有可用的 `todo`，
删掉 `build` 也能跑 —— 插件会回退到 `$PATH` 里的 `todo`，只要它支持
`list -o json` 就行（见下文「已知限制」）。

其它包管理器同理，`build = "bash scripts/install.sh"` 是关键。

### 手动安装

```sh
git clone <repo> ~/.local/share/nvim/lazy/rookie_mstodo.nvim
bash ~/.local/share/nvim/lazy/rookie_mstodo.nvim/scripts/install.sh
```

## 首次登录

```vim
:MSTodoAuth
```

会弹出一个终端窗口显示微软登录流程，登录完成后自动关闭。

- `:MSTodoLogout` 退出登录

## 命令

| 命令 | 说明 |
| --- | --- |
| `:MSTodo` | 打开浮窗（列表视图） |
| `:MSTodoAuth` | 登录 |
| `:MSTodoLogout` | 退出登录 |
| `:checkhealth rookie_mstodo` | 检查二进制、登录状态 |

## 键位

浮窗内 buffer-local，全局不生效。

| 键 | 列表视图 | 任务视图 |
| --- | --- | --- |
| `<CR>` | 打开该列表 | 勾选完成 |
| `a` | 新建列表 | 新建任务 |
| `d` | 删除列表 | 删除任务 |
| `r` | 刷新 | 刷新 |
| `q` / `<Esc>` | 关闭 | 返回列表视图 |

删除列表会连带删掉里面所有任务，因此会先弹确认框。

## 配置

```lua
require("rookie_mstodo").setup({
  -- 列表名。留空的话，插件在你创建/打开列表时会自动学习并记住，
  -- 存在 stdpath("data")/rookie_mstodo/state.json
  lists = { "工作", "生活" },

  -- 任务视图是否显示已完成任务
  show_completed = true,

  -- todo 可执行文件；nil = 先找 deps/bin/todo，再找 $PATH
  cmd = nil,

  ui = {
    width = 0.62,   -- 浮窗宽度占比，或绝对列数
    height = 0.72,
    border = "rounded",
    title = " Microsoft To-Do ",
  },

  icons = {
    open = "○",
    done = "✓",
    due = "due",
    done_label = "done",
  },
})
```

## 它是怎么工作的

**列表总览**没有「列出所有列表」的 API —— `todo-cli` 只能按名字查。所以插件这样做：

1. 一次 `todo list --all -o json` 拿到全部任务，按 `ListId` 分组统计未完成数；
2. 已经查过名字的列表，计数直接从这个结果里算；
3. 还没查过的列表才发单独的命名请求（并发上限 8，渐进渲染，显示 `...` 占位）。

查过一次的列表名和 `ListId` 会持久化，所以第二次打开列表页几乎是瞬间的。

**状态**是乐观更新：勾选/删除先改本地视图，再发请求，失败时回滚 + 报错。

## 已知限制

这些来自上游 `todo-cli`，不是插件的取舍：

- **无法撤销完成**。`todo-cli` 只暴露 `complete`，没有 uncomplete。
- **不能改任务**。改 subject / due date 得去官网或客户端。
- **截止日期可能差一天**。走 Graph API 时区转换的问题，`2026-10-20`
  读回来可能是 `2026-10-19`。
- **必须从源码构建**。GitHub release 版开了 `PublishTrimmed`，会把
  `System.Text.Json` 的反射序列化裁掉，`-o json` 直接抛异常。所以本插件的
  `scripts/install.sh` 固定用 `PublishTrimmed=false` 从某个 commit 构建。如果你
  把 `cmd` 指向一个 release 版二进制，读取会失败。
- **删除需要非交互模式**。`todo remove item` 会弹 Inquirer 确认，非 TTY 环境下
  直接崩。`install.sh` 会给 `RemoveCommandHandler.cs` 打一个补丁：设
  `TODO_CLI_ASSUME_YES=1` 时跳过确认。补丁打不上（上游改了源码）时会退化成
  终端浮窗手动确认。

## 开发 / 测试

```sh
# 语法检查
nvim --headless -c "lua loadfile('lua/rookie_mstodo/cli.lua')" -c qa

# 完整 E2E（真实二进制 + 真实 Graph API，只动 rookie-e2e-test 列表）
nvim --headless --noplugin --cmd "set rtp^=$(pwd)" -c "luafile tests/e2e_real.lua"
```

E2E 会在你的账号里建一个 `rookie-e2e-test` 列表，跑完删掉。

## 许可证

MIT