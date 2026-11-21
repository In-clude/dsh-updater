---
name: upgrade-dsh
description: "用 dsh-updater 脚本升级/更新 DeepSeek Harness（dsh）：先预览本体与 profile 插件的可用新版本，然后在用户完全退出 DSH 后通过 Windows 计划任务自动完成升级，重启后验证结果，需要时可回滚。Use this skill whenever the user says 升级 dsh、更新 dsh、把 DSH 升到最新、看看 dsh 有没有新版本、更新 DSH 本体/插件、回滚 dsh 更新，or mentions dsh-updater / Update-Dsh.ps1 / update-dsh.sh / check-updates.cmd；也用于用户重启 DSH 后询问“更新成功了吗”时的验证。"
---

# 升级 DeepSeek Harness（dsh）

用本机的 **dsh-updater** 脚本升级 dsh 本体与各 profile 的插件。脚本自带预览、更新前备份、插件兼容性校验和回滚；本 skill 负责编排：定位脚本 → 预览 → 在用户退出 DSH 后通过 Windows 计划任务自动完成升级 → 重启后验证。

## 路径约定

- `<skill>`：本 skill 基目录（DSH 运行时提供；安装后通常是 `<DSH_HOME>\skills\upgrade-dsh`），脚本在 `<skill>\scripts\`
- `<root>`：dsh-updater 目录。默认按顺序查找：`-UpdaterRoot` 参数 → 环境变量 `DSH_UPDATER_HOME` → 仓库内相对位置（本 skill 位于 `<repo>\skills\upgrade-dsh` 时即 `<repo>`）；都找不到时先问用户
- `<root>\Update-Dsh.ps1` 是主脚本（Windows），`<root>\README.md` 有完整参数说明

## 三条硬约束（违反就会失败）

1. **不能在当前会话里直接升级本体。** agent 自己就运行在 dsh 进程里；`Update-Dsh.ps1` 检测到 DSH 在运行会拒绝更新本体（或 npm 报 EBUSY），因为要替换被占用的文件。
2. **不要用 `Start-Process` / `nohup` / `&` 把升级“放到后台”。** DSH 在 Windows 上用 kill-on-close 的 Job Object 管理子进程，DSH 退出时这些后台进程会被一并杀掉，升级会静默丢失。唯一可靠的方式是通过**任务计划程序**启动一个与 DSH 无关的进程——`scripts\Invoke-DshAutoUpgrade.ps1` 已经封装好了这件事。
3. **调用 updater 必须带 `-Yes`。** 脚本在“开始更新？”处会 `Read-Host`，非交互调用会卡住或中止；即使 `-DryRun` 也会走到这个确认（虽然不做修改），同样要带 `-Yes`。

## 标准流程

### 1. 预览（只读，约 5–15 秒）

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "<root>\Update-Dsh.ps1" -DryRun -Yes
```

- 工具超时给足：`timeoutMs` ≥ 300000。
- 把输出里的「更新计划」转述给用户：本体 `x -> y`，各 profile 的插件 `旧 -> 新`。
- 若输出「所有内容都已是最新，无需更新」，到此结束，不要启动自动升级。
- 若提示检测到 DSH 正在运行：正常（agent 就在 DSH 里），预览不受影响。
- 用户只是随便问问时，先给预览计划，确认后再启动自动升级。

