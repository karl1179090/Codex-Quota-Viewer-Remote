[English](README.md) | 中文

# Codex Quota Viewer

> 当前正式版：`1.3.7`
>
> 1.3.7 更新：
> - 从第三方 Provider 模式切回普通 ChatGPT 账号时，会清理遗留的 `[model_providers.custom]` 配置；本机和选中的远端 SSH 主机都会同步处理。
> - 账号切换确认框里的远端 Codex 进程终止选项默认开启。
> - 修复远端会话导入时多行 SSH 脚本和 `~/.codex` 路径的 quoting 问题。
> - 同一远端主机导入后不再重复显示直接预览会话；只有 provider 元数据或文件大小变化时，不再刷新会话 `updatedAt`。
> - 优化内置 Session Manager 的远端导入表单在窄屏下的布局。
>
> 1.3.6 修复：
> - 修复紧凑账号行中 `7d` 刷新日期显示不全的问题，尤其是中文 `12月 31日` 这类本地化月日日期。
>
> 1.3.4 修复：
> - 远端账号同步完成后会重启远端 Codex app-server 进程，确保它重新读取切换后的账号。
> - 保留早期版本中已保存但没有重命名标记的自定义账号显示名。
>
> 1.3.3 更新：
> - 切换账号确认框新增选项，可终止选中远端 SSH 主机上的 Codex 进程。
> - 远端终止逻辑扩展到 SSH 登录用户下的 Codex native 进程、Node wrapper 和 app-server proxy 的 shell wrapper。
> - 修复账号重命名后在运行时刷新和 vault 归一化时被邮箱覆盖的问题。
>
> 1.3.2 修复：
> - 修复切换账号后设置页“账户”面板内容变空的问题，确保页面和账号列表滚动区域始终按可见内容区撑开。
> - 使用确定性的账号列表布局保持已保存账号的操作按钮可见，并补充覆盖零高度滚动区域回归的测试。
>
> 1.3.1 修复：
> - 修复设置页账号行布局，确保切换、重命名和移除操作在账号列表刷新后仍保持可见。
>
> 1.3.0 fork 更新：
> - 新增 **远端同步**：本地切换账号时，可以同时通过 SSH 更新选中的远端 Codex 目录。
> - 新增 **远程** 设置页：自动读取 `~/.ssh/config` 里的可选 `Host`，支持搜索、全选、重新读取、自定义 SSH 目标，以及配置远端 Codex 目录。
> - 扩展安全切换流程：支持多远端同步，远端写入 `auth.json`、合并 `config.toml`、更新远端 rollout 的 `model_provider`，并把远端回滚绑定到同一个 restore point。
> - 新增 **直接切换（不备份）**：适合明确不需要本地和远端 restore point 的场景。
> - ChatGPT 账号登录支持取消，并新增登录超时保护；登录过程中设置页会显示取消按钮。
> - 定时刷新会刷新已保存账号额度；额度标签从 `1w` 改为 `7d`；账号行改为更紧凑的额度指示器，并补充菜单图标。
> - 打包脚本会用无扩展属性的干净副本签名，并为内置 Session Manager 打包所需的 Node runtime library。
>
> 1.2.0 更新：
> - 新增 **第三方 Provider 模式**：Codex 保持普通 ChatGPT 账号登录，但实际请求使用已保存的 API 账号。
> - 菜单新增模式切换入口，会根据当前状态显示 **切换为第三方 Provider…** 或 **切换回正常账号**。
> - 切换时可从已保存 API 账号中选择 Provider，并安全写入 `config.toml` 所需的 `base_url` 与 API Key。
> - 进入和退出该模式都会创建 restore point，并同步 rollout provider、修复本地线程状态，确保切换 API 与普通账号登录时不丢会话历史。
>

Codex Quota Viewer 是一个原生 macOS 菜单栏应用。它把 Codex 用户最常做的几件
事放到一个入口里：看当前额度、管理多个账号、安全切换账号、浏览和修复本地会话。

你不用自己去翻 `~/.codex`，也不用手动改 `auth.json`、`config.toml`，更不用为了
看会话再单独装一套 Session Manager。打开菜单栏图标，大多数日常操作都能直接做。

## 当前版本能做什么

- 查看当前 Codex 账号，并直接看到 `5h` / `7d` 剩余额度。
- 管理多个 ChatGPT 账号和 API 账号。
- 用应用内置流程新增 ChatGPT 账号。
- 通过 API Key + Base URL 新增 OpenAI-compatible API 账号，并在可用时自动探测模型。
- 安全切换账号，自动备份、修复线程状态，并支持一键回滚。
- 可选通过 SSH 把同一次账号切换同步到远端机器，切回普通 ChatGPT 账号时也会清理遗留 Provider 配置。
- 从菜单栏直接打开内置 Session Manager，在浏览器里管理本地会话。
- 浏览、搜索、恢复、归档、回收、批量处理本地和导入的远端会话。
- 一次设置中英文语言，原生界面和 Session Manager 一起切换。
- 在设置里调整刷新频率、菜单栏显示样式、开机启动等常用选项。

