/**
 * 插件的共享 JSDoc 类型（纯声明，无运行时代码）。
 *
 * index.js（dsh 进程内）与 worker.js（独立进程）通过 `import('./types.js').X`
 * 引用同一批形状：job 描述、升级状态、检查结果都是磁盘上的 JSON，两边字段必须一致。
 * 运行时不加载本文件，`npm run typecheck` 会校验这些形状是否与实现吻合。
 */

/**
 * 一条包版本记录。
 * @typedef {object} PackageVersion
 * @property {string} pkg 包名
 * @property {string} [current] 已安装版本（读不到时缺省）
 * @property {string} [latest] registry 上的最新版本（查询失败时缺省）
 */

/**
 * dsh 本体版本对。
 * @typedef {object} CoreVersion
 * @property {string} [current]
 * @property {string} [latest]
 */

/**
 * 轻量检查结果，落在 `<DSH_HOME>/.dsh-update-backups/latest-check.json`。
 *
 * `core`、`profiles`、`updateAvailable` 在写失败或旧版本文件里可能缺失，
 * 读取方一律按缺省处理，所以这里都是可选的。
 * @typedef {object} CheckState
 * @property {number} schemaVersion
 * @property {string} checkedAt ISO 时间
 * @property {string} [registry]
 * @property {CoreVersion} [core]
 * @property {Record<string, PackageVersion[]>} [profiles]
 * @property {boolean} [updateAvailable]
 * @property {string | null} [error]
 * @property {number} [failures]
 * @property {string} [nextCheckAt]
 */

/**
 * dsh 注入的 profile 上下文（只声明本插件用到的字段）。
 * @typedef {object} ProfileContext
 * @property {string} name profile 名（如 web）
 * @property {string} dir profile 目录
 * @property {string} installAnchor dsh 本体 package.json 的路径
 */

/**
 * worker 写、插件读的升级状态（`auto-update-latest.json`）。
 * @typedef {object} UpgradeStatus
 * @property {'waiting' | 'running' | 'finished' | 'failed' | 'timeout'} status
 * @property {'update' | 'rollback'} [mode]
 * @property {string} [taskName]
 * @property {string} [jobFile]
 * @property {string} [logPath]
 * @property {string} [message]
 * @property {string} [backupDir]
 * @property {string} [dshBefore]
 * @property {string} [dshAfter]
 * @property {number | null} [exitCode]
 * @property {string} [createdAt]
 * @property {string} [startedAt]
 * @property {string} [updatedAt]
 */

/**
 * 插件写给 worker 的 job 描述（`auto-update-<stamp>.job.json`）。
 * @typedef {object} Job
 * @property {string} taskName 计划任务名
 * @property {string} jobFile 本文件自身路径
 * @property {string} logPath 升级日志
 * @property {string} statusPath 升级状态文件
 * @property {string} dshHome
 * @property {string} workerScript
 * @property {string} updaterScript
 * @property {string[]} updaterArgs
 * @property {'update' | 'rollback'} mode
 * @property {number} pid 发起升级的 dsh 进程
 * @property {string} [dshBefore]
 * @property {number} [waitTimeoutMinutes]
 * @property {number} [keepBackups]
 * @property {{ enabled: boolean, command: string, args: string[], cwd: string }} [relaunch]
 */

/**
 * 支持的范围。
 * @typedef {'All' | 'Core' | 'Plugins'} UpdateScope
 */

/**
 * schema 的 volatile 字段：运行期不是原始值，而是带 `get()` 的包装。
 * @template T
 * @typedef {{ get(): T }} VolatileValue
 */

/**
 * 插件配置。volatile 字段是 `VolatileValue`（schema 不可用时退回原始值）。
 * @typedef {object} PluginConfig
 * @property {boolean | VolatileValue<boolean>} [autoCheck]
 * @property {number | VolatileValue<number>} [intervalHours]
 * @property {boolean | VolatileValue<boolean>} [autoQuit]
 * @property {number | VolatileValue<number>} [quitDelaySeconds]
 * @property {UpdateScope | VolatileValue<UpdateScope>} [scope]
 * @property {string[] | VolatileValue<string[]>} [profiles]
 * @property {boolean | VolatileValue<boolean>} [autoRelaunch]
 * @property {string[] | VolatileValue<string[]>} [relaunchArgs]
 * @property {string | VolatileValue<string>} [updaterRoot]
 * @property {number | VolatileValue<number>} [waitTimeoutMinutes]
 * @property {number | VolatileValue<number>} [keepBackups]
 */

/**
 * `/update` 命令的返回值。
 * @typedef {object} CommandResult
 * @property {'success' | 'error'} kind
 * @property {string} text
 */

/**
 * 命令被调用时的入参。
 * @typedef {object} CommandInvocation
 * @property {string} [rawInput]
 */

/**
 * `commands.register()` 的入参。
 * @typedef {object} CommandSpec
 * @property {string} name
 * @property {string} description
 * @property {{ hint?: string }} [input]
 * @property {(invocation: CommandInvocation) => Promise<CommandResult> | CommandResult} handler
 */

/**
 * `ctx.get('commands')` 拿到的服务。
 * @typedef {object} CommandsService
 * @property {(spec: CommandSpec) => void} register
 */

/**
 * 本插件实际用到的 Cordis 上下文能力（不引入 cordis 依赖）。
 * @typedef {object} PluginContext
 * @property {(name: string) => any} get 取服务：commands / profileContext / appExit
 * @property {(callback: () => void, ms: number) => void} timeout
 * @property {(callback: () => void | Promise<void>, ms: number) => void} interval
 * @property {(event: string, callback: () => void) => void} on
 */

export {}
