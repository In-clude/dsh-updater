/**
 * 轻量检查：已安装版本 vs registry 的 `dist-tags.latest`。
 *
 * 只回答「有没有新东西」，不判断兼容性——兼容性与权威计划由
 * `Update-Dsh.ps1 -DryRun` 负责（v1 的 /update apply 会跑它）。
 * 本模块不依赖 dsh 内部包，可单独用 node 运行测试。
 */
import { execFile } from 'node:child_process'
import { mkdir, readFile, rename, writeFile } from 'node:fs/promises'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'
import { promisify } from 'node:util'

const execFileAsync = promisify(execFile)
const WINDOWS = process.platform === 'win32'

/**
 * 运行 npm 子命令。
 *
 * Windows 上 npm 是 .cmd，Node 24 不允许直接 execFile 一个 .cmd 且 `shell: true`
 * 会对参数做拼接（DEP0190）。这里显式用 `cmd.exe /d /s /c`，参数原样传入、不经 shell 解析。
 * @param {string[]} args npm 参数
 */
async function runNpm(args) {
  const options = { timeout: FETCH_TIMEOUT_MS, windowsHide: true }
  if (WINDOWS) return execFileAsync('cmd.exe', ['/d', '/s', '/c', 'npm', ...args], options)
  return execFileAsync('npm', args, options)
}

/** dsh 本体包名。 */
export const CORE_PACKAGE = '@deepseek-ai/dsh'

/** 轻量检查结果的有效期（超过则 /update 重新检查）。 */
export const CHECK_CACHE_MS = 10 * 60_000

/** registry 请求超时。 */
const FETCH_TIMEOUT_MS = 15_000

/** 读 JSON 文件，容忍 BOM、缺失与损坏内容；失败返回 undefined。 */
export async function readJson(file) {
  try {
    const text = (await readFile(file, 'utf8')).replace(/^\uFEFF/, '')
    return JSON.parse(text)
  } catch {
    return undefined
  }
}

/** 原子写 JSON：先写临时文件再 rename，避免读到半个文件。 */
export async function writeJsonAtomic(file, value) {
  await mkdir(dirname(file), { recursive: true })
  const temporary = `${file}.${process.pid}.tmp`
  await writeFile(temporary, `${JSON.stringify(value, undefined, 2)}\n`, 'utf8')
  await rename(temporary, file)
}

/** 解析 dsh home（与引擎保持同一套规则）。 */
export function resolveDshHome(env = process.env) {
  const configured = env.DSH_HOME?.trim()
  return configured ? configured : join(homedir(), '.dsh')
}

/** 轻量检查状态文件的绝对路径。 */
export function checkStateFile(home) {
  return join(home, '.dsh-update-backups', 'latest-check.json')
}

/** 读取上次检查结果；不存在或损坏时返回 undefined。 */
export async function readCheckState(home) {
  return readJson(checkStateFile(home))
}

/** 判断状态是否仍然新鲜（无错误且未过期）。 */
export function isFresh(state, now = Date.now()) {
  if (!state || state.error) return false
  const checkedAt = Date.parse(state.checkedAt ?? '')
  if (!Number.isFinite(checkedAt)) return false
  return now - checkedAt < CHECK_CACHE_MS
}

let registryPromise

