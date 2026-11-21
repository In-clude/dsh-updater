<#
.SYNOPSIS
    让 dsh-updater 在「DSH 完全退出」后自动执行升级（Windows 计划任务版）。

.DESCRIPTION
    agent 自己运行在 dsh 进程内，而升级本体必须替换被运行中进程占用的文件；同时 DSH 在 Windows
    上用 kill-on-close 的 Job Object 管理子进程，所以直接在后台（Start-Process / nohup）启动的
    升级进程会随 DSH 退出被一起杀掉，升级会静默丢失。

    本脚本改为注册一个独立的 Windows 计划任务：worker 进程由任务计划程序托管，与 DSH 进程树无关。
    worker 先等所有 dsh node 进程退出（稳定若干秒），再以 -Yes 运行 Update-Dsh.ps1；结束后写状态、
    删除计划任务，并在窗口里停留一会儿展示结果。

    日志与状态：$DSH_HOME\.dsh-update-backups\logs\
        auto-update-<时间戳>.log      worker + updater 的完整输出
        auto-update-<时间戳>.job.json worker 的启动参数（排障用）
        auto-update-latest.json      最近一次运行的状态（重启后用 Get-DshUpdateStatus.ps1 读）

.PARAMETER UpdaterRoot
    dsh-updater 目录（含 Update-Dsh.ps1）。默认取环境变量 DSH_UPDATER_HOME，
    否则按本脚本所在位置的仓库相对路径推断。

.PARAMETER Scope
    透传给 Update-Dsh.ps1：All（默认）/ Core / Plugins。

.PARAMETER Profile
    透传：只更新指定 profile，如 -Profile web,headless（默认自动发现）。

.PARAMETER WithinRanges
    透传：只在 package.json 声明的 semver 范围内升级（默认升到 latest）。

.PARAMETER UpdateLinked
    透传：对 link: 本地插件目录执行 git pull --ff-only。

.PARAMETER NoBackup
    透传：跳过更新前备份（不推荐，会失去回滚能力）。

.PARAMETER Rollback
    回滚模式：退出 DSH 后执行 Update-Dsh.ps1 -Rollback（只回滚插件，不降级本体）。

.PARAMETER RollbackId
    回滚模式：指定备份目录名，如 20261023-213045（默认最近一次）。

.PARAMETER WaitTimeoutMinutes
    worker 等待 DSH 退出的上限，默认 120 分钟；超时则放弃本次升级。

.PARAMETER StableSeconds
    连续多少秒检测不到 dsh 进程才认为已完全退出，默认 6 秒。

.PARAMETER PauseSeconds
    升级结束后 worker 窗口停留的秒数，默认 120 秒（按任意键提前关闭）。

.PARAMETER SkipWait
    仅用于自检：跳过「等待 DSH 退出」，立即执行 updater。

.EXAMPLE
    .\Invoke-DshAutoUpgrade.ps1 -Scope All
    注册「退出 DSH 后自动升级本体 + 插件」的计划任务，然后请用户完全退出 DSH。

.EXAMPLE
    .\Invoke-DshAutoUpgrade.ps1 -Scope Plugins -Profile web
    只更新 web profile 的插件（同样在 DSH 退出后执行）。

.EXAMPLE
    .\Invoke-DshAutoUpgrade.ps1 -Rollback
    退出 DSH 后回滚到最近一次更新前。
#>
[CmdletBinding()]
param(
    [string]$UpdaterRoot = '',

    [ValidateSet('All', 'Core', 'Plugins')]
    [string]$Scope = 'All',

    [string[]]$Profile = @(),

    [switch]$WithinRanges,
    [switch]$UpdateLinked,
    [switch]$NoBackup,

    [switch]$Rollback,
    [string]$RollbackId = '',

    [int]$WaitTimeoutMinutes = 120,
    [int]$StableSeconds = 6,
    [int]$PauseSeconds = 120,

    [switch]$SkipWait
)

$ErrorActionPreference = 'Stop'

$script:TaskPrefix = 'DSH-AutoUpdate'

