/**
 * dsh-updater worker —— 在 dsh 进程之外运行（由 Windows 计划任务拉起）。
 *
 * 流程：写 waiting 状态 → 注销自己的计划任务 → 等 dsh 进程消失 → 跑
 * Update-Dsh.ps1 → 写 finished/failed → 按需重启 dsh。
 *
 * 为什么必须走计划任务：dsh 在 Windows 上用 kill-on-close 的 Job Object 管子进程，
 * 任何挂在 dsh 进程树下的后台进程都会随 dsh 退出被杀掉。
 *
 * 控制台只输出 ASCII 进度（中文在 GBK 控制台窗口里必然乱码）；完整的中文输出只进日志文件。
 */
import { spawn } from 'node:child_process'
import { appendFileSync } from 'node:fs'
import { mkdir, readdir, readFile, rm } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import { readJson, writeJsonAtomic } from './checker.js'
import { PWSH_ARGUMENTS, buildPwshCommand, decodeOutput } from './output.js'

const POLL_MS = 2_000
const BACKUP_DIR = /^\d{8}-\d{6}$/

function argValue(name) {
  const argv = process.argv.slice(2)
  const index = argv.indexOf(name)
  return index >= 0 ? argv[index + 1] : undefined
}

const jobFile = argValue('--job')
if (!jobFile) {
  process.stderr.write('worker: missing --job <job.json>\n')
  process.exit(2)
}

const job = JSON.parse(await readFile(jobFile, 'utf8'))
const startedAt = new Date().toISOString()
const logPath = job.logPath
let status = {
  status: 'waiting',
  mode: job.mode ?? 'update',
  taskName: job.taskName,
  jobFile,
  logPath,
  dshBefore: job.dshBefore,
  dshAfter: '',
  exitCode: null,
  backupDir: '',
  message: '等待所有 DSH 进程退出',
  createdAt: startedAt,
  startedAt,
  updatedAt: startedAt,
}

await mkdir(dirname(logPath), { recursive: true }).catch(() => {})

/** 追加到日志文件（UTF-8，可含中文）。 */
function log(message) {
  try {
    appendFileSync(logPath, `[${new Date().toISOString()}] ${message}\n`, 'utf8')
  } catch {
    // 日志写不进去也不能影响升级本身。
  }
}

/** 同时写到控制台；只能是 ASCII，否则 GBK 控制台窗口里会变乱码。 */
function progress(message) {
  log(message)
  try {
    process.stdout.write(`[dsh-updater] ${message}\n`)
  } catch {}
}

/** 原子写状态文件，供 /update status 与设置页读取。 */
async function writeStatus(patch) {
  status = { ...status, ...patch, updatedAt: new Date().toISOString() }
  await writeJsonAtomic(job.statusPath, status).catch(error => log(`写状态失败：${String(error)}`))
}

/** 注销自身计划任务；worker 已经在跑，任务留着只会变成残留。 */
async function deleteSelfTask() {
  if (!job.taskName) return
  try {
    await exec('schtasks.exe', ['/Delete', '/TN', job.taskName, '/F'])
    log(`已删除计划任务 ${job.taskName}（worker 已独立运行）`)
  } catch (error) {
    log(`删除计划任务失败（可忽略）：${String(error?.message ?? error)}`)
  }
}

/** 执行一个子进程并等待结束。 */
function exec(file, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(file, args, { windowsHide: true, ...options })
    child.on('error', reject)
    child.on('close', code => resolve(code ?? 0))
  })
}

/** 执行一个子进程并收集 stdout。 */
function capture(file, args) {
  return new Promise(resolve => {
    const child = spawn(file, args, { windowsHide: true, stdio: ['ignore', 'pipe', 'ignore'] })
    let out = ''
    child.stdout.on('data', chunk => { out += decodeOutput(chunk, { stream: true }) })
    child.on('error', () => resolve(''))
    child.on('close', () => resolve(out))
  })
}

/**
 * 探测实际会被调用的 pwsh 路径与版本。
 *
 * 不用 `where.exe`：它按控制台代码页输出，路径里的中文会变成乱码。
 * 直接让 pwsh 自己报告（并把输出固定成 UTF-8），拿到的是真实进程路径。
 */
async function detectPwsh() {
  const command = '[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false); '
    + '[Environment]::ProcessPath + "|" + $PSVersionTable.PSVersion.ToString()'
  const out = (await capture('pwsh', [...PWSH_ARGUMENTS, command])).trim()
  const [path, version] = out.split('|')
  return { path: path?.trim() || 'pwsh', version: version?.trim() || '' }
}

/** 运行升级引擎：输出只进日志，不进控制台。 */
function runUpdater() {
  const command = buildPwshCommand(job.updaterScript, job.updaterArgs ?? [])
  log(`开始执行：pwsh ${PWSH_ARGUMENTS.join(' ')} "${command}"`)
  return new Promise(resolve => {
    const child = spawn('pwsh', [...PWSH_ARGUMENTS, command], {
      cwd: job.dshHome || undefined,
      windowsHide: true,
      stdio: ['ignore', 'pipe', 'pipe'],
    })
    const pipe = chunk => {
      try {
        appendFileSync(logPath, decodeOutput(chunk, { stream: true }), 'utf8')
      } catch {}
    }
    child.stdout.on('data', pipe)
    child.stderr.on('data', pipe)
    child.on('error', error => {
      log(`启动升级引擎失败：${String(error?.message ?? error)}`)
      resolve(127)
    })
    child.on('close', code => resolve(code ?? 1))
  })
}

/** 进程是否仍存活（EPERM 表示存在但无权限探测）。 */
function isAlive(pid) {
  try {
    process.kill(pid, 0)
    return true
  } catch (error) {
    return error?.code === 'EPERM'
  }
}

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms))