## 这款程序适合谁

如果你有下面这些需求，这个程序基本就是为你准备的：

- 你经常想确认“我现在这个 Codex 账号还有多少额度”。
- 你会在多个 Codex 身份之间切换，但不想手改配置文件。
- 你想找回旧会话、恢复会话、清理会话，最好别敲命令。
- 你希望拿到的是一个能直接打开的 `.app`，不是一堆脚本。

## 快速开始

### 安装

1. 到 [Releases](https://github.com/karl1179090/Codex-Quota-Viewer-Remote/releases) 页面下载最新 DMG。
2. 把 `CodexQuotaViewer.app` 拖进 `/Applications`。
3. 双击打开；如果 macOS 提示来源不明，按系统提示手动放行。
4. 点击菜单栏里的新图标。

### 第一次使用

1. 先让程序读取你当前的 `~/.codex/auth.json`。
2. 如果你要保存更多账号，打开 **Settings... -> Accounts**。
3. 如果你要管理旧会话，打开 **Maintenance -> Open Session Manager**。
4. 如果你要切换到别的账号，使用 **Switch Safely**。

## 主要功能

### 1. 菜单栏直接看额度

这部分就是最直接的“抬头就能看”的体验。

- 标准 Codex 登录会显示 `5h` 和 `7d` 两个窗口。
- 只有周额度的账号，也会按周额度正确显示。
- 菜单栏可以切成仪表样式，也可以切成文字样式。
- 可以手动刷新，也可以按设定频率自动刷新。
- 数据如果变旧了，会明确提示你它可能已经过期。

### 2. 本地账号仓

程序内建了自己的本地账号仓，用来保存你想长期管理的账号。

- 保存多个 ChatGPT 账号。
- 保存多个 API 账号。
- 在 **Settings... -> Accounts** 里重命名、激活、忘记账号。
- 一键打开本地账号仓目录。
- 菜单顶部保持简洁，完整账号列表收进 **All Accounts**。
- 如果本机存在兼容的旧账号数据，程序可以做一次性导入。
- 菜单会尽量把更值得优先看的账号排在前面，同时完整分组列表仍然保留在 **All Accounts** 里。

### 3. 安全切换账号

这是本程序最核心的能力之一。

点击 **Switch Safely** 后，程序会尽量按安全流程帮你完成切换：

- 先关闭 Codex
- 创建 restore point 备份
- 写入目标 `auth.json`
- 合并并写入目标 `config.toml`
- 必要时重写 rollout 的 `model_provider`
- 修复本地官方线程状态
- 最后重新打开 Codex

如果你在设置里启用了 **远端同步**，同一次切换还会同步到选中的远端 SSH 目标。
远端同步会写入目标 `auth.json`，把目标 `config.toml` 合并到远端已有配置中，更新远端
rollout 的 `model_provider`，并在完成后报告远端警告数量和已更新的 rollout 数量。
从第三方 Provider 模式切回普通 ChatGPT 账号时，本机和远端都会移除遗留的
`[model_providers.custom]` 配置段。切换确认框中还可以选择终止每个选中远端主机上
SSH 登录用户拥有的全部 `codex` 进程；远端切换时这个清理选项默认开启。

如果切完发现不对，可以直接用 **Maintenance -> Rollback Last Change** 回退最近一次切换。

切换备份默认保存在：

```text
~/Library/Application Support/CodexQuotaViewer/SwitchBackups/
```

远端 restore point 数据保存在远端 Codex 目录下：

```text
~/.codex/.codex-quota-viewer/remote-switch-backups/
```

确认弹窗里也可以选择 **直接切换（不备份）**。这个路径会跳过本地和远端 restore point
创建，只适合你明确不需要回滚保护的场景。

### 4. 远端同步设置

打开 **Settings... -> Remote** 可以配置远端切换同步。

- 启用或关闭账号切换时的远端同步。
- 从 `~/.ssh/config` 里选择一个或多个 SSH Host。
- 搜索、全选、取消全选、重新读取 SSH Host。
- 添加不在 SSH config 里的自定义 SSH 目标。
- 设置远端 Codex 目录，默认是 `~/.codex`。

远端同步使用系统 `ssh` 命令，因此需要你本机已经能正常 SSH 连接到目标机器。

### 5. 内置 Session Manager

你可以从 **Maintenance -> Open Session Manager** 直接打开内置会话管理器。它会在
本机 `127.0.0.1:4318` 启动一个本地 Web 管理台。

你可以在里面：

- 按项目目录浏览会话
- 按 `Active`、`Archived`、`Trash` 筛选
- 按标题、路径、摘要搜索会话
- 查看摘要、时间、行数、事件数、工具调用数
- 阅读完整时间线
- 恢复会话
- 在 `Resume only` 和 `Rebind cwd` 两种恢复模式之间选择
- 预览并导入 SSH 主机上的远端会话，导入后不会重复显示同一个远端 thread
- 归档、移入回收站、恢复、彻底清理
- 批量选择多条会话一起操作
- 修复官方本地线程元数据漂移

重点是：它已经打包进 `.app` 里了。最终用户不需要再单独安装 CodexMM，也不需要自己装 Node。

### 6. Maintenance 工具集中入口

当本地状态有点乱、或者你只是想手动处理问题时，**Maintenance** 里集中放了最常用的几个入口：

- **Refresh All**
- **Open Session Manager**
- **Repair Now**
- **Rollback Last Change**

### 7. 一套语言设置，全局生效

程序和 Session Manager 共用同一套语言设置：

- `Follow System`
- `English`
- `中文`

你只需要在 **Settings... -> General -> Language** 改一次。

### 8. 真正常用的设置项

当前版本的设置项不是摆设，都是日常会用到的：

- 刷新频率
- 开机启动
- 菜单栏显示样式
- 语言
- 远端同步
- 账号管理

## 常见使用路径

### 我只想看当前额度

1. 打开程序。
2. 看菜单栏或点开菜单。
3. 如果觉得数据可能旧了，点 **Refresh All**。

### 我想新增一个账号

1. 打开 **Settings... -> Accounts**。
2. 选择 **Sign in with ChatGPT** 或 **Add API Account**。
3. 保存账号。
4. 需要使用时，再从菜单里选中它。

### 我想安全切换账号

1. 在顶部账号行或 **All Accounts** 里选中目标账号。
2. 点击 **Switch Safely**。
3. 等程序完成备份、写配置、修复线程和重开 Codex。
4. 如需撤销，点 **Rollback Last Change**。

### 我想把账号切换同步到远端机器

1. 打开 **Settings... -> Remote**。
2. 启用远端同步，并选择 SSH Host 或添加自定义目标。
3. 确认远端 Codex 目录。
4. 从菜单执行 **Switch Safely**。
5. 根据成功提示确认远端 rollout 更新数量和警告数量。

### 我想找回或恢复旧会话

1. 打开 **Maintenance -> Open Session Manager**。
2. 找到项目和会话。
3. 如果只是想让 Codex 重新识别它，用 `Resume only`。
4. 如果还想改会话绑定的工作目录，用 `Rebind cwd`。

## 隐私与本地数据

这个程序是按“本地桌面工具”设计的。

- 它读取的是你机器上已经存在的本地 Codex 数据。
- 如果你主动新增 API 账号，凭据会保存在应用自己的本地账号仓里。
- Session Manager 只监听 `127.0.0.1`。
- 会话文件不会被自动上传到外部服务。

程序常见会接触到这些本地路径：

- `~/.codex/auth.json`
- `~/.codex/config.toml`
- `~/.codex/sessions/**/*.jsonl`
- `~/.codex/archived_sessions/**/*.jsonl`
- `~/Library/Application Support/CodexQuotaViewer/Accounts/**/*`
- `~/Library/Application Support/CodexQuotaViewer/SwitchBackups/**/*`

本仓库里的截图已经做过隐私安全处理。

## 系统要求

- macOS 13 或更高版本
- 本机可用的 Codex 安装：
  `Codex.app` 在 `/Applications`，或者 shell `PATH` 中有 `codex`
- 已登录的 Codex 配置：`~/.codex/auth.json`

## 从源码构建

如果你要构建完整的打包应用：

```bash
./scripts/build-app.sh
```

产物在：

```text
dist/CodexQuotaViewer.app
```

如果你只想构建原生可执行文件：

```bash
swift build -c release --product CodexQuotaViewer
```

如果你要跑项目验证：

```bash
./scripts/verify-all.sh
```

## 故障排查

### “Could not find the codex executable.”

确认以下任一条件成立：

- `/Applications` 里存在 `Codex.app`
- shell `PATH` 中可以直接找到 `codex`

### “Sign in required.”

说明当前本地 Codex 登录缺失、过期或无效。请重新登录，并确认 `~/.codex/auth.json`
确实存在。

### “Timed out while reading quota.”

说明本地 Codex 运行时没有及时返回额度信息。先重试 **Refresh All**；如果一直失败，
先确认 Codex 本身在这台机器上是可用的。

### “Bundled session manager is missing. Rebuild CodexQuotaViewer.app.”

请重新构建打包应用：

```bash
./scripts/build-app.sh
```

然后从 `dist/` 目录里打开完整的 `.app`，不要只运行 Swift 裸可执行文件。

### “Session manager could not start because port 4318 is already in use.”

说明有别的进程占用了 `4318` 端口。如果那就是已经运行的会话管理器，程序可以复用；
如果不是，请先停止它，再重试。

## 分发说明

打包后的 `.app` 内已经包含：

- 原生 Swift 菜单栏应用
- 内置 Session Manager 的应用文件
- 供 Session Manager 使用的私有 Node runtime

所以最终分发单位就是这个 `.app`。普通用户不需要再去单独准备一套 Web 端会话管理器环境。

## 致谢

感谢 [LinuxDo](https://linux.do/) 社区的支持。
