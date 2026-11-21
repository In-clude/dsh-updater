<#
.SYNOPSIS
    查看最近一次 dsh 自动升级/回滚的状态与结果。

.DESCRIPTION
    读取 Invoke-DshAutoUpgrade.ps1 的 worker 写下的 auto-update-latest.json，结合当前 dsh 版本、
    最近一次备份清单与日志尾部，给出「升级是否成功、要不要回滚」的结论。用户重启 DSH 后用它验证。

.EXAMPLE
    .\Get-DshUpdateStatus.ps1
    输出最近一次自动升级的状态、当前版本、备份、残留任务和日志尾部。
#>
[CmdletBinding()]
param(
    [string]$LogsDir = '',
    [int]$TailLines = 40
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { }

$dshHome = ''
if (-not [string]::IsNullOrWhiteSpace($env:DSH_HOME)) {
    $dshHome = [System.IO.Path]::GetFullPath($env:DSH_HOME)
} else {
    $dshHome = [System.IO.Path]::GetFullPath((Join-Path $HOME '.dsh'))
}
if ([string]::IsNullOrWhiteSpace($LogsDir)) {
    $LogsDir = Join-Path (Join-Path $dshHome '.dsh-update-backups') 'logs'
}
$latestPath = Join-Path $LogsDir 'auto-update-latest.json'

$labels = @{
    'starting' = 'worker 刚启动'
    'waiting'  = '等待 DSH 退出'
    'running'  = '正在执行更新'
    'finished' = '成功'
    'failed'   = '失败'
    'timeout'  = '等待 DSH 退出超时'
    'error'    = '出错'
}

$state = $null
if (Test-Path -LiteralPath $latestPath) {
    try { $state = Get-Content -LiteralPath $latestPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $state = $null }
}

$dshVersion = ''
try {
    $dshCmd = Get-Command dsh -CommandType Application, ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $dshCmd) {
        $versionText = (& ([string]$dshCmd.Source) --version 2>$null | Select-Object -First 1)
        if ([string]$versionText -match '(\d+\.\d+\.\d+(?:-[0-9A-Za-z.\-]+)?)') { $dshVersion = $Matches[1] }
    }
} catch { }

$tasks = @(Get-ScheduledTask -TaskName 'DSH-AutoUpdate-*' -ErrorAction SilentlyContinue | Select-Object TaskName, State)

