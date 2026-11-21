# dsh-updater — 一键更新 DSH 本体与插件

自动更新 **DeepSeek Harness（dsh 本体）** 和 **各 profile 的插件**，带版本预览、更新前备份、
兼容性保护和一键回滚。

跨平台，同一套功能两种入口：

- **Windows**：PowerShell（`Update-Dsh.ps1` + 双击用 `.cmd` 包装）
- **Linux**：原生 bash（`update-dsh.sh` + `check-updates.sh`），**不需要安装 PowerShell**

> Cross-platform updater for the npm-installed
> [DeepSeek Harness](https://www.npmjs.com/package/@deepseek-ai/dsh) core and its profile
> plugins, with dry-run preview, backups, compatibility guards, and one-command rollback.
> Windows uses PowerShell; Linux uses native bash.

## 文件

| 文件 | 平台 | 用途 |
|---|---|---|
| `Update-Dsh.ps1` | Windows | 主脚本（PowerShell 7 / Windows PowerShell 5.1） |
| `check-updates.cmd` | Windows | 双击预览：只显示有哪些新版本，**不改任何东西** |
| `update-dsh.cmd` | Windows | 双击更新：交互确认后实际执行 |
| `update-dsh.sh` | Linux | 主脚本（bash ≥ 4.4） |
| `check-updates.sh` | Linux | 只预览：等价于 `update-dsh.sh --dry-run` |
| `skills/upgrade-dsh/` | Windows | 可选的 DSH skill：由 agent 编排「预览 → 退出 DSH 后自动升级 → 重启验证」 |

## DSH skill（可选）

仓库附带一个 [DSH](https://github.com/deepseek-ai/deepseek-harness) skill（`skills/upgrade-dsh/`），
让 agent 直接完成整条升级链路：预览可用版本 → 在用户完全退出 DSH 后通过 Windows 计划任务自动升级 → 重启后验证。

1. 把 skill 复制到 DSH 的全局 skills 目录（Windows 默认 `%USERPROFILE%\.dsh\skills\upgrade-dsh`）：

   ```powershell
   $dest = Join-Path $env:USERPROFILE '.dsh\skills\upgrade-dsh'
   New-Item -ItemType Directory -Force $dest | Out-Null
   Copy-Item .\skills\upgrade-dsh\* $dest -Recurse -Force
   ```

2. 在 DSH 里说「升级 dsh」或调用 `/upgrade-dsh`。skill 会先跑 `-DryRun` 预览，再注册计划任务
   `DSH-AutoUpdate-<时间戳>`：等所有 dsh 进程退出后自动执行 `Update-Dsh.ps1 -Scope All -Yes`，
   并把日志与状态写到 `$DSH_HOME\.dsh-update-backups\logs\`；重启 DSH 后可用
   `scripts\Get-DshUpdateStatus.ps1` 验证结果。

skill 按 `-UpdaterRoot` → 环境变量 `DSH_UPDATER_HOME` → 仓库内相对位置 → 默认路径的顺序定位
`Update-Dsh.ps1`。仓库不在默认路径时，复制 skill 后设置一次环境变量即可：

```powershell
setx DSH_UPDATER_HOME "D:\tools\dsh-updater"
```

> skill 的“退出后自动升级”依赖 Windows 任务计划程序，只支持 Windows；Linux 请直接用 `update-dsh.sh`。

## 前置条件

两个平台都要求：

- dsh 是 **npm 全局安装** 的（`npm i -g @deepseek-ai/dsh`，可用 `dsh --version` 验证）
- 有 `pnpm`（dsh 的插件管理依赖它；`pnpm --version`）
- npm registry 可访问（国内可配置 `registry.npmmirror.com` 等镜像）

Windows 额外要求：PowerShell 7（`pwsh`）或 Windows PowerShell 5.1。

Linux 额外要求：

- `bash` ≥ 4.4（主流发行版默认满足）
- `node`（dsh 自身依赖；脚本用 node 解析 JSON，不额外依赖 `jq`）
- `dsh` / `npm` / `pnpm` 在 `PATH` 里
- `git` 可选：`github:` 依赖的远端检查与 `link:` 依赖的 `git pull` 需要

## 怎么用

### Windows

#### 1. 先预览

双击 `check-updates.cmd`（或 `pwsh -NoProfile -File .\Update-Dsh.ps1 -DryRun`）。它会列出：

```
== 更新计划
   dsh 本体：0.2.0-rc.2 -> 0.2.1-rc.2
   web / example-plugin-a：1.2.3 -> 1.4.0
   web / example-plugin-b：0.5.0 -> 0.6.1
   web / my-local-plugin：本地 link 包（link:../my-local-plugin），跳过
```

#### 2. 退出 DSH，再实际更新

**更新本体必须完全退出 DSH**（含所有 `dsh` node 进程）：npm 要替换运行中进程占用的文件。
插件更新也会让运行中的会话重载模块，所以一并退出最稳妥。

双击 `update-dsh.cmd`，确认计划后回车即可。

#### 3. 重启 DSH

插件与本体变更在下次启动时完全生效。

### Linux

```bash
# 首次：git clone 克隆下来的 .sh 可能没有执行权限，按需加一次
chmod +x update-dsh.sh check-updates.sh

# 1. 先预览（不修改任何文件）
./check-updates.sh

# 2. 完全退出 DSH，再实际更新（交互确认）
./update-dsh.sh

# 或者不交互（定时任务/无人值守）
./update-dsh.sh --yes

# 3. 重启 DSH 使变更生效
```

没有执行权限时也可以直接 `bash update-dsh.sh` 运行。脚本在 Linux 上会：

- 通过 `ps` 识别正在运行的 dsh（匹配 `@deepseek-ai/dsh/lib/bin.js`，以及 npm 全局 bin
  软链形式 `node /usr/local/bin/dsh`），并阻止更新本体；容器里没有 `ps` 时退化扫描 `/proc`；
- 把 `$DSH_HOME` 默认为 `~/.dsh`（与 dsh 自身一致；支持 `~`、相对路径，可用环境变量覆盖）；
- 用 `node` 解析 `package.json`、`pnpm outdated --format json` 和备份清单，不依赖 `jq`；
- `check-updates.sh` 只做预览，收到 `--rollback` 参数会直接拒绝，避免误改。

## 更新顺序与保护机制

1. **先更新本体**：`npm install -g @deepseek-ai/dsh@latest`，并把 npm 的 `latest` 换成实际命令。
2. **再更新插件**：对每个 profile 执行 `dsh plugin --profile <名字> update --latest <待更新包>`。
   - 由 dsh 插件管理器在安装前后做 peer 版本兼容性校验：**不兼容的新版本会被自动回滚**，
     不会把 profile 留在“装上了但启动被拒”的状态。
   - 若更新后仍有插件与本体不兼容，脚本会打印 dsh 给出的 `allow-version` 命令。
3. **校验**：`dsh --profile <名字> --dump-config`，确认 profile 还能正常组合。
4. **汇总**：成功/失败逐项列出，并给出日志与回滚命令。

`--within-ranges`（Windows：`-WithinRanges`）时不加 `--latest`，只在 `package.json` 声明的
semver 范围内取最高版本（注意：`^0.26.0` 这类 0.x 范围不会升到 0.27/0.28，此时默认策略才能升上去）。

**非注册表依赖**（`link:` / `file:` / `workspace:` / `github:` / `git+` / 压缩包 URL）不参与
`pnpm update`，会在计划里单独列出并注明类型：

- `github:` 依赖会检查远端默认分支，若固定的 commit 已落后，打印升级命令：
  `dsh plugin --profile <名字> add github:<owner>/<repo>`（dsh 会先做插件兼容性校验）；
- `link:` 目录默认只提示，加 `--update-linked`（Windows：`-UpdateLinked`）才会执行
  `git pull --ff-only`。

## 参数

### Windows（PowerShell）

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

### Linux（bash）

| 选项 | 说明 |
|---|---|
| `--scope all\|core\|plugins` | 更新范围，默认 `all`（本体+插件） |
| `--profile <名字>[,<名字>]` | 指定 profile，可重复或逗号分隔；默认自动发现 `$DSH_HOME/profiles` 下所有含 `package.json` 的 profile |
| `--within-ranges` | 只在声明范围内更新（默认跨范围升到 latest） |
| `--dry-run` / `-n` | 只预览，不修改 |
| `--yes` / `-y` | 不交互确认（定时任务用） |
| `--force` | 检测到 DSH 正在运行也继续（不推荐，本体更新通常仍会失败） |
| `--skip-if-running` | 检测到 DSH 在运行时安静跳过并返回 0（定时任务用） |
| `--update-linked` | 对 `link:` 的本地插件目录执行 `git pull --ff-only`（默认跳过） |
| `--no-backup` | 跳过更新前备份（不推荐，等于放弃 `--rollback`） |
| `--rollback` | 回滚模式，默认最近一次备份 |
| `--rollback-id <时间戳>` | 配合 `--rollback` 指定备份目录名，如 `20261023-213045` |
| `-h, --help` | 显示帮助 |
| `-V, --version` | 显示版本号 |

两个平台的参数一一对应；Linux 版用 GNU 风格长选项，不再使用 PowerShell 的 `-Name` 形式。

示例：

```powershell
# Windows：只更新 web 的插件，不更新本体、不交互
pwsh -NoProfile -File .\Update-Dsh.ps1 -Scope Plugins -Profile web -Yes

# Windows：预览，并检查本地 link: 插件会怎么处理
pwsh -NoProfile -File .\Update-Dsh.ps1 -DryRun -UpdateLinked

# Windows：回滚到最近一次更新前
pwsh -NoProfile -File .\Update-Dsh.ps1 -Rollback
```

```bash
# Linux：只更新 web 的插件，不更新本体、不交互
./update-dsh.sh --scope plugins --profile web --yes

# Linux：预览，并检查本地 link: 插件会怎么处理
./update-dsh.sh --dry-run --update-linked

# Linux：回滚到最近一次更新前
./update-dsh.sh --rollback
```

## 备份与回滚

更新前把每个 profile 的 `package.json`、`pnpm-lock.yaml`、`pnpm-workspace.yaml`、
`cordis.patch.yml`、`compatibility.json`（存在才备份）复制到：

```
$DSH_HOME/.dsh-update-backups/<时间戳>/     # Windows 路径为 $DSH_HOME\.dsh-update-backups\
    manifest.json          # 时间、更新前后的 dsh 版本、被备份的 profile 与文件、逐项结果
    update.log             # 本次运行的完整输出
    web/...
```

回滚会恢复这些文件并执行 `pnpm install --frozen-lockfile`，把插件依赖装回更新前的版本。
两个平台的备份目录与 `manifest.json` 格式相同，可以互相识别（Windows 备份也能在 Linux 上
`--rollback`，反之亦然；Linux 版读清单时会自动兼容 Windows PowerShell 5.1 写出的 BOM/CRLF）。

想先看回滚会做什么，可加 `--dry-run`：`./update-dsh.sh --rollback --dry-run` 只列出备份与
将恢复的文件，不修改任何内容（`check-updates.sh` 不接受回滚参数）。

> 回滚只恢复**插件**，不降级 dsh 本体。要降级本体：
> `npm install -g @deepseek-ai/dsh@<manifest.json 里的 dshBefore>`

回滚命令：

```powershell
pwsh -NoProfile -File .\Update-Dsh.ps1 -Rollback
```

```bash
./update-dsh.sh --rollback
```

## 常见问题

**提示“检测到 DSH 正在运行”**
先完全退出 DSH 再跑。只想插件更新：`-Scope Plugins` / `--scope plugins`（会再确认一次）；
定时任务：`-SkipIfRunning` / `--skip-if-running`。

**npm 报 EBUSY / EPERM（Windows）**
仍有进程占用 DSH 安装目录（DSH 窗口、后台 job、终端里的子进程）。结束相关 `node` 进程后重跑。
脚本会打印恢复旧版本的命令。

**npm 报 EACCES / EPERM（Linux）**
全局安装目录不可写。三种做法：用 nvm/volta 等用户级 Node；或把 npm 全局目录改到用户空间
（`npm config set prefix "$HOME/.npm-global"`，再把 `$HOME/.npm-global/bin` 加入 `PATH`）；
或临时 `sudo` 重跑（不建议，root 权限会带进全局 `node_modules`）。脚本检测到这类错误时会打印提示。

**Linux 下 cron/systemd 里跑没反应**
没有终端时脚本默认中止交互确认。定时任务请加 `--yes --skip-if-running`，并确保 cron 的
`PATH` 里能找到 `node`/`dsh`/`npm`/`pnpm`（nvm 安装的 Node 需要显式 source 或在 crontab 里补
`PATH`）。

**提示 `Permission denied` 或 `bash: ./update-dsh.sh: 权限不够`**
`chmod +x update-dsh.sh check-updates.sh`，或直接用 `bash update-dsh.sh`。

**提示找不到 node（Linux）**
Linux 版用 node 解析 JSON（不依赖 jq）。把 node 加入 `PATH`，或从 nvm 环境里运行脚本。

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
npm/pnpm 只更新 registry 版本范围，这些依赖需要单独处理：`link:` 目录用 `-UpdateLinked` /
`--update-linked` 执行 `git pull --ff-only`（有本地改动或分叉时安全失败）；`github:` 固定 commit
落后时，按计划里打印的 `dsh plugin --profile <名字> add github:<owner>/<repo>` 升级（会解除
commit 固定、跟随默认分支，dsh 会先做插件兼容性校验）；`file:` / `git+` / 压缩包 URL 只列出，不改动。

**手动放进 `node_modules`、不在 `package.json` 里的目录会怎样**
它不是 `package.json` 里声明的依赖，也不受 pnpm 管理，脚本不会删除或更新它。

**回滚后 pnpm 说 “Already up to date”，版本没退回去**
pnpm 会按 lockfile 的 mtime 做快速判断；脚本恢复备份后已主动刷新时间戳。手动恢复时若遇到，
`pnpm install --frozen-lockfile --force` 或先 `touch`（更新修改时间）一下恢复的文件。

## 定时任务（可选）

只自动更新插件（DSH 在运行时跳过；本体更新仍建议手动，因为必须退出 DSH）：

Windows：

```
schtasks /Create /TN "DSH-Update-Plugins" /SC DAILY /ST 12:00 ^
  /TR "pwsh -NoProfile -ExecutionPolicy Bypass -File \"C:\tools\dsh-updater\Update-Dsh.ps1\" -Scope Plugins -Yes -SkipIfRunning"
```

删除：`schtasks /Delete /TN "DSH-Update-Plugins" /F`。

Linux（crontab，每天 12:00）：

```cron
0 12 * * * cd /opt/dsh-updater && ./update-dsh.sh --scope plugins --yes --skip-if-running >> /var/log/dsh-updater.log 2>&1
```

注意：自动更新插件后需要重启 DSH 才完全生效。

## 已知限制

- 只适用于 **npm 全局安装** 的 dsh；桌面版或其它安装方式不适用。
- 不降级本体、不切换发布通道（latest 由 npm registry 的 `dist-tags.latest` 决定）。
- 不改动 profile 的 `dsh.profile.bundles` 选择，只更新依赖版本。
- 兼容性保护来自 dsh 插件管理器；跨大版本的运行时行为变化仍需更新后人工确认。
- Linux 版需要 bash ≥ 4.4 与 node；不能用 `dash` 等其它 shell 直接执行。
- Linux 版按 Linux 语义实现（`ps`、路径、权限提示）；macOS 未专门适配。

## 测试环境

- Windows 11 + PowerShell 7.6 / Windows PowerShell 5.1
- Linux bash 版实机验证：Kali Linux 6.19（bash 5.3、node 24、pnpm 12、dsh `0.2.1-rc.5`
  npm 全局安装）——真实 `dsh --version`、`npm view`、`pnpm outdated --format json`、
  `ps` 进程识别（npm 软链形式 `node .../dsh`）与无 `ps` 时的 `/proc` 回退、
  `check-updates.sh` 执行位与预览、空 DSH_HOME、真实插件升级计划均通过。
- 另在 bash 5.2（Git Bash/MSYS2）上用伪 `DSH_HOME` + 伪 `dsh/pnpm/npm/git/ps` 跑完整
  端到端用例：实际更新、备份与 `manifest.json`、`--rollback`、插件不兼容自动回滚分支、
  `--skip-if-running`/`--force`、`--dry-run` 回滚预览、BOM/CRLF 的 Windows 备份清单回滚、
  含空格路径、DSH_HOME 为空白/含 `~`、非法 profile 名、参数错误处理。
- dsh `0.2.0-rc.2` ~ `0.2.1-rc.5`（npm 全局安装）+ pnpm 11/12
- 已验证：正常升级、插件不兼容被 dsh 自动回滚、备份与回滚、`--dump-config` 校验、
  非注册表依赖分类与 GitHub 依赖远端检查、包装脚本自动 `Unblock-File`
- dsh `0.2.0-rc.2` ~ `0.2.1-rc.5`（npm 全局安装）+ pnpm 11
- 已验证：正常升级、插件不兼容被 dsh 自动回滚、备份与回滚、`--dump-config` 校验、
  非注册表依赖分类与 GitHub 依赖远端检查、包装脚本自动 `Unblock-File`

## 更新日志

- **1.2.0**：新增 Linux 原生 bash 版 `update-dsh.sh` / `check-updates.sh`（功能与 Windows
  版对齐，参数为 GNU 风格长选项）；Windows 版逻辑不变，仅版本号对齐。
- **1.1.0**：非注册表依赖（`link:`/`file:`/`workspace:`/`github:`/`git+`/URL）分类标注；
  `github:` 依赖检查远端默认分支并在落后时打印升级命令；包装脚本启动时自动 `Unblock-File`，
  解决下载文件被执行策略拦截的问题（.cmd 保持纯 ASCII）。
- **1.0.0**：首次发布。本体+插件更新、兼容性回滚、备份、`-Rollback`、定时任务参数。

## 许可

[MIT](LICENSE)
