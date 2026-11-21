<#
.SYNOPSIS
    dsh-updater 自动升级 worker：等所有 DSH 进程退出后执行升级。

.DESCRIPTION
    由 Invoke-DshAutoUpgrade.ps1 通过 Windows 计划任务启动，与 DSH 进程树无关，
    因此 DSH 退出时不会被 kill-on-close 的 Job Object 一起带走。

    流程：读取 job 文件 → 删除计划任务（此后不再依赖 Task Scheduler）
         → 等待所有 dsh node 进程退出并稳定 N 秒
         → 以 job 里的参数运行 Update-Dsh.ps1
         → 写状态文件、窗口停留展示结果、退出。

.NOTES
    退出码：0 成功，1 升级失败，2 等待 DSH 退出超时，3 其他错误。
    不要手动调用本脚本；由 Invoke-DshAutoUpgrade.ps1 负责注册计划任务。
#>
param(
    [Parameter(Mandatory = $true)][string]$JobFile,
    [switch]$NoWait
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { }
try { $Host.UI.RawUI.WindowTitle = 'DSH 自动升级（请勿关闭本窗口）' } catch { }

# ---------------------------------------------------------------------------
# 读取 job
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $JobFile)) {
    Write-Host ("找不到 job 文件：{0}" -f $JobFile) -ForegroundColor Red
    Start-Sleep -Seconds 10
    exit 3
}
$jobText = [System.IO.File]::ReadAllText($JobFile, [System.Text.Encoding]::UTF8)
$job = $jobText | ConvertFrom-Json

$logPath = [string]$job.logPath
$latestPath = [string]$job.latestPath
$logDir = Split-Path -Parent $logPath
if ($logDir -and -not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = ('[{0}] [{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Message)
    Write-Host $line
    try { Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8 } catch { }
}

$script:State = [ordered]@{
    status        = 'starting'
    taskName      = [string]$job.taskName
    jobFile       = $JobFile
    logPath       = $logPath
    updaterScript = [string]$job.updaterScript
    updaterArgs   = @($job.updaterArgs)
    dshBefore     = [string]$job.dshBefore
    dshAfter      = ''
    exitCode      = $null
    backupDir     = ''
    message       = ''
    createdAt     = [string]$job.createdAt
    startedAt     = (Get-Date).ToString('o')
    updatedAt     = (Get-Date).ToString('o')
}

function Set-State {
    param([string]$Status, [hashtable]$Extra = @{})
    $script:State.status = $Status
    foreach ($key in $Extra.Keys) { $script:State[$key] = $Extra[$key] }
    $script:State.updatedAt = (Get-Date).ToString('o')
    try {
        $json = $script:State | ConvertTo-Json -Depth 6
        [System.IO.File]::WriteAllText($latestPath, $json, (New-Object System.Text.UTF8Encoding $false))
    } catch {
        Write-Log ("状态文件写入失败：{0}" -f $_.Exception.Message) 'WARN'
    }
}

Set-State 'starting' @{ message = 'worker 已启动' }

Write-Log ("自动升级 worker 启动：job={0}" -f $JobFile)
Write-Log ("PowerShell {0}（{1}）" -f $PSVersionTable.PSVersion.ToString(), (Get-Process -Id $PID).Path)

# 任务已经执行到这一步，先删掉计划任务；即使后面窗口被关掉也不会留下会自动触发的任务。
if (-not [string]::IsNullOrWhiteSpace([string]$job.taskName)) {
    try {
        Unregister-ScheduledTask -TaskName ([string]$job.taskName) -Confirm:$false -ErrorAction Stop
        Write-Log ("已删除计划任务 {0}（worker 已独立运行）" -f $job.taskName)
    } catch {
        Write-Log ("删除计划任务失败（可忽略，稍后可手动清理）：{0}" -f $_.Exception.Message) 'WARN'
    }
}

# ---------------------------------------------------------------------------
# 进程检测（与 Update-Dsh.ps1 使用同一匹配规则，避免两边判断不一致）
# ---------------------------------------------------------------------------
function Get-DshProcessSnapshot {
    $processes = New-Object System.Collections.ArrayList
    $supported = $false
    try {
        $cim = Get-CimInstance -ClassName Win32_Process -Filter "Name='node.exe'" -ErrorAction Stop
        $supported = $true
        foreach ($p in $cim) {
            $cl = [string]$p.CommandLine
            if ($cl -match '(?i)@deepseek-ai[\\/]dsh[\\/]lib[\\/]bin\.js') {
                [void]$processes.Add([pscustomobject]@{ Id = [int]$p.ProcessId; CommandLine = $cl })
            }
        }
    } catch {
        try {
            $procs = @(Get-Process -Name node -ErrorAction Stop)
            $supported = $true
            foreach ($p in $procs) {
                $cl = ''
                if ($p.PSObject.Properties.Name -contains 'CommandLine') { $cl = [string]$p.CommandLine }
                if ($cl -and $cl -match '(?i)@deepseek-ai[\\/]dsh[\\/]lib[\\/]bin\.js') {
                    [void]$processes.Add([pscustomobject]@{ Id = [int]$p.Id; CommandLine = $cl })
                }
            }
        } catch {
            $supported = $false
        }
    }
    return [pscustomobject]@{ Supported = $supported; Processes = $processes.ToArray() }
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
    return (Get-Process -Id $PID).Path
}

function Resolve-CommandPath {
    param([string]$Name)
    $cmd = Get-Command $Name -CommandType Application, ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $cmd) { return [string]$cmd.Source }
    return $null
}

