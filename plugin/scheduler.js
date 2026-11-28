/**
 * 用 Windows 计划任务托管 worker。
 *
 * dsh 退出时会把进程树一起杀掉（Job Object），所以 worker 不能是 dsh 的子进程；
 * 计划任务由 Task Scheduler 服务拉起，与 dsh 无关。
 *
 * 注意：不要把启动命令写进 .cmd 文件——cmd.exe 按控制台代码页（简体中文 = GBK）读脚本，
 * 而 DSH_HOME 常含中文用户名，UTF-8 写入的路径会变成乱码、任务静默失败。
 * `/TR` 走 Windows 命令行（UTF-16），不存在这个问题。
 */
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'

const execFileAsync = promisify(execFile)

/** schtasks 的参数超过这个值就可能被拒。 */
const SCHTASKS_TIMEOUT_MS = 60_000

/** v1 只支持 Windows：计划任务是本机唯一的“逃出进程树”的办法。 */
export function assertSupportedPlatform() {
  if (process.platform !== 'win32') {
    throw new Error('当前平台不支持自动升级：worker 需要 Windows 计划任务托管（Linux 请直接运行 update-dsh.sh）')
  }
}

/**
 * 调用 schtasks。
 * @param {string[]} args
 * @returns {Promise<string>}
 */
async function schtasks(args) {
  const { stdout, stderr } = await execFileAsync('schtasks.exe', args, {
    timeout: SCHTASKS_TIMEOUT_MS,
    windowsHide: true,
  })
  return `${stdout ?? ''}${stderr ?? ''}`
}

/**
 * 拼出计划任务要执行的命令行（各段都带引号，路径含空格也安全）。
 * @param {{ nodeExe: string, workerScript: string, jobFile: string }} options
 * @returns {string}
 */
export function buildCommandLine({ nodeExe, workerScript, jobFile }) {
  return [`"${nodeExe}"`, `"${workerScript}"`, '--job', `"${jobFile}"`].join(' ')
}

/**
 * 注册并立即启动计划任务。
 * @param {{ taskName: string, commandLine: string }} options
 * @returns {Promise<void>}
 */
export async function startTask({ taskName, commandLine }) {
  // 触发时间只是占位：任务由 /Run 立即执行，worker 启动后自己注销。
  const time = new Date(Date.now() + 5 * 60_000)
  const stamp = `${String(time.getHours()).padStart(2, '0')}:${String(time.getMinutes()).padStart(2, '0')}`
  await schtasks(['/Create', '/TN', taskName, '/TR', commandLine, '/SC', 'ONCE', '/ST', stamp, '/F'])
  await schtasks(['/Run', '/TN', taskName])
}

/**
 * 删除计划任务（不存在时静默）。
 * @param {string} taskName
 * @returns {Promise<void>}
 */
export async function deleteTask(taskName) {
  try {
    await schtasks(['/Delete', '/TN', taskName, '/F'])
  } catch {
    // 任务可能已经被 worker 自己注销。
  }
}

/**
 * 查询任务是否存在。
 * @param {string} taskName
 * @returns {Promise<boolean>}
 */
export async function taskExists(taskName) {
  try {
    await schtasks(['/Query', '/TN', taskName, '/FO', 'LIST'])
    return true
  } catch {
    return false
  }
}

/**
 * 任务最近一次运行结果（排障用）。
 * @param {string} taskName
 * @returns {Promise<string>}
 */
export async function taskLastResult(taskName) {
  try {
    const text = await schtasks(['/Query', '/TN', taskName, '/V', '/FO', 'LIST'])
    const line = text.split(/\r?\n/).find(entry => /Last Result|上次运行结果/i.test(entry))
    return line?.trim() ?? ''
  } catch (/** @type {any} */ error) {
    return String(error?.message ?? error)
  }
}