/** 等 dsh 进程退出；超时返回 false。 */
async function waitForExit(pid, timeoutMs) {
  const deadline = Date.now() + timeoutMs
  let last = 0
  while (Date.now() < deadline) {
    if (!isAlive(pid)) return true
    if (Date.now() - last > 60_000) {
      last = Date.now()
      progress(`waiting for DSH (pid ${pid}) to exit...`)
    }
    await sleep(POLL_MS)
  }
  return false
}

/** 升级后 dsh 版本。 */
async function dshVersion() {
  const out = await capture('cmd.exe', ['/c', 'dsh', '--version'])
  return out.trim().split(/\r?\n/).pop() ?? ''
}

/** 最近一次备份目录（引擎生成的 YYYYMMDD-HHmmss 目录）。 */
async function newestBackup(sinceMs) {
  const root = join(job.dshHome ?? '', '.dsh-update-backups')
  try {
    const entries = await readdir(root, { withFileTypes: true })
    const candidates = entries
      .filter(entry => entry.isDirectory() && BACKUP_DIR.test(entry.name))
      .map(entry => entry.name)
      .sort()
    const newest = candidates.at(-1)
    if (!newest) return ''
    const stamp = newest.replace(/^(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})$/, '$1-$2-$3T$4:$5:$6')
    const time = Date.parse(stamp)
    return Number.isFinite(time) && time >= sinceMs ? join(root, newest) : ''
  } catch {
    return ''
  }
}

/** 只保留最近 N 个备份目录（目录名必须是时间戳且位于备份根下）。 */
async function pruneBackups(keep) {
  if (!Number.isFinite(keep) || keep <= 0) return
  const root = join(job.dshHome ?? '', '.dsh-update-backups')
  try {
    const entries = await readdir(root, { withFileTypes: true }).catch(() => [])
    const dirs = entries
      .filter(entry => entry.isDirectory() && BACKUP_DIR.test(entry.name))
      .map(entry => entry.name)
      .sort()
    for (const name of dirs.slice(0, Math.max(0, dirs.length - keep))) {
      await rm(join(root, name), { recursive: true, force: true })
      log(`已清理旧备份 ${name}`)
    }
  } catch (error) {
    log(`清理旧备份失败（可忽略）：${String(error?.message ?? error)}`)
  }
}

/** 重启 dsh；失败只记日志，不影响状态落盘。 */
async function relaunch() {
  const spec = job.relaunch
  if (!spec?.enabled) {
    log('未启用自动重启（autoRelaunch 关闭或 apply 时用了 --no-quit），跳过重启 dsh')
    return { relaunched: false }
  }
  const args = ['/c', 'start', '', spec.command, ...(spec.args ?? [])]
  progress(`relaunching: ${spec.command} ${(spec.args ?? []).join(' ')}`)
  try {
    const child = spawn('cmd.exe', args, { cwd: spec.cwd || undefined, detached: true, stdio: 'ignore', windowsHide: false })
    child.on('error', error => log(`重启失败：${String(error?.message ?? error)}`))
    child.unref()
    return { relaunched: true }
  } catch (error) {
    log(`重启失败：${String(error?.message ?? error)}`)
    return { relaunched: false, relaunchError: String(error?.message ?? error) }
  }
}

// ---------------------------------------------------------------------------
// 主流程
// ---------------------------------------------------------------------------
progress(`worker started (mode=${status.mode})`)
log(`worker 启动：mode=${status.mode} job=${jobFile}`)
const pwsh = await detectPwsh()
log(`PowerShell：${pwsh.path}${pwsh.version ? `（${pwsh.version}）` : '（版本未知）'}`)
progress(`pwsh: ${pwsh.version || 'unknown'} (${pwsh.path})`)
await writeStatus({ status: 'waiting', message: '等待所有 DSH 进程退出' })
await deleteSelfTask()

const timeoutMs = Math.max(1, Number(job.waitTimeoutMinutes ?? 120)) * 60_000
progress(`waiting for DSH (pid ${job.pid}) to exit, up to ${Math.round(timeoutMs / 60_000)} min`)
const exited = await waitForExit(Number(job.pid), timeoutMs)

if (!exited) {
  log(`等待 ${Math.round(timeoutMs / 60_000)} 分钟后 DSH 仍在运行，放弃本次升级`)
  progress('timeout: DSH still running, giving up')
  await writeStatus({ status: 'timeout', message: '等待 DSH 退出超时，未执行升级' })
  process.exit(3)
}

progress('DSH exited; running update engine...')
log('DSH 已退出，开始升级')
await writeStatus({ status: 'running', message: '正在执行更新' })
const startedMs = Date.now()
const exitCode = await runUpdater()
const after = await dshVersion()
const backupDir = await newestBackup(startedMs)
const succeeded = exitCode === 0

await writeStatus({
  status: succeeded ? 'finished' : 'failed',
  exitCode,
  dshAfter: after,
  backupDir,
  message: succeeded ? '升级完成' : `升级失败（exit ${exitCode}），详见日志`,
})
log(succeeded ? `升级完成：dsh ${job.dshBefore ?? '?'} → ${after || '?'}` : `升级失败：exit ${exitCode}`)
progress(`engine exit=${exitCode} (dsh ${job.dshBefore || '?'} -> ${after || '?'})`)
progress(`log: ${logPath}`)

if (succeeded && status.mode === 'update') await pruneBackups(Number(job.keepBackups ?? 5))

const relaunchResult = await relaunch()
if (relaunchResult.relaunched) {
  await writeStatus({ message: `${status.message}；已重新启动 dsh` })
}

process.exit(succeeded ? 0 : 1)