# ---------------------------------------------------------------------------
# 等待 DSH 退出
# ---------------------------------------------------------------------------
$skipWait = $NoWait -or [bool]$job.skipWait
$exited = $false
if ($skipWait) {
    Write-Log '自检模式：跳过等待 DSH 退出'
    $exited = $true
} else {
    $waitMinutes = [int]$job.waitTimeoutMinutes
    $stableSeconds = [int]$job.stableSeconds
    $deadline = (Get-Date).AddMinutes($waitMinutes)
    $clearSince = $null
    $lastReport = ''
    Set-State 'waiting' @{ message = '等待所有 DSH 进程退出' }
    Write-Log ("等待所有 DSH 进程退出（最多 {0} 分钟；连续 {1} 秒检测不到才继续）" -f $waitMinutes, $stableSeconds)

    while ((Get-Date) -lt $deadline) {
        $snapshot = Get-DshProcessSnapshot
        if (-not $snapshot.Supported) {
            Write-Log '无法枚举进程（受权限或系统限制），不能确认 DSH 已退出，放弃本次自动升级。' 'ERROR'
            Set-State 'error' @{ message = '无法枚举进程，不能确认 DSH 已退出' }
            exit 3
        }
        $count = @($snapshot.Processes).Count
        if ($count -eq 0) {
            if ($null -eq $clearSince) {
                $clearSince = Get-Date
                Write-Log '未检测到 DSH 进程，确认稳定后开始升级…'
            }
            if (((Get-Date) - $clearSince).TotalSeconds -ge $stableSeconds) {
                $exited = $true
                break
            }
        } else {
            if ($null -ne $clearSince) {
                Write-Log '又检测到 DSH 进程，继续等待…'
                $clearSince = $null
            }
            $pids = (@($snapshot.Processes) | ForEach-Object { [string]$_.Id }) -join ', '
            if ($pids -ne $lastReport) {
                Write-Log ("DSH 仍在运行（PID: {0}），继续等待…" -f $pids)
                $lastReport = $pids
            }
        }
        Start-Sleep -Seconds 2
    }

    if (-not $exited) {
        Write-Log ("等待超时（{0} 分钟）：DSH 仍未完全退出，放弃本次自动升级。" -f $waitMinutes) 'ERROR'
        Set-State 'timeout' @{ message = '等待 DSH 退出超时，未执行升级' }
        Write-Host ''
        Write-Host '等待超时：DSH 还没有完全退出，本次没有升级。' -ForegroundColor Yellow
        Write-Host '请确认关掉了所有 DSH 窗口和终端里的 dsh 进程，然后重新运行升级。' -ForegroundColor Yellow
        Start-Sleep -Seconds 20
        exit 2
    }
}

