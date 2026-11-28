# AGENTS.md — dsh-updater 仓库约定

给在本仓库工作的 agent（以及人）的说明。一句话：**一套升级引擎，多个入口；Windows 与 Linux 必须行为对齐。**

## 这个仓库做什么

更新 **npm 全局安装**的 DeepSeek Harness（`@deepseek-ai/dsh`）本体与各 profile 的插件：预览可用版本 → 更新前备份 → 兼容性校验（不兼容自动回滚）→ 可回滚。

| 入口 | 位置 | 说明 |
|---|---|---|
| DSH 插件 | `plugin/` | 在 DSH 里 `/update` 检查与升级；升级由进程外 worker 执行，完成后自动重启 DSH |
| Windows 脚本 | `Update-Dsh.ps1` + `*.cmd` | PowerShell 7（兼容 5.1）；`.cmd` 是双击包装 |
| Linux 脚本 | `update-dsh.sh`、`check-updates.sh` | bash ≥ 4.4，不依赖 PowerShell |
| DSH skill | `skills/upgrade-dsh/` | 让 agent 编排「预览 → 退出 DSH 后自动升级 → 重启后验证」 |
| 设计稿 | `docs/`（被 `.gitignore` 忽略） | 本地笔记，**不要提交** |

## 目录职责

| 路径 | 职责 | 注意 |
|---|---|---|
| `Update-Dsh.ps1` | Windows 引擎：预览、备份、更新、校验、回滚 | 必须保持在**仓库根**（插件按 `../Update-Dsh.ps1` 找它） |
| `update-dsh.sh` | Linux 引擎，功能与 Windows 对齐 | 参数是 GNU 长选项（`--scope` 对应 `-Scope`） |
| `check-updates.*` | 只读预览入口 | 必须拒绝回滚参数，避免误改 |
| `update-dsh.cmd`、`check-updates.cmd` | 双击包装 | **纯 ASCII**，启动前 `Unblock-File` |
| `plugin/index.js` | DSH 插件 Host 侧：命令、定时检查、排 worker | 运行在 dsh 进程内 |
| `plugin/worker.js` | 进程外 worker：等 dsh 退出 → 跑引擎 → 重启 | 由计划任务拉起 |
| `plugin/checker.js`、`scheduler.js`、`output.js` | 版本查询、schtasks 封装、子进程输出解码 | 可被两边复用 |
| `skills/upgrade-dsh/` | agent 编排用的 skill 与 PS 脚本 | 与 `plugin/` 有功能重叠，改动时注意两边一致性 |

## 硬性规则

1. **两套引擎功能对齐。** 改了 Windows 侧的行为，Linux 侧要同步（反之亦然）；备份目录结构与 `manifest.json` 字段必须一致——两边的备份可以互相 `--rollback`。
2. **版本号同步升级。** `Update-Dsh.ps1` 的 `$script:ScriptVersion` 与 `update-dsh.sh` 的 `SCRIPT_VERSION` 同时改；行为有变化就在 `README.md` 的「更新日志」补一条。插件自己的版本在 `plugin/package.json`，与引擎版本无关。
3. **文件编码不能随意变。**
   - `Update-Dsh.ps1`：**必须保留 UTF-8 BOM**。没有 BOM 时 Windows PowerShell 5.1 会按 ANSI 读，中文全变乱码。
   - `.cmd`：保持纯 ASCII（`chcp` 与代码页问题）。
   - `.sh`：保持 LF（`.gitattributes` 已固定 `*.sh text eol=lf`）。
4. **不写死本机路径。** 不提交 `D:\...`、用户名、机器名；用环境变量（`DSH_UPDATER_HOME`、`DSH_HOME`）或仓库相对位置。
5. **不提交运行产物。** `.dsh-update-backups/`、`*.log`、仓库根的 `docs/` 都在 `.gitignore` 里；不要用 `git add -f` 绕过。
6. **一次提交一件事。** 不夹带格式化、不顺手重构无关代码。

## 改动后的验证