function Resolve-UpdaterRoot {
    param([string]$Requested)
    $candidates = New-Object System.Collections.ArrayList
    if (-not [string]::IsNullOrWhiteSpace($Requested)) { [void]$candidates.Add($Requested) }
    if (-not [string]::IsNullOrWhiteSpace($env:DSH_UPDATER_HOME)) { [void]$candidates.Add($env:DSH_UPDATER_HOME) }
    # 本 skill 位于 <repo>\skills\upgrade-dsh\scripts 时，上三级就是 dsh-updater 仓库根。
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        try {
            $repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\..') -ErrorAction Stop).Path
            [void]$candidates.Add($repoRoot)
        } catch { }
    }

    $tried = @()
    foreach ($candidate in $candidates) {
        try {
            $dir = (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path
        } catch {
            $tried += ("{0}（不存在）" -f $candidate)
            continue
        }
        if (Test-Path -LiteralPath (Join-Path $dir 'Update-Dsh.ps1')) { return $dir }
        $tried += ("{0}（缺少 Update-Dsh.ps1）" -f $dir)
    }
    throw ("找不到 dsh-updater（Update-Dsh.ps1）。请用 -UpdaterRoot 或环境变量 DSH_UPDATER_HOME 指定目录。已尝试：{0}" -f ($tried -join '；'))
}

function Resolve-PwshExe {
    $cmd = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) { return [string]$cmd.Source }
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\Microsoft.PowerShell_8wekyb3d8bbwe\pwsh.exe'),
        (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    $fallback = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $fallback) { return $fallback }
    throw '找不到 pwsh / Windows PowerShell，无法启动自动升级 worker。'
}

function Resolve-CommandPath {
    param([string]$Name)
    $cmd = Get-Command $Name -CommandType Application, ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $cmd) { return [string]$cmd.Source }
    return $null
}

# ---------------------------------------------------------------------------
# 前置检查
# ---------------------------------------------------------------------------
$updaterRoot = Resolve-UpdaterRoot -Requested $UpdaterRoot
$updaterScript = Join-Path $updaterRoot 'Update-Dsh.ps1'
$workerScript = Join-Path $PSScriptRoot 'Wait-ForDshExit.ps1'
if (-not (Test-Path -LiteralPath $workerScript)) { throw ("缺少 worker 脚本：{0}" -f $workerScript) }

$dshHome = ''
if (-not [string]::IsNullOrWhiteSpace($env:DSH_HOME)) {
    $dshHome = [System.IO.Path]::GetFullPath($env:DSH_HOME)
} else {
    $dshHome = [System.IO.Path]::GetFullPath((Join-Path $HOME '.dsh'))
}

$dshExe = Resolve-CommandPath 'dsh'
$npmExe = Resolve-CommandPath 'npm'
$pnpmExe = Resolve-CommandPath 'pnpm'
if ($null -eq $dshExe) { throw '找不到 dsh 命令。请先安装：npm install -g @deepseek-ai/dsh' }
if ($null -eq $pnpmExe) { throw '找不到 pnpm 命令（dsh 的插件管理依赖它，npm install -g pnpm 安装）。' }
if (-not $Rollback -and $Scope -ne 'Plugins' -and $null -eq $npmExe) { throw '找不到 npm 命令，无法更新 dsh 本体。' }

# 上一次运行残留的任务：正在运行的直接拒绝（避免两个 worker 抢更新），已结束的清理掉。
$existingTasks = @(Get-ScheduledTask -TaskName "$($script:TaskPrefix)-*" -ErrorAction SilentlyContinue)
foreach ($task in $existingTasks) {
    if ($task.State -eq 'Running') {
        throw ("已有正在等待/执行的自动升级任务：{0}。请等它完成，或先运行：Get-ScheduledTask -TaskName '{1}-*' | Unregister-ScheduledTask -Confirm:`$false" -f $task.TaskName, $script:TaskPrefix)
    }
    Unregister-ScheduledTask -TaskName $task.TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Warning ("已清理残留计划任务：{0}" -f $task.TaskName)
}

$dshBefore = ''
try {
    $versionText = (& $dshExe --version 2>$null | Select-Object -First 1)
    if ([string]$versionText -match '(\d+\.\d+\.\d+(?:-[0-9A-Za-z.\-]+)?)') { $dshBefore = $Matches[1] }
} catch { }

# ---------------------------------------------------------------------------
# 生成 job 文件（worker 通过它拿参数，避免计划任务命令行里堆参数和引号）
# ---------------------------------------------------------------------------
$backupRoot = Join-Path $dshHome '.dsh-update-backups'
$logsDir = Join-Path $backupRoot 'logs'
if (-not (Test-Path -LiteralPath $logsDir)) { New-Item -ItemType Directory -Force -Path $logsDir | Out-Null }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$taskName = "$($script:TaskPrefix)-$stamp"
$logPath = Join-Path $logsDir ("auto-update-{0}.log" -f $stamp)
$latestPath = Join-Path $logsDir 'auto-update-latest.json'
$jobFile = Join-Path $logsDir ("auto-update-{0}.job.json" -f $stamp)

