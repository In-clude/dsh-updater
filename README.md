# dsh-updater — 一键更新 DSH 本体与插件

自动更新 **DeepSeek Harness（dsh 本体）** 和 **各 profile 的插件**，带版本预览、更新前备份、
兼容性保护和一键回滚。

> A Windows PowerShell script that updates the npm-installed
> [DeepSeek Harness](https://www.npmjs.com/package/@deepseek-ai/dsh) core and its profile plugins,
> with dry-run preview, backups, compatibility guards, and one-command rollback.

## 文件

| 文件 | 用途 |
|---|---|
| `Update-Dsh.ps1` | 主脚本 |
| `check-updates.cmd` | 双击预览：只显示有哪些新版本，**不改任何东西** |
| `update-dsh.cmd` | 双击更新：交互确认后实际执行 |

## 前置条件

- dsh 是 **npm 全局安装** 的（`npm i -g @deepseek-ai/dsh`，可用 `dsh --version` 验证）
- 有 `pnpm`（dsh 的插件管理依赖它；`pnpm --version`）
- PowerShell 7（`pwsh`）或 Windows PowerShell 5.1
- npm registry 可访问（国内可配置 `registry.npmmirror.com` 等镜像）

## 怎么用

### 1. 先预览

双击 `check-updates.cmd`（或 `pwsh -NoProfile -File .\Update-Dsh.ps1 -DryRun`）。它会列出：

```
== 更新计划
   dsh 本体：0.2.0-rc.2 -> 0.2.1-rc.2
   web / example-plugin-a：1.2.3 -> 1.4.0
   web / example-plugin-b：0.5.0 -> 0.6.1
   web / my-local-plugin：本地 link 包（link:../my-local-plugin），跳过
```

### 2. 退出 DSH，再实际更新

**更新本体必须完全退出 DSH**（含所有 `dsh` node 进程）：npm 要替换运行中进程占用的文件。
插件更新也会让运行中的会话重载模块，所以一并退出最稳妥。

双击 `update-dsh.cmd`，确认计划后回车即可。

### 3. 重启 DSH

插件与本体变更在下次启动时完全生效。

## 更新顺序与保护机制

1. **先更新本体**：`npm install -g @deepseek-ai/dsh@latest`，并把 npm 的 `latest` 换成实际命令。
2. **再更新插件**：对每个 profile 执行 `dsh plugin --profile <名字> update --latest <待更新包>`。
   - 由 dsh 插件管理器在安装前后做 peer 版本兼容性校验：**不兼容的新版本会被自动回滚**，
     不会把 profile 留在“装上了但启动被拒”的状态。
   - 若更新后仍有插件与本体不兼容，脚本会打印 dsh 给出的 `allow-version` 命令。
3. **校验**：`dsh --profile <名字> --dump-config`，确认 profile 还能正常组合。
4. **汇总**：成功/失败逐项列出，并给出日志与回滚命令。

`-WithinRanges` 时不加 `--latest`，只在 `package.json` 声明的 semver 范围内取最高版本
（注意：`^0.26.0` 这类 0.x 范围不会升到 0.27/0.28，此时默认策略才能升上去）。

**非注册表依赖**（`link:` / `file:` / `workspace:` / `github:` / `git+` / 压缩包 URL）不参与
`pnpm update`，会在计划里单独列出并注明类型：

- `github:` 依赖会检查远端默认分支，若固定的 commit 已落后，打印升级命令：
  `dsh plugin --profile <名字> add github:<owner>/<repo>`（dsh 会先做插件兼容性校验）；
- `link:` 目录默认只提示，加 `-UpdateLinked` 才会执行 `git pull --ff-only`。

## 参数

| 参数 | 说明 |
|---|---|
| `-Scope All\|Core\|Plugins` | 更新范围，默认 `All`（本体+插件） |
| `-Profile web,headless` | 指定 profile；默认自动发现 `$DSH_HOME\profiles` 下所有含 `package.json` 的 profile |
| `-WithinRanges` | 只在声明范围内更新（默认跨范围升到 latest） |
| `-DryRun` | 只预览，不修改 |
| `-Yes` | 不交互确认（定时任务用） |
| `-Force` | 检测到 DSH 正在运行也继续（不推荐，本体更新通常仍会失败） |
| `-SkipIfRunning` | 检测到 DSH 在运行时安静跳过并返回 0（定时任务用） |
| `-UpdateLinked` | 对 `link:` 的本地插件目录执行 `git pull --ff-only`（默认跳过；其它非注册表依赖不受影响） |
| `-NoBackup` | 跳过更新前备份（不推荐，等于放弃 `-Rollback`） |
| `-Rollback` | 回滚模式；`-RollbackId 20261023-213045` 可指定某次备份，默认最近一次 |

示例：

```powershell
# 只更新 web 的插件，不更新本体、不交互
pwsh -NoProfile -File .\Update-Dsh.ps1 -Scope Plugins -Profile web -Yes

# 预览，并检查本地 link: 插件会怎么处理
pwsh -NoProfile -File .\Update-Dsh.ps1 -DryRun -UpdateLinked

# 回滚到最近一次更新前
pwsh -NoProfile -File .\Update-Dsh.ps1 -Rollback
```

## 备份与回滚

更新前把每个 profile 的 `package.json`、`pnpm-lock.yaml`、`pnpm-workspace.yaml`、
`cordis.patch.yml`、`compatibility.json`（存在才备份）复制到：

```
$DSH_HOME\.dsh-update-backups\<时间戳>\
    manifest.json          # 时间、更新前后的 dsh 版本、被备份的 profile 与文件、逐项结果
    update.log             # 本次运行的完整输出
    web\...
```

回滚会恢复这些文件并执行 `pnpm install --frozen-lockfile`，把插件依赖装回更新前的版本。

> 回滚只恢复**插件**，不降级 dsh 本体。要降级本体：
> `npm install -g @deepseek-ai/dsh@<manifest.json 里的 dshBefore>`

## 常见问题

**提示“检测到 DSH 正在运行”**
先完全退出 DSH 再跑。只想插件更新：`-Scope Plugins`（会再确认一次）；定时任务：`-SkipIfRunning`。

**npm 报 EBUSY / EPERM**
仍有进程占用 DSH 安装目录（DSH 窗口、后台 job、终端里的子进程）。结束相关 `node` 进程后重跑。
脚本会打印恢复旧版本的命令。

**插件更新失败并提示 incompatible / 已回滚**
说明该插件的最新版还没适配当前 dsh 本体：先更新本体（脚本默认顺序已经如此）；若本体已最新，
就等插件发布兼容版本。也可按脚本打印的
`dsh plugin --profile web allow-version <包@版本> --dsh-version <版本> --accept-risk` 显式授权，
但插件与本体不匹配有崩溃或数据丢失风险。

**pnpm 提示 Ignored build scripts / approve-builds**
pnpm 11 默认拦截依赖的构建脚本。把提示里的包名加到 profile 的 `pnpm-workspace.yaml`
`allowBuilds`（值为 `true`）后重跑。

**Windows 提示“未进行数字签名，无法运行此脚本”**
从网络下载或复制来的文件带 `Zone.Identifier`（Internet 标记），而系统执行策略通常是
`RemoteSigned`，于是拒绝加载未签名的 `.ps1`。三种解决：

1. 双击 `update-dsh.cmd` / `check-updates.cmd` —— 它们内部用 `-ExecutionPolicy Bypass`
   运行，并在启动前自动对本目录执行 `Unblock-File`，不受影响（推荐）；
2. 手动解除锁定：`Get-ChildItem . -Recurse | Unblock-File`；
3. 临时运行：`pwsh -NoProfile -ExecutionPolicy Bypass -File .\Update-Dsh.ps1`。

用 `git clone` 代替下载 ZIP 可以从源头避免这个问题。

**非注册表依赖（`link:` / `github:` / `file:` 等）没被更新**
npm/pnpm 只更新 registry 版本范围，这些依赖需要单独处理：`link:` 目录用 `-UpdateLinked`
执行 `git pull --ff-only`（有本地改动或分叉时安全失败）；`github:` 固定 commit 落后时，
按计划里打印的 `dsh plugin --profile <名字> add github:<owner>/<repo>` 升级（会解除 commit
固定、跟随默认分支，dsh 会先做插件兼容性校验）；`file:` / `git+` / 压缩包 URL 只列出，不改动。

**手动放进 `node_modules`、不在 `package.json` 里的目录会怎样**
它不是 `package.json` 里声明的依赖，也不受 pnpm 管理，脚本不会删除或更新它。

**回滚后 pnpm 说 “Already up to date”，版本没退回去**
pnpm 会按 lockfile 的 mtime 做快速判断；脚本恢复备份后已主动刷新时间戳。手动恢复时若遇到，
`pnpm install --frozen-lockfile --force` 或先 `touch`（更新修改时间）一下恢复的文件。

## 定时任务（可选）

只自动更新插件（DSH 在运行时跳过；本体更新仍建议手动，因为必须退出 DSH）：

```
schtasks /Create /TN "DSH-Update-Plugins" /SC DAILY /ST 12:00 ^
  /TR "pwsh -NoProfile -ExecutionPolicy Bypass -File \"C:\tools\dsh-updater\Update-Dsh.ps1\" -Scope Plugins -Yes -SkipIfRunning"
```

删除：`schtasks /Delete /TN "DSH-Update-Plugins" /F`。
注意：自动更新插件后需要重启 DSH 才完全生效。

## 已知限制

- 只适用于 **npm 全局安装** 的 dsh；桌面版或其它安装方式不适用。
- 不降级本体、不切换发布通道（latest 由 npm registry 的 `dist-tags.latest` 决定）。
- 不改动 profile 的 `dsh.profile.bundles` 选择，只更新依赖版本。
- 兼容性保护来自 dsh 插件管理器；跨大版本的运行时行为变化仍需更新后人工确认。

## 测试环境

- Windows 11 + PowerShell 7.6 / Windows PowerShell 5.1
- dsh `0.2.0-rc.2` ~ `0.2.1-rc.5`（npm 全局安装）+ pnpm 11
- 已验证：正常升级、插件不兼容被 dsh 自动回滚、备份与回滚、`--dump-config` 校验、
  非注册表依赖分类与 GitHub 依赖远端检查、包装脚本自动 `Unblock-File`

## 更新日志

- **1.1.0**：非注册表依赖（`link:`/`file:`/`workspace:`/`github:`/`git+`/URL）分类标注；
  `github:` 依赖检查远端默认分支并在落后时打印升级命令；包装脚本启动时自动 `Unblock-File`，
  解决下载文件被执行策略拦截的问题（.cmd 保持纯 ASCII）。
- **1.0.0**：首次发布。本体+插件更新、兼容性回滚、备份、`-Rollback`、定时任务参数。

## 许可

[MIT](LICENSE)