# ---------------------------------------------------------------------------
# 执行 updater
# ---------------------------------------------------------------------------
if (-not [string]::IsNullOrWhiteSpace([string]$job.dshHome)) { $env:DSH_HOME = [string]$job.dshHome }
if (-not [string]::IsNullOrWhiteSpace([string]$job.pathEnv)) { $env:PATH = [string]$job.pathEnv }

$pwshExe = Resolve-PwshExe
$argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', [string]$job.updaterScript)
foreach ($a in @($job.updaterArgs)) { $argList += [string]$a }

Write-Log 'DSH 已退出，开始执行 dsh-updater…'
Write-Log ("执行：{0} {1}" -f $pwshExe, ($argList -join ' '))
Set-State 'running' @{ message = '正在执行升级' }

$exitCode = 0
try {
    & $pwshExe @argList 2>&1 | ForEach-Object {
        Write-Log ([string]$_) 'OUT'
    }
    if ($null -ne $LASTEXITCODE) { $exitCode = [int]$LASTEXITCODE } else { $exitCode = 0 }
} catch {
    Write-Log ("执行 updater 失败：{0}" -f $_.Exception.Message) 'ERROR'
    $exitCode = 127
}

# ---------------------------------------------------------------------------
# 收尾：版本、备份目录、状态、展示
# ---------------------------------------------------------------------------
$dshAfter = ''
try {
    $dshCmd = Resolve-CommandPath 'dsh'
    if ($dshCmd) {
        $versionText = (& $dshCmd --version 2>$null | Select-Object -First 1)
        if ([string]$versionText -match '(\d+\.\d+\.\d+(?:-[0-9A-Za-z.\-]+)?)') { $dshAfter = $Matches[1] }
    }
} catch { }

$backupDir = ''
try {
    $backupRoot = Join-Path ([string]$job.dshHome) '.dsh-update-backups'
    if (Test-Path -LiteralPath $backupRoot) {
        $candidate = Get-ChildItem -LiteralPath $backupRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'manifest.json') } |
            Sort-Object Name -Descending | Select-Object -First 1
        if ($null -ne $candidate) { $backupDir = $candidate.FullName }
    }
} catch { }

if ($exitCode -eq 0) {
    Write-Log ("升级完成：dsh {0} -> {1}" -f $job.dshBefore, ($(if ($dshAfter) { $dshAfter } else { '未知' }))) 'OK'
    Set-State 'finished' @{ exitCode = 0; dshAfter = $dshAfter; backupDir = $backupDir; message = '升级完成' }
} else {
    Write-Log ("升级失败：updater 退出码 {0}，详见日志与备份目录。" -f $exitCode) 'ERROR'
    Set-State 'failed' @{ exitCode = $exitCode; dshAfter = $dshAfter; backupDir = $backupDir; message = ("updater 退出码 {0}" -f $exitCode) }
}

Write-Host ''
Write-Host '============================================' -ForegroundColor Cyan
if ($exitCode -eq 0) {
    Write-Host '  DSH 升级完成，可以重新打开 DSH 了。' -ForegroundColor Green
} else {
    Write-Host '  DSH 升级失败，请查看日志后重试或回滚。' -ForegroundColor Red
}
Write-Host ("  日志：{0}" -f $logPath)
if ($backupDir) { Write-Host ("  备份：{0}" -f $backupDir) }
Write-Host ("  dsh：{0} -> {1}" -f $job.dshBefore, ($(if ($dshAfter) { $dshAfter } else { '未知' })))
Write-Host '============================================' -ForegroundColor Cyan

$pauseSeconds = [int]$job.pauseSeconds
if ($pauseSeconds -gt 0) {
    Write-Host ("窗口将在 {0} 秒后自动关闭（按任意键立即关闭）。" -f $pauseSeconds) -ForegroundColor DarkGray
    for ($i = 0; $i -lt $pauseSeconds; $i++) {
        try {
            if ([Console]::KeyAvailable) { [void][Console]::ReadKey($true); break }
        } catch { }
        Start-Sleep -Seconds 1
    }
}

if ($exitCode -eq 0) { exit 0 } else { exit 1 }