/** 读取 npm registry（进程内缓存一次）。 */
export function resolveRegistry() {
  registryPromise ??= (async () => {
    try {
      const { stdout } = await runNpm(['config', 'get', 'registry'])
      const value = stdout.trim()
      if (/^https?:\/\//i.test(value)) return value.replace(/\/+$/, '')
    } catch {
      // 落到默认源；私有源由 npm view 回退处理。
    }
    return 'https://registry.npmjs.org'
  })()
  return registryPromise
}

/** scoped 包名需要把斜杠编码，才能拼进 registry 路径。 */
function encodePackageName(name) {
  return name.startsWith('@') ? name.replace('/', '%2f') : name
}

/** 直接读 registry 的 abbreviated packument，取 dist-tags.latest。 */
export async function fetchLatest(name, registry) {
  const url = `${registry.replace(/\/+$/, '')}/${encodePackageName(name)}`
  const response = await fetch(url, {
    headers: { Accept: 'application/vnd.npm.install-v1+json' },
    signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
  })
  if (!response.ok) throw new Error(`registry HTTP ${response.status}`)
  const document = await response.json()
  const latest = document?.['dist-tags']?.latest
  if (typeof latest !== 'string' || latest === '') throw new Error('registry 未返回 dist-tags.latest')
  return latest
}

/** 回退路径：交给 npm 自己处理配置与凭据。 */
export async function npmViewLatest(name) {
  const { stdout } = await runNpm(['view', name, 'version', '--no-color'])
  const lines = stdout.trim().split(/\r?\n/).filter(Boolean)
  const version = lines.at(-1)
  if (!version || !/^\d+\.\d+\.\d+/.test(version)) throw new Error('npm view 未返回版本号')
  return version
}

/** 先 registry，再 npm view；两条都失败返回 undefined。 */
async function latestOf(name, registry) {
  try {
    return await fetchLatest(name, registry)
  } catch {
    try {
      return await npmViewLatest(name)
    } catch {
      return undefined
    }
  }
}

/** 本地来源的依赖（link:/file:/workspace:/git+）不在 registry 上，检查时跳过。 */
const LOCAL_SPEC = /^(link:|file:|workspace:|git\+|github:|portal:)/

/**
 * 读取已安装版本：本体取安装锚点 package.json，插件取 profile 的 node_modules。
 * dependencies 里的 `^1.84.2` 是范围不是实际版本，只作为读不到 node_modules 时的兜底。
 */
export async function readInstalled(profileContext) {
  const anchor = await readJson(profileContext.installAnchor)
  const profilePackage = await readJson(join(profileContext.dir, 'package.json'))
  const declared = profilePackage?.dependencies ?? {}
  const plugins = []
  for (const name of Object.keys(declared)) {
    const spec = String(declared[name] ?? '')
    if (LOCAL_SPEC.test(spec) || name.startsWith('@local/')) continue
    const installed = await readJson(join(profileContext.dir, 'node_modules', ...name.split('/'), 'package.json'))
    const fallback = spec.replace(/^[\^~>=<\s]+/, '')
    plugins.push({ pkg: name, current: installed?.version ?? (fallback || undefined) })
  }
  return {
    core: { current: anchor?.version },
    profile: { name: profileContext.name, plugins },
  }
}

/**
 * 跑一次轻量检查。
 * @returns 写入状态文件的对象：{ schemaVersion, checkedAt, core, profiles, updateAvailable, error }
 */
export async function runCheck({ profileContext, registry, now = Date.now() }) {
  const installed = await readInstalled(profileContext)
  const source = registry ?? (await resolveRegistry())
  const coreLatest = await latestOf(CORE_PACKAGE, source)
  const pluginResults = await Promise.all(installed.profile.plugins.map(async item => ({
    pkg: item.pkg,
    current: item.current,
    latest: await latestOf(item.pkg, source),
  })))

  const all = [
    { pkg: CORE_PACKAGE, current: installed.core.current, latest: coreLatest },
    ...pluginResults,
  ]
  const failed = all.filter(item => item.latest === undefined)
  const updates = all.filter(item => item.latest !== undefined && item.latest !== item.current)

  return {
    schemaVersion: 1,
    checkedAt: new Date(now).toISOString(),
    registry: source,
    core: { current: installed.core.current, latest: coreLatest },
    profiles: { [installed.profile.name]: pluginResults },
    updateAvailable: updates.length > 0,
    error: failed.length === all.length && all.length > 0
      ? '所有版本查询都失败（registry 不可达或需要认证）'
      : null,
  }
}