```powershell
# PowerShell：语法 + BOM
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile("$PWD\Update-Dsh.ps1", [ref]$null, [ref]$errors)
if ($errors) { $errors | ForEach-Object Message }
'{0:X2} {1:X2} {2:X2}' -f [System.IO.File]::ReadAllBytes("$PWD\Update-Dsh.ps1")[0..2]   # 应为 EF BB BF；无 BOM 时以 3C 开头

# bash：语法（bash 可能不在 PATH，Git for Windows 下用绝对路径）
& 'C:\Program Files\Git\bin\bash.exe' -n update-dsh.sh

# 插件 JS
node --check plugin/index.js; node --check plugin/worker.js
node --check plugin/checker.js; node --check plugin/scheduler.js
```

- **预览是只读的**，可放心跑：`pwsh -NoProfile -File .\Update-Dsh.ps1 -DryRun -Yes` / `./update-dsh.sh --dry-run --yes`。
- **不要在 agent 会话里执行真实升级**：它会替换运行中的 dsh 文件、退出当前进程；真实闭环交给用户或在 DSH 之外执行。
- 改 `plugin/index.js` 后需要重载插件（Plugins 页停用→启用）；改 `plugin/worker.js` 不需要（每次 `/update apply` 都是新进程）。

## 已知坑（踩过，别再踩）

| 现象 | 原因与做法 |
|---|---|
| 升级任务窗口 / 日志中文乱码 | PowerShell 7 写管道的编码随环境变：有控制台时 GBK，计划任务（无控制台）时 UTF-8。**不要猜**，统一用 `-Command` 先设 `[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)`，再按 UTF-8 解码（`plugin/output.js`） |
| 计划任务静默不执行 | 别写 `.cmd` 启动器——cmd.exe 按 GBK 读脚本，`C:\Users\中文\...` 的路径会坏。把命令行直接交给 `schtasks /TR`（UTF-16） |
| 后台进程随 dsh 退出消失 | dsh 在 Windows 用 kill-on-close 的 Job Object；升级执行必须由**计划任务**托管，`Start-Process`/`nohup`/`&` 都不可靠 |
| 更新本体报 EBUSY/EPERM | 仍有 dsh/node 占用安装目录；必须等所有 dsh 进程退出 |
| 插件更新后启动被拒 | 引擎会做 peer 兼容性校验并自动回滚；不要绕过，按日志里的 `allow-version` 说明处理（有崩溃风险） |
| 控制台窗口乱码 | 控制台只输出 ASCII 进度，中文只进日志文件 |

## 提交与发布

- 提交信息用中文，前缀与历史一致：`feat:` / `fix:` / `docs:` / `chore:`。
- 发布：`git tag -a vX.Y.Z -m "..."` → `git push origin main vX.Y.Z` → `gh release create vX.Y.Z --title ... --notes-file ...`。
- 默认分支 `main`；远端 `origin` 走 SSH（若 git 报 host key 错误，用系统 OpenSSH：`$env:GIT_SSH_COMMAND = '"C:/Windows/System32/OpenSSH/ssh.exe"'`）。

## 常用命令

```powershell
# 只预览（不改任何东西）
pwsh -NoProfile -File .\Update-Dsh.ps1 -DryRun -Yes
pwsh -NoProfile -File .\Update-Dsh.ps1 -DryRun -Yes -Scope Plugins -Profile web

# 只更新插件（在 DSH 之外执行）
pwsh -NoProfile -File .\Update-Dsh.ps1 -Scope Plugins -Yes

# 回滚到最近一次备份（只回滚插件，不降级本体）
pwsh -NoProfile -File .\Update-Dsh.ps1 -Rollback

# 给 agent 用的「退出 DSH 后自动升级」
pwsh -NoProfile -File .\skills\upgrade-dsh\scripts\Invoke-DshAutoUpgrade.ps1 -Scope All
```

```bash
./check-updates.sh          # 只预览
./update-dsh.sh --yes       # 实际更新（先完全退出 DSH）
./update-dsh.sh --rollback  # 回滚
```
