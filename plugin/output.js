/**
 * 子进程输出解码 + PowerShell 调用约定。
 *
 * 背景（实测）：PowerShell 7 把中文写到被捕获的 stdout 时，编码取决于运行环境——
 * 有控制台时按控制台代码页（简体中文 = GBK/CP936）写出，由计划任务拉起（无控制台）时
 * 却按 UTF-8 写出。同一份日志因此可能同时出现两种编码的乱码。
 *
 * 结论：不猜编码，而是显式强制子进程用 UTF-8 输出，然后统一按 UTF-8 解码。
 */
const decoder = new TextDecoder('utf-8')

/**
 * 拼出 PowerShell 的单引号字符串字面量。
 * @param {unknown} value 任意参数值
 * @returns {string}
 */
function singleQuote(value) {
  return `'${String(value).replace(/'/g, "''")}'`
}

/**
 * 需要加引号的参数（含空白或引号）。
 * @param {unknown} value 任意参数值
 * @returns {string}
 */
function quoteArgument(value) {
  const text = String(value)
  return /[\s'"]/.test(text) ? singleQuote(text) : text
}

/** 通用 pwsh 选项：命令走 `-Command`，因为要先设置输出编码再调用脚本。 */
export const PWSH_ARGUMENTS = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command']

/**
 * 构造一条“先强制 UTF-8 输出，再执行脚本”的 PowerShell 命令。
 * @param {string} script 脚本绝对路径
 * @param {string[]} [args] 传给脚本的参数
 */
export function buildPwshCommand(script, args = []) {
  const preamble = '[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false); '
    + '$OutputEncoding = [Console]::OutputEncoding'
  const tail = args.map(quoteArgument).join(' ')
  return `${preamble}; & ${singleQuote(script)}${tail ? ` ${tail}` : ''}`
}

/**
 * 把子进程输出的字节解码成字符串。
 * @param {Buffer|Uint8Array} buffer 原始字节
 * @param {{ stream?: boolean }} [options] `stream: true` 用于分块解码
 */
export function decodeOutput(buffer, options) {
  return decoder.decode(buffer, options)
}