$backupRoot = Join-Path $dshHome '.dsh-update-backups'
$latestBackup = $null
if (Test-Path -LiteralPath $backupRoot) {
    $latestBackup = Get-ChildItem -LiteralPath $backupRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'manifest.json') } |
        Sort-Object Name -Descending | Select-Object -First 1
}
$manifest = $null
if ($null -ne $latestBackup) {
    try { $manifest = Get-Content -LiteralPath (Join-Path $latestBackup.FullName 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $manifest = $null }
}

$logTail = @()
if ($null -ne $state -and -not [string]::IsNullOrWhiteSpace([string]$state.logPath) -and (Test-Path -LiteralPath ([string]$state.logPath))) {
    $logTail = @(Get-Content -LiteralPath ([string]$state.logPath) -Encoding UTF8 -Tail $TailLines -ErrorAction SilentlyContinue)
}

Write-Host ''
Write-Host '== 最近一次自动升级' -ForegroundColor Cyan
if ($null -eq $state) {
    Write-Host ("  没有找到自动升级记录：{0}" -f $latestPath) -ForegroundColor Yellow
} else {
    $label = $labels[[string]$state.status]
    if (-not $label) { $label = '未知状态' }
    Write-Host ("  状态          : {0}（{1}）" -f $state.status, $label)
    Write-Host ("  启动时间      : {0}" -f $state.startedAt)
    Write-Host ("  更新时间      : {0}" -f $state.updatedAt)
    Write-Host ("  计划任务      : {0}" -f $state.taskName)
    Write-Host ("  更新命令      : {0} {1}" -f $state.updaterScript, ((@($state.updaterArgs)) -join ' '))
    Write-Host ("  dsh 版本      : {0} -> {1}" -f $state.dshBefore, ($(if ([string]::IsNullOrWhiteSpace([string]$state.dshAfter)) { '未知' } else { $state.dshAfter })))
    Write-Host ("  updater 退出码: {0}" -f $state.exitCode)
    if (-not [string]::IsNullOrWhiteSpace([string]$state.backupDir)) { Write-Host ("  备份目录      : {0}" -f $state.backupDir) }
    Write-Host ("  日志          : {0}" -f $state.logPath)
}

Write-Host ''
Write-Host '== 当前环境' -ForegroundColor Cyan
Write-Host ("  当前 dsh 版本 : {0}" -f ($(if ($dshVersion) { $dshVersion } else { '未知' })))
Write-Host ("  DSH_HOME      : {0}" -f $dshHome)

if ($null -ne $manifest) {
    Write-Host ''
    Write-Host '== 最近一次备份清单' -ForegroundColor Cyan
    Write-Host ("  目录     : {0}" -f $latestBackup.FullName)
    Write-Host ("  时间     : {0}" -f $manifest.createdAt)
    Write-Host ("  dsh 版本 : {0} -> {1}" -f $manifest.dshBefore, $manifest.dshAfter)
    foreach ($p in @($manifest.profiles)) { Write-Host ("  profile  : {0}（{1}）" -f $p.name, (@($p.files) -join ', ')) }
    foreach ($r in @($manifest.results)) {
        $before = [string]$r.before
        $after = [string]$r.after
        $arrow = ''
        if ($before -or $after) { $arrow = '  {0} -> {1}' -f $before, $after }
        $note = ''
        if ($r.note) { $note = '（{0}）' -f $r.note }
        Write-Host ("  [{0}] {1}{2}{3}" -f $r.status, $r.item, $arrow, $note)
    }
    $updaterPath = '<dsh-updater 目录>\Update-Dsh.ps1'
    if ($null -ne $state -and -not [string]::IsNullOrWhiteSpace([string]$state.updaterScript)) { $updaterPath = [string]$state.updaterScript }
    Write-Host ("  回滚命令 : pwsh -NoProfile -ExecutionPolicy Bypass -File `"{0}`" -Rollback -Yes" -f $updaterPath)
}

Write-Host ''
Write-Host '== 残留计划任务' -ForegroundColor Cyan
if ($tasks.Count -eq 0) {
    Write-Host '  无'
} else {
    foreach ($t in $tasks) { Write-Host ("  {0} [{1}]" -f $t.TaskName, $t.State) }
    Write-Host "  清理：Get-ScheduledTask -TaskName 'DSH-AutoUpdate-*' | Unregister-ScheduledTask -Confirm:`$false"
}

if ($logTail.Count -gt 0) {
    Write-Host ''
    Write-Host ("== 日志尾部（最后 {0} 行）" -f $TailLines) -ForegroundColor Cyan
    foreach ($line in $logTail) { Write-Host ("  {0}" -f $line) }
}

Write-Host ''
if ($null -eq $state) {
    Write-Host '结论：没有自动升级记录（可能从未启动过，或记录已被清理）。' -ForegroundColor Yellow
} elseif ([string]$state.status -eq 'finished' -and [int]$state.exitCode -eq 0) {
    Write-Host '结论：升级成功。重启 DSH 后即可使用新版本。' -ForegroundColor Green
} elseif ([string]$state.status -eq 'failed') {
    Write-Host '结论：升级失败。看上方的失败项与日志尾部；需要时可执行上面的回滚命令。' -ForegroundColor Red
} elseif ([string]$state.status -eq 'timeout') {
    Write-Host '结论：等待 DSH 退出超时，本次没有升级。确认 DSH 完全退出后重新运行 skill。' -ForegroundColor Yellow
} elseif ([string]$state.status -eq 'waiting' -or [string]$state.status -eq 'running') {
    Write-Host '结论：升级还没有结束（DSH 可能尚未退出，或正在安装依赖）。' -ForegroundColor Yellow
} else {
    Write-Host '结论：见上方状态与日志。' -ForegroundColor Yellow
}
