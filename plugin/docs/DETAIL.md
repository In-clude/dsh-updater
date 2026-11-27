# DSH 更新检查与升级（dsh-updater 插件）

在 dsh 里检查并执行 dsh 更新：比对本体与 profile 插件的可用新版本，确认后退出 dsh、在进程外完成升级、再自动重启 dsh。

## 功能

- **定时检查**：启动后 20 秒一次，之后按间隔（默认 6 小时）自动比对；结果缓存 10 分钟。
- **一键升级**：`/update apply` 先跑完整预览（含兼容性判断），确认有更新后把升级交给进程外的 worker；worker 等 dsh 退出后执行引擎、重启 dsh。
- **失败可见**：worker 无论成功失败都会写状态并尝试重启 dsh，`/update status` 给出状态、备份目录与日志路径。
- **回滚**：`/update rollback [备份ID]` 走同一条 worker 链路执行插件的回滚（不降级本体）。
- **备份清理**：成功后只保留最近 N 个备份目录（默认 5）。

## 用法

| 命令 | 说明 |
|---|---|
| `/update` | 显示当前检查结果（命中缓存则直接返回） |
| `/update --refresh` | 强制重新检查 |
| `/update status` | 检查结果 + 上次升级结果/备份/日志 |
| `/update apply` | 排升级 → 倒计时退出 dsh → worker 升级 → 自动重启 |
| `/update apply --no-quit` | 只排队，由你自己关闭 dsh |
| `/update rollback [id]` | 回滚插件（默认最近一次备份） |

## 工作方式

```
/update apply
  ├─ 跑 Update-Dsh.ps1 -DryRun -Yes 拿权威计划（无更新则直接返回）
  ├─ 写 job.json，注册计划任务 DSH-AutoUpdate-<时间戳> 并启动
  ├─ 等 worker 写出 waiting 状态（30 秒），失败则清理任务并报错
  └─ 倒计时后请求 dsh 优雅退出（ctx.appExit）

worker（进程外，由计划任务拉起，启动后立即注销自身任务）
  ├─ 等 dsh 进程消失（默认最多 120 分钟）
  ├─ pwsh scripts/Update-Dsh.ps1 -Scope <scope> -Yes（输出全量落日志）
  ├─ 写 auto-update-latest.json（状态/前后版本/退出码/备份目录）
  └─ 重启 dsh（沿用 profile 与 relaunchArgs）
```

**为什么必须由计划任务托管**：dsh 在 Windows 上用 kill-on-close 的 Job Object 管理子进程，任何挂在 dsh 进程树下的后台进程都会随 dsh 退出被杀掉；计划任务由 Task Scheduler 服务拉起，与 dsh 无关。

## 限制

- **仅 Windows**：计划任务是本机唯一可靠的“逃出进程树”方式。Linux 请直接用仓库里的 `update-dsh.sh`。
- **必须退出 dsh**：正在运行的 dsh 锁着自己的安装目录，替换文件只能在没有 dsh 进程时进行。这是物理约束，不是实现取舍。
- **升级引擎来自仓库**：默认使用插件目录上一级的 `Update-Dsh.ps1`（本插件与引擎同仓）。插件独立分发时，用配置项 `updaterRoot` 指向引擎所在目录。
- **兼容性判断在预览里**：轻量检查只回答“有没有新版本”；某个新版本是否可用，以完整预览和引擎的兼容性校验为准（不兼容的插件会被引擎自动回滚）。

## 配置项

| 字段 | 默认 | 说明 |
|---|---|---|
| `autoCheck` | `true` | 启动时 + 定时检查 |
| `intervalHours` | `6` | 检查间隔（1–168） |
| `autoQuit` | `true` | apply 后自动退出 dsh |
| `quitDelaySeconds` | `5` | 退出前倒计时 |
| `scope` | `All` | 升级范围：`All` / `Core` / `Plugins` |
| `profiles` | `[]` | 只更新这些 profile（空 = 引擎自动发现） |
| `autoRelaunch` | `true` | 升级后重启 dsh |
| `relaunchArgs` | `[]` | 追加到重启命令的参数（如 `--port 3080`） |
| `updaterRoot` | `''` | 引擎所在目录；空 = 用插件上一级的 `Update-Dsh.ps1` |
| `waitTimeoutMinutes` | `120` | 等 dsh 退出的上限 |
| `keepBackups` | `5` | 成功后保留的备份目录数 |

## 数据文件

都在 `$DSH_HOME\.dsh-update-backups\`：

| 文件 | 内容 |
|---|---|
| `latest-check.json` | 检查结果（时间、本体与插件版本、`updateAvailable`、错误、下次检查时间） |
| `logs\auto-update-<时间戳>.log` | worker 与引擎的完整输出 |
| `logs\auto-update-<时间戳>.job.json` | worker 的启动参数（排障用） |
| `logs\auto-update-latest.json` | 最近一次升级状态 |
| `<时间戳>\` | 引擎生成的备份（`manifest.json` + `update.log` + profile 清单） |

## 卸载

Plugins 页停用或移除本插件即可。已排队的 worker 不受影响（它独立运行）；需要取消时在终端删除计划任务：`schtasks /Delete /TN DSH-AutoUpdate-* /F`。
