/**
 * dsh-updater：dsh 更新检查与执行（v1 + v1.5）。
 *
 * 进程内部分：定时检查、/update 命令、把升级排给进程外的 worker、请求优雅退出。
 * 进程外部分：worker.js（由 Windows 计划任务拉起）——等 dsh 退出、跑 Update-Dsh.ps1、重启 dsh。
 */
import { execFile } from 'node:child_process'
import { existsSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { promisify } from 'node:util'
import {
  CHECK_CACHE_MS,
  checkStateFile,
  isFresh,
  readCheckState,
  readJson,
  resolveDshHome,
  runCheck,
  writeJsonAtomic,
} from './checker.js'
import { assertSupportedPlatform, buildCommandLine, deleteTask, startTask } from './scheduler.js'
import { decodeOutput, PWSH_ARGUMENTS, buildPwshCommand } from './output.js'

const execFileAsync = promisify(execFile)
const PLUGIN_DIR = dirname(fileURLToPath(import.meta.url))

/** 备份与日志根目录（相对 DSH_HOME）。 */
const BACKUP_ROOT = '.dsh-update-backups'
/** 完整预览最多跑多久。 */
const PREVIEW_TIMEOUT_MS = 10 * 60_000
/** 注册计划任务后等 worker 写出 waiting 状态的上限。 */
const START_CONFIRM_MS = 30_000
/** 启动后多久做第一次检查。 */
const FIRST_DELAY_MS = 20_000
/** 调度 tick。 */
const TICK_MS = 60_000
/** 失败退避上限。 */
const MAX_BACKOFF_MS = 12 * 3600_000

let z
try {
  ({ default: z } = await import('@deepseek-ai/schemastery'))
} catch {
  // 拿不到 schema 库时降级：没有表单，配置项用行里的原始值。
  z = undefined
}

export const inject = ['timer']

export const Config = z
  ? z.object({
    autoCheck: z.boolean().default(true).volatile(),
    intervalHours: z.number().min(1).max(168).default(6).step(1).volatile(),
    autoQuit: z.boolean().default(true).volatile(),
    quitDelaySeconds: z.number().min(0).max(60).default(5).step(1).volatile(),
    scope: z.enum(['All', 'Core', 'Plugins']).default('All').volatile(),
    profiles: z.array(z.string()).default([]).volatile(),
    autoRelaunch: z.boolean().default(true).volatile(),
    relaunchArgs: z.array(z.string()).default([]).volatile(),
    updaterRoot: z.string().default('').volatile(),
    waitTimeoutMinutes: z.number().min(5).max(720).default(120).step(5).volatile(),
    keepBackups: z.number().min(1).max(30).default(5).step(1).volatile(),
  })
  : undefined

/** 读取配置值：volatile 字段是 `.get()` 包装，schema 不可用时是原始值。 */
function read(value, fallback) {
  if (value === undefined) return fallback
  if (typeof value?.get === 'function') return value.get()
  return value
}

/** 渲染 `YYYY-MM-DD HH:mm`（本地时区）。 */
function formatTime(iso) {
  const date = new Date(iso ?? '')
  if (Number.isNaN(date.getTime())) return '未知时间'
  const pad = (n) => String(n).padStart(2, '0')
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}`
}

/** 时间戳目录名：YYYYMMDD-HHmmss。 */
function stamp(date = new Date()) {
  const pad = (n) => String(n).padStart(2, '0')
  return `${date.getFullYear()}${pad(date.getMonth() + 1)}${pad(date.getDate())}-${pad(date.getHours())}${pad(date.getMinutes())}${pad(date.getSeconds())}`
}

function isOutdated(item) {
  return Boolean(item?.latest && item.latest !== item.current)
}

/** 把检查结果渲染成文本。 */
function renderPlan(state) {
  if (!state) return '还没有检查结果。'
  if (state.error) return `检查失败：${state.error}\n稍后会自动重试（已按失败次数退避）。`

  const lines = [`dsh 更新检查 · ${formatTime(state.checkedAt)}`]
  const core = state.core ?? {}
  lines.push(isOutdated(core)
    ? `  本体 ${core.current ?? '未知'} → ${core.latest}`
    : `  本体 ${core.current ?? '未知'}（已是最新）`)

  let pluginCount = 0
  let outdated = 0
  for (const [profile, items] of Object.entries(state.profiles ?? {})) {
    for (const item of items ?? []) {
      pluginCount += 1
      if (isOutdated(item)) {
        outdated += 1
        lines.push(`  ${profile} / ${item.pkg} ${item.current ?? '未知'} → ${item.latest}`)
      }
    }
  }

  if (!isOutdated(core) && outdated === 0) {
    lines.push('', `所有内容都已是最新（插件 ${pluginCount} 个）。`)
  } else {
    lines.push('', `另有 ${pluginCount - outdated} 个插件已是最新。`)
    lines.push('执行升级：/update apply（会先关闭 dsh，升级后自动重启）；想自己控制开关 dsh 用 /update apply --no-quit。')
  }
  lines.push(`结果缓存 ${Math.round(CHECK_CACHE_MS / 60_000)} 分钟；/update --refresh 强制刷新。`)
  return lines.join('\n')
}

/** 找升级引擎：配置 > 包内 scripts > 仓库根（本插件与引擎同仓时）。 */
function resolveUpdaterScript(config) {
  const configured = String(read(config?.updaterRoot, '') ?? '').trim()
  if (configured) {
    const candidate = configured.endsWith('.ps1') ? configured : join(configured, 'Update-Dsh.ps1')
    return existsSync(candidate) ? candidate : undefined
  }
  const bundled = join(PLUGIN_DIR, 'scripts', 'Update-Dsh.ps1')
  if (existsSync(bundled)) return bundled
  const sibling = join(PLUGIN_DIR, '..', 'Update-Dsh.ps1')
  return existsSync(sibling) ? sibling : undefined
}

/** 从引擎 dry-run 输出里截出「更新计划」段。 */
function extractPlan(output) {
  const lines = String(output ?? '').split(/\r?\n/)
  const start = lines.findIndex(line => line.includes('== 更新计划'))
  if (start < 0) return ''
  const plan = []
  for (const line of lines.slice(start + 1)) {
    if (line.trim().startsWith('==')) break
    if (line.trim() === '') continue
    plan.push(line.replace(/\s+$/, ''))
  }
  return plan.join('\n')
}

export function apply(ctx, config) {
  const home = resolveDshHome()
  const backupRoot = join(home, BACKUP_ROOT)
  const stateFile = checkStateFile(home)
  const upgradeStatusFile = join(backupRoot, 'logs', 'auto-update-latest.json')
  const logsDir = join(backupRoot, 'logs')
  const commands = ctx.get('commands')

  let state
  let nextAt = Date.now() + FIRST_DELAY_MS
  let running = false
  let failures = 0

  const autoCheckEnabled = () => read(config?.autoCheck, true)
  const intervalMs = () => Math.max(1, Number(read(config?.intervalHours, 6)) || 6) * 3600_000

  async function hydrate() {
    if (state !== undefined) return state
    state = await readCheckState(home)
    return state
  }

  /** 轻量检查；`force` 忽略缓存。 */
  async function check({ force = false } = {}) {
    if (running) return state
    await hydrate()
    if (!force && isFresh(state)) return state

    running = true
    try {
      const profileContext = ctx.get('profileContext')
      if (!profileContext?.dir || !profileContext?.installAnchor) {
        throw new Error('当前会话没有 profile 上下文，无法读取已安装版本')
      }
      state = await runCheck({ profileContext })
      failures = 0
      nextAt = Date.now() + intervalMs()
      await writeJsonAtomic(stateFile, { ...state, failures, nextCheckAt: new Date(nextAt).toISOString() })
      return state
    } catch (error) {
      failures += 1
      nextAt = Date.now() + Math.min(3600_000 * 2 ** failures, MAX_BACKOFF_MS)
      state = {
        ...(state ?? {}),
        schemaVersion: 1,
        checkedAt: state?.checkedAt ?? new Date().toISOString(),
        error: String(error?.message ?? error),
        failures,
        nextCheckAt: new Date(nextAt).toISOString(),
      }
      await writeJsonAtomic(stateFile, state).catch(() => {})
      return state
    } finally {
      running = false
    }
  }

  /** 跑完整预览（权威计划，含兼容性判断）。只读。 */
  async function runPreview(engine, scope) {
    const scriptArgs = ['-DryRun', '-Yes', '-Scope', scope]
    const profiles = read(config?.profiles, []) ?? []
    if (profiles.length > 0) scriptArgs.push('-Profile', profiles.join(','))
    const command = buildPwshCommand(engine, scriptArgs)
    try {
      const { stdout, stderr } = await execFileAsync('pwsh', [...PWSH_ARGUMENTS, command], {
        timeout: PREVIEW_TIMEOUT_MS,
        windowsHide: true,
        maxBuffer: 8 * 1024 * 1024,
        encoding: 'buffer',
      })
      const output = `${decodeOutput(stdout ?? Buffer.alloc(0))}\n${decodeOutput(stderr ?? Buffer.alloc(0))}`
      return { ok: true, output, hasUpdates: /\[PLAN\]/.test(output) }
    } catch (error) {
      const raw = Buffer.concat([error?.stdout ?? Buffer.alloc(0), error?.stderr ?? Buffer.alloc(0)])
      return {
        ok: false,
        output: raw.length > 0 ? decodeOutput(raw) : '',
        hasUpdates: false,
        error: String(error?.message ?? error),
      }
    }
  }

  /** 组装 worker 的 job 描述；`relaunch` 为 false 时 worker 升级完不会重启 dsh。 */
  async function createJob({ engine, rollback, rollbackId, relaunch }) {
    const when = stamp()
    const taskName = `DSH-AutoUpdate-${when}`
    const jobFile = join(logsDir, `auto-update-${when}.job.json`)
    const scope = read(config?.scope, 'All')
    const profiles = read(config?.profiles, []) ?? []
    const profileContext = ctx.get('profileContext')
    const updaterArgs = rollback
      ? ['-Rollback', '-Yes', ...(rollbackId ? ['-RollbackId', rollbackId] : [])]
      : ['-Scope', scope, '-Yes', ...(profiles.length > 0 ? ['-Profile', profiles.join(',')] : [])]

    const job = {
      taskName,
      jobFile,
      logPath: join(logsDir, `auto-update-${when}.log`),
      statusPath: upgradeStatusFile,
      dshHome: home,
      workerScript: join(PLUGIN_DIR, 'worker.js'),
      updaterScript: engine,
      updaterArgs,
      mode: rollback ? 'rollback' : 'update',
      pid: process.pid,
      dshBefore: state?.core?.current ?? '',
      waitTimeoutMinutes: Number(read(config?.waitTimeoutMinutes, 120)) || 120,
      keepBackups: Number(read(config?.keepBackups, 5)) || 5,
      relaunch: {
        enabled: Boolean(relaunch),
        command: 'dsh',
        args: [profileContext?.name ?? 'web', ...(read(config?.relaunchArgs, []) ?? [])],
        cwd: process.cwd(),
      },
    }
    await writeJsonAtomic(jobFile, job)
    return job
  }

  /** 等 worker 写出 waiting 状态。 */
  async function waitForWorker(job) {
    const deadline = Date.now() + START_CONFIRM_MS
    while (Date.now() < deadline) {
      const current = await readJson(upgradeStatusFile)
      if (current?.jobFile === job.jobFile && current?.status === 'waiting') return true
      await new Promise(resolve => setTimeout(resolve, 500))
    }
    return false
  }

  /** 排一次升级（update 或 rollback），并请求 dsh 优雅退出。 */
  async function enqueue({ rollback, rollbackId, quit }) {
    assertSupportedPlatform()

    const existing = await readJson(upgradeStatusFile)
    if (existing?.status === 'waiting' || existing?.status === 'running') {
      return {
        kind: 'error',
        text: `已有进行中的升级（${existing.status}，任务 ${existing.taskName ?? '未知'}）。\n请等它结束，或用 /update status 查看进度。`,
      }
    }

    const engine = resolveUpdaterScript(config)
    if (!engine) {
      return {
        kind: 'error',
        text: '找不到 Update-Dsh.ps1。请设置 updaterRoot，或把引擎放到本包 scripts/ 目录（与本插件同仓时直接用仓库根的 Update-Dsh.ps1）。',
      }
    }

    let plan = ''
    if (!rollback) {
      const preview = await runPreview(engine, read(config?.scope, 'All'))
      if (!preview.ok) {
        return { kind: 'error', text: `预览失败，未执行升级：\n${preview.error}` }
      }
      if (!preview.hasUpdates) {
        return { kind: 'success', text: `没有可更新的内容。\n\n${extractPlan(preview.output) || '（引擎未给出计划）'}` }
      }
      plan = extractPlan(preview.output)
    }

    const autoQuit = quit !== false && Boolean(read(config?.autoQuit, true))
    const autoRelaunch = quit !== false && Boolean(read(config?.autoRelaunch, true))
    const delay = Math.max(0, Number(read(config?.quitDelaySeconds, 5)) || 0)

    const job = await createJob({ engine, rollback, rollbackId, relaunch: autoRelaunch })
    const commandLine = buildCommandLine({
      nodeExe: process.execPath,
      workerScript: job.workerScript,
      jobFile: job.jobFile,
    })

    try {
      await startTask({ taskName: job.taskName, commandLine })
    } catch (error) {
      await deleteTask(job.taskName)
      return { kind: 'error', text: `注册计划任务失败：${String(error?.message ?? error)}` }
    }

    if (!(await waitForWorker(job))) {
      await deleteTask(job.taskName)
      return {
        kind: 'error',
        text: `计划任务已注册但 worker 没有启动（30 秒内无 waiting 状态）。\n任务名：${job.taskName}\n日志：${job.logPath}`,
      }
    }

    const appExit = ctx.get('appExit')
    if (autoQuit && appExit) ctx.timeout(() => appExit(0), delay * 1000)

    const action = rollback ? '回滚' : '升级'
    const relaunchText = autoRelaunch
      ? '完成后自动重启 dsh'
      : '完成后不会自动重启 dsh，需要时请手动启动'
    const lines = [
      `已排队${action}：${job.taskName}`,
      plan ? `\n更新计划：\n${plan}\n` : '',
      `日志：${job.logPath}`,
      autoQuit && appExit
        ? `${delay} 秒后自动退出 dsh；worker 会在进程退出后执行${action}，${relaunchText}。`
        : `请手动退出 dsh；worker 会在进程退出后执行${action}，${relaunchText}。`,
      autoRelaunch
        ? '退出后这个会话会中断，重开 dsh 即可继续。'
        : '退出后这个会话会中断；升级完成后请手动打开 dsh。',
    ]
    return { kind: 'success', text: lines.filter(Boolean).join('\n') }
  }

  /** `/update status`：合并「有无新版本」与「上次升级结果」。 */
  async function statusText() {
    const current = await hydrate()
    const upgrade = await readJson(upgradeStatusFile)
    const lines = [renderPlan(current)]
    if (current?.nextCheckAt) lines.push(`下次自动检查：${formatTime(current.nextCheckAt)}`)
    if (current?.failures) lines.push(`连续失败：${current.failures} 次`)

    if (!upgrade) {
      lines.push('', '上次升级：无记录')
    } else {
      const labels = { waiting: '等待 DSH 退出', running: '正在执行', finished: '成功', failed: '失败', timeout: '等待超时' }
      lines.push('', `上次升级：${labels[upgrade.status] ?? upgrade.status} · ${formatTime(upgrade.updatedAt)}`)
      if (upgrade.dshBefore || upgrade.dshAfter) lines.push(`  版本：${upgrade.dshBefore || '?'} → ${upgrade.dshAfter || '?'}`)
      if (upgrade.backupDir) lines.push(`  备份：${upgrade.backupDir}`)
      if (upgrade.logPath) lines.push(`  日志：${upgrade.logPath}`)
      if (upgrade.status === 'failed') lines.push('  回滚：/update rollback（只回滚插件，不降级本体）')
    }
    return { kind: 'success', text: lines.join('\n') }
  }

  ctx.interval(async () => {
    if (!autoCheckEnabled() || running || Date.now() < nextAt) return
    await check({ force: true })
  }, TICK_MS)

  ctx.timeout(() => {
    if (autoCheckEnabled()) void check({ force: true })
  }, FIRST_DELAY_MS)

  ctx.on('loader/volatile-update', () => {
    nextAt = Math.min(nextAt, Date.now() + 1_000)
  })

  if (commands) {
    commands.register({
      name: 'update',
      description: '检查并执行 dsh 更新：本体与 profile 插件，升级后自动重启',
      input: { hint: 'apply | status | rollback | --refresh' },
      handler: async (invocation) => {
        const raw = String(invocation?.rawInput ?? '').trim()
        const parts = raw.split(/\s+/).filter(Boolean)
        const sub = parts[0] ?? ''
        try {
          if (sub === 'status') return await statusText()
          if (sub === 'apply') return await enqueue({ rollback: false, quit: !parts.includes('--no-quit') })
          if (sub === 'rollback') return await enqueue({ rollback: true, rollbackId: parts[1] })
          if (sub === '' || sub === '--refresh' || sub === '-r') {
            const current = await check({ force: sub !== '' })
            return current?.error
              ? { kind: 'error', text: renderPlan(current) }
              : { kind: 'success', text: renderPlan(current) }
          }
          return { kind: 'error', text: `未知参数 ${JSON.stringify(sub)}。可用：/update、/update --refresh、/update status、/update apply、/update rollback。` }
        } catch (error) {
          return { kind: 'error', text: `执行失败：${String(error?.message ?? error)}` }
        }
      },
    })
  }
}
