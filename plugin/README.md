# dsh-update-plugin

DSH 插件（bundle）：检查并执行 dsh 更新。发布到 npm 的包名是 `dsh-update-plugin`。

- `/update` 检查本体与 profile 插件的可用新版本；`/update apply` 退出 dsh 后由计划任务托管升级并自动重启（`--no-quit` 只排队，不自动退出、也不自动重启）。
- 升级引擎复用仓库根的 `Update-Dsh.ps1`（备份 / 兼容性校验 / 回滚都由它负责）；发布到 npm 时由 `prepack` 把它复制进包内 `scripts/Update-Dsh.ps1`。
- 详细说明见 [docs/DETAIL.md](docs/DETAIL.md)。

## 安装

从 npm 安装（包内自带更新引擎副本，不需要本仓库）：

```powershell
dsh plugin --profile web add dsh-update-plugin
```

换 profile 改 `--profile`；锁版本用 `dsh-update-plugin@0.1.1`；卸载用
`dsh plugin --profile web remove dsh-update-plugin`。装好后在输入框输入 `/update` 验证。

## 模块

| 文件 | 运行位置 | 职责 |
|---|---|---|
| `index.js` | dsh 进程内 | 命令、定时检查、排 worker、请求退出 |
| `checker.js` | 两边 | 版本读取、registry 查询、状态文件 |
| `worker.js` | 计划任务（进程外） | 等 dsh 退出、跑引擎、重启 dsh |
| `scheduler.js` | dsh 进程内 | schtasks 注册/启动/删除 |
| `output.js` | 两边 | 子进程输出解码（Windows 下 PowerShell 按 GBK 输出） |
| `types.js` | 不加载 | 共享 JSDoc 类型：job 描述、升级状态、检查结果 |

## 开发

```powershell
# 依赖（typescript + @types/node；只需一次）
npm install

# 类型校验：JSDoc + checkJs，只报错、不产出文件
npm run typecheck

# 语法检查
node --check index.js; node --check checker.js; node --check worker.js; node --check scheduler.js

# 单独跑一次检查（不依赖 dsh 运行时）
node --input-type=module -e "import('./checker.js').then(async m => console.log(JSON.stringify(await m.runCheck({ profileContext: { name: 'web', dir: '<profile 目录>', installAnchor: '<dsh>/package.json' } }), null, 2)))"

# 单独跑 worker（需要一份 job.json；建议把 dshHome 指到临时目录，避免写入真实状态）
node worker.js --job <job.json>
```

从本仓库安装：用 dsh 的插件管理（Plugins 页或 `plugin_manager` 的 `install_bundle`）指向本目录。

发布到 npm：

```powershell
cd plugin
npm publish --registry=https://registry.npmjs.org
```

`prepack` 会自动把仓库根的 `Update-Dsh.ps1` 复制到包内 `scripts/`（该目录是生成物，不提交）。

改动 `index.js` / `worker.js` 后需要重新加载插件（停用再启用）才能生效。