if ($Rollback) {
    $updaterArgs = @('-Rollback', '-Yes')
    if (-not [string]::IsNullOrWhiteSpace($RollbackId)) { $updaterArgs += @('-RollbackId', $RollbackId) }
} else {
    $updaterArgs = @('-Scope', $Scope, '-Yes')
    if (@($Profile).Count -gt 0) { $updaterArgs += @('-Profile', ($Profile -join ',')) }
    if ($WithinRanges) { $updaterArgs += '-WithinRanges' }
    if ($UpdateLinked) { $updaterArgs += '-UpdateLinked' }
    if ($NoBackup) { $updaterArgs += '-NoBackup' }
}

$job = [ordered]@{
    taskName           = $taskName
    updaterScript      = $updaterScript
    updaterArgs        = @($updaterArgs)
    workerScript       = $workerScript
    logPath            = $logPath
    latestPath         = $latestPath
    jobFile            = $jobFile
    dshHome            = $dshHome
    dshBefore          = $dshBefore
    pathEnv            = [string]$env:PATH
    waitTimeoutMinutes = $WaitTimeoutMinutes
    stableSeconds      = $StableSeconds
    pauseSeconds       = $PauseSeconds
    skipWait           = [bool]$SkipWait
    createdAt          = (Get-Date).ToString('o')
}
$jobJson = $job | ConvertTo-Json -Depth 6
[System.IO.File]::WriteAllText($jobFile, $jobJson, (New-Object System.Text.UTF8Encoding $true))

# ---------------------------------------------------------------------------
# 注册并启动计划任务
# ---------------------------------------------------------------------------
$pwshExe = Resolve-PwshExe
$actionArgument = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -JobFile "{1}"' -f $workerScript, $jobFile
$action = New-ScheduledTaskAction -Execute $pwshExe -Argument $actionArgument
# 触发时间放得很远：任务靠 Start-ScheduledTask 立即执行，worker 启动后会把任务本身删掉。
$trigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddYears(10))
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 8)

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Description 'DSH 自动升级（由 upgrade-dsh skill 创建，worker 启动后自行删除）' | Out-Null
Start-ScheduledTask -TaskName $taskName

$started = $false
$deadline = (Get-Date).AddSeconds(30)
while ((Get-Date) -lt $deadline) {
    if (Test-Path -LiteralPath $latestPath) {
        try {
            $state = Get-Content -LiteralPath $latestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([string]$state.jobFile -eq $jobFile) { $started = $true; break }
        } catch { }
    }
    Start-Sleep -Milliseconds 500
}

if (-not $started) {
    $taskInfo = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    throw ("计划任务没有正常启动（worker 未写出状态文件）。TaskInfo：{0}；worker={1}；pwsh={2}" -f (($taskInfo | Out-String).Trim()), $workerScript, $pwshExe)
}

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '== 已就绪：DSH 完全退出后自动升级' -ForegroundColor Cyan
Write-Host ("  计划任务    : {0}" -f $taskName)
Write-Host ("  等待条件    : 所有 dsh node 进程退出并稳定 {0} 秒（最多等 {1} 分钟）" -f $StableSeconds, $WaitTimeoutMinutes)
Write-Host ("  更新命令    : {0} {1}" -f $updaterScript, ($updaterArgs -join ' '))
Write-Host ("  当前版本    : {0}" -f ($(if ($dshBefore) { "dsh $dshBefore" } else { '未知' })))
Write-Host ("  日志        : {0}" -f $logPath)
Write-Host ("  状态        : {0}" -f $latestPath)
Write-Host ''
Write-Host '接下来：完全退出 DSH（关掉所有 DSH 窗口和终端里的 dsh）。「DSH 自动升级」窗口现在正在等它退出，完成后窗口和日志都会给出结果，然后再重新打开 DSH。' -ForegroundColor Yellow
Write-Host ''
Write-Host ("[DSH-AUTO-UPDATE] task={0} log={1} latest={2}" -f $taskName, $logPath, $latestPath)
exit 0