### 2. 启动「退出 DSH 后自动升级」

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\Invoke-DshAutoUpgrade.ps1" -Scope All
```

可选参数：`-Scope All|Core|Plugins`、`-Profile web,headless`、`-WithinRanges`、`-UpdateLinked`、`-NoBackup`、`-WaitTimeoutMinutes 120`、`-PauseSeconds 120`、`-Rollback`（见回滚）。

脚本会：注册并立即启动计划任务 `DSH-AutoUpdate-<时间戳>` → worker 等到**所有 dsh node 进程**退出（稳定 6 秒）→ 以 `-Scope All -Yes` 运行 updater。日志：`$DSH_HOME\.dsh-update-backups\logs\auto-update-<时间戳>.log`；状态：同目录 `auto-update-latest.json`。

成功时最后一行形如：

```
[DSH-AUTO-UPDATE] task=DSH-AutoUpdate-20261121-235500 log=... latest=...
```

若没有这一行，读脚本输出报错，并检查 `Get-ScheduledTask -TaskName 'DSH-AutoUpdate-*'`。

### 3. 让用户完全退出 DSH

告诉用户（可原话转述）：

> 请**完全退出 DSH**：关掉所有 DSH 窗口，以及终端里运行的 `dsh`（只关浏览器页面不算）。启动自动升级时已经弹出一个标题为「DSH 自动升级」的窗口，它正在等 DSH 退出，退出后会自动开始升级；等它显示「升级完成」**再重新打开 DSH**，不要提前重开，否则 npm 可能因文件占用失败。（如果没看到窗口，以日志里的进度为准。）

同时给出日志路径和计划任务名，方便用户自己看进度。退出 DSH 会结束当前会话，用户重开 DSH 后再回到会话继续验证。

### 4. 重启后验证

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\Get-DshUpdateStatus.ps1"
```

它汇总：`auto-update-latest.json` 的状态（waiting/running/finished/failed/timeout）、dsh 版本前后、updater 退出码、备份目录、最近备份清单、残留计划任务、日志尾部。据此报告：`finished` + 退出码 0 → 成功；`failed`/`timeout` → 贴出关键日志并给回滚命令。

## 其他场景

### 只更新插件

同样建议走自动升级（`-Scope Plugins`），更新在 DSH 退出后进行最稳。运行中的会话可能重载插件模块，所以不建议在会话内直接热更新。

### 回滚

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\Invoke-DshAutoUpgrade.ps1" -Rollback
# 指定某次备份：-Rollback -RollbackId 20261023-213045
```

回滚只恢复**插件**（profile 清单 + `pnpm install --frozen-lockfile`），不降级 dsh 本体；要降级本体，按备份目录 `manifest.json` 里的 `dshBefore` 执行 `npm install -g @deepseek-ai/dsh@<版本>`。

### 清理残留计划任务

```powershell
Get-ScheduledTask -TaskName 'DSH-AutoUpdate-*' | Unregister-ScheduledTask -Confirm:$false
```

## 失败排查

- 日志：`$DSH_HOME\.dsh-update-backups\logs\auto-update-*.log`；每个备份目录里还有 updater 自己写的 `update.log` 与 `manifest.json`
- `EBUSY / EPERM`：仍有 dsh/node 占用安装目录，确认进程真的退干净后重跑
- 插件 incompatible / 已自动回滚：插件最新版未适配当前 dsh 本体；按脚本打印的 `allow-version` 命令显式授权有崩溃/数据丢失风险
- `Ignored build scripts` / `approve-builds`：按提示把包名加入 profile 的 `pnpm-workspace.yaml` 的 `allowBuilds`
- 状态一直 `waiting`：DSH 没退干净；超过等待上限（默认 120 分钟）后 worker 会放弃并退出
- 参数与机制细节：`<root>\README.md`

## Linux

本 skill 的自动升级脚本只支持 Windows（依赖任务计划程序）。Linux 上 DSH 用 transient systemd scope 管理子进程，`nohup ... &` 同样会在 DSH 退出时被回收；请在外部终端退出 DSH 后运行 `./update-dsh.sh --yes`（或用 `systemd-run --user --scope` 托管），详见 README 的 Linux 章节。

## 汇报模板

```markdown
## dsh 更新报告
- 本体：0.2.2-rc.1 → 0.2.2-rc.5（或：已是最新）
- 插件：web / a 1.3.0 → 1.4.1；web / b 0.30.1 → 0.32.1
- 自动升级：计划任务 DSH-AutoUpdate-... 已启动，等待退出 DSH
- 日志：<路径>
- 回滚：pwsh -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\Invoke-DshAutoUpgrade.ps1" -Rollback
- 下一步：完全退出 DSH → 等「DSH 自动升级」窗口显示完成 → 重开 DSH
```
