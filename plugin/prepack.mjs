/**
 * npm 打包前把仓库根的更新引擎（Update-Dsh.ps1）复制进包内 `scripts/`。
 *
 * 插件运行时要调 `pwsh <pkg>/scripts/Update-Dsh.ps1`；从仓库安装时它取的是
 * 上一级的引擎，发布到 npm 后没有那个兄弟目录，所以打包时带一份副本。
 * 仓库里的 `plugin/scripts/` 是生成物，不提交（见 .gitignore）。
 */
import { copyFileSync, existsSync, mkdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const source = process.env.DSH_UPDATER_ENGINE || join(here, '..', 'Update-Dsh.ps1')
const target = join(here, 'scripts', 'Update-Dsh.ps1')

if (!existsSync(source)) {
  process.stderr.write(`[prepack] 找不到更新引擎：${source}\n`)
  process.stderr.write('[prepack] 请在仓库的 plugin/ 目录打包，或用 DSH_UPDATER_ENGINE 指定 Update-Dsh.ps1。\n')
  process.exit(1)
}

mkdirSync(dirname(target), { recursive: true })
copyFileSync(source, target)
process.stdout.write(`[prepack] 已复制更新引擎到 ${target}\n`)
