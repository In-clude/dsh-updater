<#
.SYNOPSIS
    一键更新 DeepSeek Harness（dsh 本体）与各 profile 的插件。

.DESCRIPTION
    更新顺序：先更新 npm 全局安装的 dsh 本体，再更新各 profile（默认自动发现）里
    package.json 声明的注册表插件。插件更新走 `dsh plugin --profile <名字> update`，
    由 dsh 自己在安装前后做版本兼容性校验，不兼容的新版本会被自动回滚，因此更新
    不会把 profile 留在“能装上但启动被拒”的状态。

    每次实际更新前，都会把 profile 的 package.json / pnpm-lock.yaml 等清单备份到
    $DSH_HOME\.dsh-update-backups\<时间戳>\，可用 -Rollback 恢复。

.PARAMETER Scope
    更新范围：All（默认，本体+插件）、Core（只更新本体）、Plugins（只更新插件）。

.PARAMETER Profile
    要更新的 profile 名，可写多个（如 -Profile web,headless）。默认自动发现
    $DSH_HOME\profiles 下所有含 package.json 的 profile。

.PARAMETER WithinRanges
    只在 package.json 声明的 semver 范围内取最新版本；默认（不加此开关）会跨范围
    升到 latest。

.PARAMETER DryRun
    只检查、只打印计划，不做任何修改（不备份、不安装）。

.PARAMETER Yes
    不交互确认，直接执行（供计划任务等非交互场景使用）。

.PARAMETER Force
    即使检测到 DSH 正在运行也继续。更新本体时 DSH 运行中会占用被替换的文件，
    通常会导致 npm 失败，请优先退出 DSH。

.PARAMETER SkipIfRunning
    检测到 DSH 正在运行时静默跳过并以退出码 0 结束（适合定时任务）。

.PARAMETER UpdateLinked
    对 package.json 里 `link:` 的本地插件目录执行 `git pull --ff-only`
    （默认跳过，只在清单里提示）。

.PARAMETER NoBackup
    跳过更新前备份（不推荐；会同时失去 -Rollback 的能力）。

.PARAMETER Rollback
    回滚模式：把最近一次（或用 -RollbackId 指定的）备份清单恢复回各 profile，
    并执行 `pnpm install --frozen-lockfile` 重新安装。

.PARAMETER RollbackId
    配合 -Rollback 使用的备份目录名（如 20261023-213045），默认取最近一次。

.EXAMPLE
    .\Update-Dsh.ps1 -DryRun
    预览：列出 dsh 本体与插件可更新的版本，不做修改。

.EXAMPLE
    .\Update-Dsh.ps1
    交互式更新本体 + 全部 profile 的插件（会先征得确认）。

.EXAMPLE
    .\Update-Dsh.ps1 -Scope Plugins -Profile web -Yes
    只把 web profile 的插件更新到 latest，不交互（需要退出 DSH 后执行）。

.EXAMPLE
    .\Update-Dsh.ps1 -Rollback
    回滚到最近一次更新前的插件版本。
#>
[CmdletBinding()]
param(
    [ValidateSet('All', 'Core', 'Plugins')]
    [string]$Scope = 'All',

    [string[]]$Profile = @(),

    [switch]$WithinRanges,
    [switch]$DryRun,
    [switch]$Yes,
    [switch]$Force,
    [switch]$SkipIfRunning,
    [switch]$UpdateLinked,
    [switch]$NoBackup,
    [switch]$Rollback,
    [string]$RollbackId = ''
)

$ErrorActionPreference = 'Stop'

$script:ScriptVersion = '1.0.0'
$script:DshHome = $null
$script:Log = New-Object System.Collections.ArrayList
$script:Results = New-Object System.Collections.ArrayList
$script:Failures = 0
$script:LogPath = $null
$script:BackupDir = $null
$script:CoreUpdated = $false

# ---------------------------------------------------------------------------
# 输出（同时写入内存日志，结束时落盘）
# ---------------------------------------------------------------------------
function Write-Line {
    param([string]$Text = '', [string]$Color = '')
    if ($Color) { Write-Host $Text -ForegroundColor $Color } else { Write-Host $Text }
    [void]$script:Log.Add($Text)
}
function Write-Step { param([string]$Text) Write-Line ''; Write-Line "== $Text" 'Cyan' }
function Write-Info { param([string]$Text) Write-Line "   $Text" }
function Write-Ok { param([string]$Text) Write-Line "  [OK]   $Text" 'Green' }
function Write-Skip { param([string]$Text) Write-Line "  [SKIP] $Text" 'DarkGray' }
function Write-Warn { param([string]$Text) Write-Line "  [WARN] $Text" 'Yellow' }
function Write-Fail { param([string]$Text) Write-Line "  [FAIL] $Text" 'Red' }

function Add-Result {
    param([string]$Item, [string]$Before = '', [string]$After = '', [string]$Status = 'ok', [string]$Note = '')
    [void]$script:Results.Add([pscustomobject]@{
            Item = $Item; Before = $Before; After = $After; Status = $Status; Note = $Note
        })
}

function Confirm-Action {
    param([string]$Message)
    if ($Yes) { return $true }
    if (-not [Environment]::UserInteractive) {
        Write-Warn "当前不是交互式终端，未加 -Yes 时默认中止。"
        return $false
    }
    $answer = Read-Host "  $Message [Y/n]"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $true }
    return ($answer -match '^(y|yes|是|好|确认|ok)$')
}

function Save-Log {
    param([string]$Path)
    try {
        $parent = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
        ($script:Log -join [Environment]::NewLine) | Set-Content -LiteralPath $Path -Encoding utf8
        $script:LogPath = $Path
    } catch {
        Write-Warn "日志写入失败：$($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# 基础工具
# ---------------------------------------------------------------------------
function Resolve-DshHomePath {
    $envHome = [Environment]::GetEnvironmentVariable('DSH_HOME')
    if (-not [string]::IsNullOrWhiteSpace($envHome)) {
        return [System.IO.Path]::GetFullPath($envHome.Trim())
    }
    return [System.IO.Path]::GetFullPath((Join-Path $HOME '.dsh'))
}

function Resolve-Executable {
    param([string]$Name)
    foreach ($candidate in @("$Name.cmd", "$Name.exe", $Name)) {
        $cmd = Get-Command $candidate -CommandType Application, ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $cmd) { return $cmd.Source }
    }
    return $null
}

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [string[]]$Arguments = @(),
        [string]$WorkDir = '',
        [switch]$Quiet,
        [switch]$AllowFail
    )
    if (-not (Test-Path -LiteralPath $Exe)) {
        $msg = "命令不存在：$Exe"
        if (-not $Quiet) { Write-Fail $msg }
        return [pscustomobject]@{ ExitCode = 127; Output = @($msg) }
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $pushed = $false
    $code = 0
    try {
        if ($WorkDir) {
            if (-not (Test-Path -LiteralPath $WorkDir)) { throw "目录不存在：$WorkDir" }
            Push-Location -LiteralPath $WorkDir
            $pushed = $true
        }
        & $Exe @Arguments 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { $text = $_.ToString() } else { $text = [string]$_ }
            $lines.Add($text)
            if (-not $Quiet) {
                [Console]::Out.WriteLine($text)
                [void]$script:Log.Add($text)
            }
        }
        if ($null -ne $LASTEXITCODE) { $code = $LASTEXITCODE } else { $code = 0 }
    } catch {
        $lines.Add($_.Exception.Message)
        if (-not $Quiet) { Write-Fail $_.Exception.Message }
        $code = 127
    } finally {
        if ($pushed) { Pop-Location }
    }
    if ($code -ne 0 -and -not $AllowFail) {
        throw "命令失败（exit $code）：$(Split-Path -Leaf $Exe) $($Arguments -join ' ')"
    }
    return [pscustomobject]@{ ExitCode = $code; Output = $lines.ToArray() }
}

# ---------------------------------------------------------------------------
# 版本号
# ---------------------------------------------------------------------------
function ConvertTo-SemVer {
    param([string]$Version)
    if ([string]::IsNullOrWhiteSpace($Version)) { return $null }
    $v = $Version.Trim()
    if ($v.StartsWith('v') -or $v.StartsWith('V')) { $v = $v.Substring(1) }
    $m = [regex]::Match($v, '^(?<maj>\d+)(?:\.(?<min>\d+))?(?:\.(?<pat>\d+))?(?:-(?<pre>[0-9A-Za-z.\-]+))?(?:\+[0-9A-Za-z.\-]+)?$')
    if (-not $m.Success) { return $null }
    $minor = 0
    $patch = 0
    $pre = ''
    if ($m.Groups['min'].Success) { $minor = [int]$m.Groups['min'].Value }
    if ($m.Groups['pat'].Success) { $patch = [int]$m.Groups['pat'].Value }
    if ($m.Groups['pre'].Success) { $pre = $m.Groups['pre'].Value }
    return [pscustomobject]@{
        Major = [int]$m.Groups['maj'].Value
        Minor = $minor
        Patch = $patch
        Prerelease = $pre
    }
}

function Compare-SemVer {
    param([string]$A, [string]$B)
    $pa = ConvertTo-SemVer $A
    $pb = ConvertTo-SemVer $B
    if ($null -eq $pa -or $null -eq $pb) { return 0 }
    foreach ($part in @('Major', 'Minor', 'Patch')) {
        if ($pa.$part -ne $pb.$part) { return [Math]::Sign($pa.$part - $pb.$part) }
    }
    $preA = $pa.Prerelease
    $preB = $pb.Prerelease
    if ($preA -eq $preB) { return 0 }
    if ($preA -eq '') { return 1 }
    if ($preB -eq '') { return -1 }
    $idsA = $preA.Split('.')
    $idsB = $preB.Split('.')
    $n = [Math]::Min($idsA.Count, $idsB.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $a = $idsA[$i]
        $b = $idsB[$i]
        $na = 0
        $nb = 0
        $aNum = [int]::TryParse($a, [ref]$na)
        $bNum = [int]::TryParse($b, [ref]$nb)
        if ($aNum -and $bNum) {
            if ($na -ne $nb) { return [Math]::Sign($na - $nb) }
        } elseif ($aNum) {
            return -1
        } elseif ($bNum) {
            return 1
        } else {
            $cmp = [string]::CompareOrdinal($a, $b)
            if ($cmp -ne 0) { return [Math]::Sign($cmp) }
        }
    }
    return [Math]::Sign($idsA.Count - $idsB.Count)
}

function Get-DshVersion {
    param([string]$DshPath)
    $r = Invoke-Native -Exe $DshPath -Arguments @('--version') -Quiet -AllowFail
    foreach ($line in $r.Output) {
        $m = [regex]::Match($line, '\d+\.\d+\.\d+(?:-[0-9A-Za-z.\-]+)?(?:\+[0-9A-Za-z.\-]+)?')
        if ($m.Success) { return $m.Value }
    }
    return $null
}

function Get-LatestDshVersion {
    param([string]$NpmPath)
    $r = Invoke-Native -Exe $NpmPath -Arguments @('view', '@deepseek-ai/dsh', 'dist-tags.latest', '--no-color') -Quiet -AllowFail
    foreach ($line in $r.Output) {
        $trim = $line.Trim()
        $m = [regex]::Match($trim, '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.\-]+)?(?:\+[0-9A-Za-z.\-]+)?$')
        if ($m.Success) { return $trim }
    }
    return $null
}

# ---------------------------------------------------------------------------
# profile 与依赖
# ---------------------------------------------------------------------------
function Get-ProfileInfos {
    param([string[]]$Requested)
    $result = New-Object System.Collections.ArrayList
    $root = Join-Path $script:DshHome 'profiles'
    $names = @()
    $useAll = ($Requested.Count -eq 0)
    foreach ($item in $Requested) {
        if ($item -eq 'all' -or $item -eq '*') { $useAll = $true }
    }
    if ($useAll) {
        if (Test-Path -LiteralPath $root) {
            $names = Get-ChildItem -LiteralPath $root -Directory |
                Where-Object { $_.Name -ne 'node_modules' -and (Test-Path -LiteralPath (Join-Path $_.FullName 'package.json')) } |
                ForEach-Object { $_.Name } | Sort-Object
        }
    } else {
        $names = $Requested | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() } | Select-Object -Unique
    }
    foreach ($name in $names) {
        $dir = Join-Path $root $name
        [void]$result.Add([pscustomobject]@{
                Name = $name
                Dir = $dir
                HasManifest = (Test-Path -LiteralPath (Join-Path $dir 'package.json'))
            })
    }
    return , $result
}

function Get-ProfileDeps {
    param([string]$ProfileDir)
    $deps = [ordered]@{}
    $file = Join-Path $ProfileDir 'package.json'
    if (-not (Test-Path -LiteralPath $file)) { return $deps }
    $json = Get-Content -LiteralPath $file -Raw -Encoding utf8 | ConvertFrom-Json
    foreach ($section in @('dependencies', 'devDependencies', 'optionalDependencies')) {
        $obj = $json.$section
        if ($null -eq $obj) { continue }
        foreach ($prop in $obj.PSObject.Properties) {
            if ($deps.Contains($prop.Name)) { continue }
            $deps[$prop.Name] = [pscustomobject]@{ Name = $prop.Name; Spec = [string]$prop.Value; Section = $section }
        }
    }
    return $deps
}

function Test-RegistrySpec {
    param([string]$Spec)
    if ([string]::IsNullOrWhiteSpace($Spec)) { return $false }
    $s = $Spec.Trim()
    if ($s -eq '*' -or $s -eq 'latest' -or $s -eq 'x') { return $true }
    # 纯数字/范围操作符开头（^1.2.3、~1.2、>=1、1.x、1.2.3）视为注册表版本范围；
    # link:/file:/workspace:/git+/github:/http:/npm: 以及路径都不是。
    return ($s -match '^[\s\^~><=v]*\d')
}

function Get-InstalledVersion {
    param([string]$ProfileDir, [string]$PackageName)
    $rel = $PackageName.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
    $file = Join-Path (Join-Path (Join-Path $ProfileDir 'node_modules') $rel) 'package.json'
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    try { return [string](Get-Content -LiteralPath $file -Raw -Encoding utf8 | ConvertFrom-Json).version } catch { return $null }
}

function Get-OutdatedMap {
    param([string]$ProfileDir, [switch]$Compatible)
    $pnpmArgs = @('outdated', '--format', 'json')
    if ($Compatible) { $pnpmArgs += '--compatible' }
    $r = Invoke-Native -Exe $script:Pnpm -Arguments $pnpmArgs -WorkDir $ProfileDir -Quiet -AllowFail
    $text = ($r.Output -join "`n")
    $start = $text.IndexOf('{')
    $end = $text.LastIndexOf('}')
    if ($start -lt 0 -or $end -le $start) { return [pscustomobject]@{ Ok = $false; Map = @{} } }
    try {
        $parsed = $text.Substring($start, $end - $start + 1) | ConvertFrom-Json
    } catch {
        return [pscustomobject]@{ Ok = $false; Map = @{} }
    }
    $map = @{}
    foreach ($prop in $parsed.PSObject.Properties) { $map[$prop.Name] = $prop.Value }
    return [pscustomobject]@{ Ok = $true; Map = $map }
}

# ---------------------------------------------------------------------------
# 计划
# ---------------------------------------------------------------------------
function New-ProfilePlan {
    param([pscustomobject]$ProfileInfo)

    $plan = [pscustomobject]@{
        Name      = $ProfileInfo.Name
        Dir       = $ProfileInfo.Dir
        Skipped   = $false
        Reason    = ''
        Registry  = @()
        Linked    = @()
        OutdatedOk = $false
        AlwaysRun = $false
        Candidates = @()
        UpToDate  = @()
    }

    if ($ProfileInfo.Name -eq 'desktop') {
        $plan.Skipped = $true
        $plan.Reason = 'desktop 是桌面应用保留 profile，由应用自己管理'
        return $plan
    }
    if (-not $ProfileInfo.HasManifest) {
        $plan.Skipped = $true
        $plan.Reason = 'profile 目录下没有 package.json（从未初始化）'
        return $plan
    }

    $deps = Get-ProfileDeps -ProfileDir $ProfileInfo.Dir
    $registryNames = New-Object System.Collections.ArrayList
    $linkedList = New-Object System.Collections.ArrayList
    foreach ($name in $deps.Keys) {
        $dep = $deps[$name]
        if (Test-RegistrySpec $dep.Spec) {
            [void]$registryNames.Add($name)
        } else {
            [void]$linkedList.Add($dep)
        }
    }
    $plan.Registry = $registryNames.ToArray()
    $plan.Linked = $linkedList.ToArray()

    if ($plan.Registry.Count -eq 0) {
        $plan.Skipped = $true
        $plan.Reason = '没有注册表插件依赖'
        return $plan
    }

    $query = Get-OutdatedMap -ProfileDir $ProfileInfo.Dir -Compatible:($WithinRanges.IsPresent)
    $plan.OutdatedOk = $query.Ok
    if (-not $query.Ok) {
        $plan.AlwaysRun = $true
        foreach ($name in $plan.Registry) {
            $plan.Candidates += [pscustomobject]@{
                Name = $name; Installed = (Get-InstalledVersion -ProfileDir $ProfileInfo.Dir -PackageName $name); Target = $null
            }
        }
        return $plan
    }

    foreach ($name in $plan.Registry) {
        $installed = Get-InstalledVersion -ProfileDir $ProfileInfo.Dir -PackageName $name
        $info = $query.Map[$name]
        if ($null -eq $info -or [string]::IsNullOrWhiteSpace([string]$info.latest)) {
            if ($null -ne $installed) { $plan.UpToDate += $name }
            continue
        }
        $target = [string]$info.latest
        if ($null -eq $installed) {
            $plan.Candidates += [pscustomobject]@{ Name = $name; Installed = $null; Target = $target }
        } elseif ((Compare-SemVer -A $target -B $installed) -gt 0) {
            $plan.Candidates += [pscustomobject]@{ Name = $name; Installed = $installed; Target = $target }
        } else {
            $plan.UpToDate += $name
        }
    }
    return $plan
}

# ---------------------------------------------------------------------------
# DSH 进程检测
# ---------------------------------------------------------------------------
function Get-DshProcessInfo {
    $procs = New-Object System.Collections.ArrayList
    $supported = $false
    try {
        $cim = Get-CimInstance -ClassName Win32_Process -Filter "Name='node.exe'" -ErrorAction Stop
        $supported = $true
        foreach ($p in $cim) {
            $cl = [string]$p.CommandLine
            if ($cl -match '(?i)@deepseek-ai[\\/]dsh[\\/]lib[\\/]bin\.js') {
                [void]$procs.Add([pscustomobject]@{ Id = [int]$p.ProcessId; CommandLine = $cl })
            }
        }
    } catch {
        try {
            $gp = @(Get-Process -Name node -ErrorAction Stop)
            if ($gp.Count -eq 0) {
                $supported = $true
            } elseif ($gp[0].PSObject.Properties.Name -contains 'CommandLine') {
                $supported = $true
                foreach ($p in $gp) {
                    $cl = [string]$p.CommandLine
                    if ($cl -match '(?i)@deepseek-ai[\\/]dsh[\\/]lib[\\/]bin\.js') {
                        [void]$procs.Add([pscustomobject]@{ Id = [int]$p.Id; CommandLine = $cl })
                    }
                }
            }
        } catch {
            $supported = $false
        }
    }
    return [pscustomobject]@{ Supported = $supported; Processes = $procs.ToArray() }
}

# ---------------------------------------------------------------------------
# 备份 / 回滚
# ---------------------------------------------------------------------------
function Get-BackupRoot { return (Join-Path $script:DshHome '.dsh-update-backups') }

function New-Backup {
    param([object[]]$ProfilesToBackup)
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dir = Join-Path (Get-BackupRoot) $stamp
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $manifest = [ordered]@{
        createdAt  = (Get-Date).ToString('o')
        script     = "Update-Dsh.ps1 $($script:ScriptVersion)"
        scope      = $Scope
        dshBefore  = $script:DshVersionBefore
        dshAfter   = $null
        profiles   = @()
        results    = @()
    }
    foreach ($p in $ProfilesToBackup) {
        $sub = Join-Path $dir $p.Name
        New-Item -ItemType Directory -Force -Path $sub | Out-Null
        $files = @()
        foreach ($f in @('package.json', 'pnpm-lock.yaml', 'cordis.patch.yml', 'pnpm-workspace.yaml', 'compatibility.json')) {
            $src = Join-Path $p.Dir $f
            if (Test-Path -LiteralPath $src) {
                Copy-Item -LiteralPath $src -Destination (Join-Path $sub $f) -Force
                $files += $f
            }
        }
        $manifest.profiles += [ordered]@{ name = $p.Name; dir = $p.Dir; files = $files }
    }
    ($manifest | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath (Join-Path $dir 'manifest.json') -Encoding utf8
    $script:BackupDir = $dir
    return $dir
}

function Save-BackupManifest {
    param([object[]]$ProfilePlans)
    if (-not $script:BackupDir) { return }
    $file = Join-Path $script:BackupDir 'manifest.json'
    try {
        $manifest = Get-Content -LiteralPath $file -Raw -Encoding utf8 | ConvertFrom-Json
        $manifest.dshAfter = $script:DshVersionAfter
        $results = @()
        foreach ($r in $script:Results) {
            $results += [ordered]@{ item = $r.Item; before = $r.Before; after = $r.After; status = $r.Status; note = $r.Note }
        }
        $manifest.results = $results
        $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $file -Encoding utf8
    } catch {
        Write-Warn "更新备份清单失败：$($_.Exception.Message)"
    }
}

function Get-BackupList {
    $root = Get-BackupRoot
    if (-not (Test-Path -LiteralPath $root)) { return @() }
    return @(Get-ChildItem -LiteralPath $root -Directory |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'manifest.json') } |
            Sort-Object Name -Descending)
}

function Invoke-Rollback {
    Write-Step '回滚'
    $backups = Get-BackupList
    if ($backups.Count -eq 0) {
        Write-Fail "没有找到备份目录（$((Get-BackupRoot))）"
        $script:Failures++
        return
    }
    $target = $null
    if (-not [string]::IsNullOrWhiteSpace($RollbackId)) {
        $target = $backups | Where-Object { $_.Name -eq $RollbackId -or $_.Name.StartsWith($RollbackId) } | Select-Object -First 1
    } else {
        $target = $backups | Select-Object -First 1
    }
    if ($null -eq $target) {
        Write-Fail "没有匹配的备份：$RollbackId"
        $script:Failures++
        return
    }

    $manifest = Get-Content -LiteralPath (Join-Path $target.FullName 'manifest.json') -Raw -Encoding utf8 | ConvertFrom-Json
    Write-Info "备份目录：$($target.FullName)"
    Write-Info "创建时间：$($manifest.createdAt)"
    Write-Info "备份时 dsh 本体：$($manifest.dshBefore)（当前：$($script:DshVersionBefore)）"
    foreach ($p in $manifest.profiles) { Write-Info "profile：$($p.name)  文件：$($p.files -join ', ')" }

    if (-not (Confirm-Action '确认恢复这些 profile 的清单并重新安装依赖？')) {
        Write-Info '已取消。'
        return
    }

    foreach ($p in $manifest.profiles) {
        $profileDir = Join-Path (Join-Path $script:DshHome 'profiles') $p.name
        $backupProfileDir = Join-Path $target.FullName $p.name
        if (-not (Test-Path -LiteralPath $profileDir)) { New-Item -ItemType Directory -Force -Path $profileDir | Out-Null }
        $restored = @()
        foreach ($f in $p.files) {
            $src = Join-Path $backupProfileDir $f
            if (Test-Path -LiteralPath $src) {
                Copy-Item -LiteralPath $src -Destination (Join-Path $profileDir $f) -Force
                $restored += $f
            }
        }
        # pnpm 会用“lockfile 的 mtime 是否晚于上次校验时间”做快速判断（已经是旧时间的
        # 备份文件会被误判为“已是最新”），所以恢复后显式刷新时间戳，强制重新安装。
        $now = [DateTime]::UtcNow
        foreach ($f in $restored) {
            $targetFile = Join-Path $profileDir $f
            if (Test-Path -LiteralPath $targetFile) { (Get-Item -LiteralPath $targetFile).LastWriteTimeUtc = $now }
        }
        Write-Info "$($p.name)：已恢复 $($restored -join ', ')"
        $r = Invoke-Native -Exe $script:Pnpm -Arguments @('install', '--frozen-lockfile', '--no-color') -WorkDir $profileDir -AllowFail
        if ($r.ExitCode -eq 0) {
            Write-Ok "$($p.name)：依赖已按恢复后的 lockfile 重新安装"
            Add-Result -Item "$($p.name)（回滚）" -Before '' -After '' -Status 'ok'
        } else {
            Write-Fail "$($p.name)：pnpm install 失败（exit $($r.ExitCode)），详见上方输出"
            Add-Result -Item "$($p.name)（回滚）" -Status 'failed' -Note 'pnpm install 失败'
            $script:Failures++
        }
    }
    if ($manifest.dshBefore -and $script:DshVersionBefore -and (Compare-SemVer $manifest.dshBefore $script:DshVersionBefore) -ne 0) {
        Write-Warn "插件已回滚，但 dsh 本体当前是 $($script:DshVersionBefore)（备份时为 $($manifest.dshBefore)）。"
        Write-Info "如需一并降级本体：npm install -g @deepseek-ai/dsh@$($manifest.dshBefore)"
    }
}

# ---------------------------------------------------------------------------
# 更新动作
# ---------------------------------------------------------------------------
function Invoke-CoreUpdate {
    param([string]$NpmPath, [string]$LatestVersion)
    Write-Step "更新 dsh 本体：$($script:DshVersionBefore) -> $LatestVersion"
    if ($DryRun) {
        Write-Skip '预览模式：将执行 npm install -g @deepseek-ai/dsh@latest'
        Add-Result -Item 'dsh 本体' -Before $script:DshVersionBefore -After $LatestVersion -Status 'planned'
        return $true
    }
    $r = Invoke-Native -Exe $NpmPath -Arguments @('install', '-g', '@deepseek-ai/dsh@latest', '--no-fund', '--no-audit', '--no-color') -AllowFail
    $after = Get-DshVersion -DshPath $script:Dsh
    if ($r.ExitCode -ne 0) {
        Write-Fail "npm 安装失败（exit $($r.ExitCode)）"
        Write-Info '若 DSH 正在运行，请完全退出后重试；已安装的旧版本可用下方命令恢复：'
        Write-Info "  npm install -g @deepseek-ai/dsh@$($script:DshVersionBefore)"
        Add-Result -Item 'dsh 本体' -Before $script:DshVersionBefore -After $after -Status 'failed' -Note "npm exit $($r.ExitCode)"
        $script:Failures++
        return $false
    }
    if ($null -eq $after) {
        Write-Fail 'npm 执行成功，但 `dsh --version` 无法解析出新版本，本体可能处于异常状态。'
        Write-Info "恢复命令：npm install -g @deepseek-ai/dsh@$($script:DshVersionBefore)"
        Add-Result -Item 'dsh 本体' -Before $script:DshVersionBefore -After '' -Status 'failed' -Note '版本校验失败'
        $script:Failures++
        return $false
    }
    Write-Ok "dsh 本体：$($script:DshVersionBefore) -> $after"
    if ($LatestVersion -and (Compare-SemVer $after $LatestVersion) -ne 0) {
        Write-Warn "安装后的版本 $after 与 registry 的 latest（$LatestVersion）不一致，请留意 npm 缓存或镜像同步。"
    }
    $script:DshVersionAfter = $after
    $script:CoreUpdated = $true
    Add-Result -Item 'dsh 本体' -Before $script:DshVersionBefore -After $after -Status 'updated'
    return $true
}

function Get-AllowVersionHints {
    param([object[]]$Output)
    $seen = @{}
    $hints = @()
    foreach ($line in $Output) {
        $text = ([string]$line).Trim()
        if ($text -match '^dsh: to accept the risk, run: (.*)$') {
            $command = $Matches[1].Trim()
            if (-not $seen.ContainsKey($command)) {
                $seen[$command] = $true
                $hints += $command
            }
        }
    }
    return $hints
}

function Repair-ProfileNodeModules {
    param([pscustomobject]$Plan)
    Write-Info '正在按回滚后的 lockfile 重新安装 node_modules …'
    $rep = Invoke-Native -Exe $script:Dsh -Arguments @('plugin', '--profile', $Plan.Name, 'install', '--frozen-lockfile', '--no-color') -AllowFail
    if ($rep.ExitCode -eq 0) {
        Write-Ok 'node_modules 已恢复到更新前的版本。'
        foreach ($c in $Plan.Candidates) {
            $v = Get-InstalledVersion -ProfileDir $Plan.Dir -PackageName $c.Name
            if ($null -ne $v) { Write-Info "$($c.Name)：$v" }
        }
    } else {
        Write-Warn "自动恢复 node_modules 失败（exit $($rep.ExitCode)）。请手动执行："
        Write-Info "  dsh plugin --profile $($Plan.Name) install"
    }
}

function Invoke-ProfilePluginUpdate {
    param([pscustomobject]$Plan, [bool]$AuditOnly)

    Write-Step "更新插件：profile $($Plan.Name)"
    if (-not $Plan.OutdatedOk) {
        Write-Warn '无法读取 outdated 信息（可能缺少 lockfile 或 registry 不可达），将直接执行 pnpm update。'
    }
    foreach ($c in $Plan.Candidates) {
        if ($null -eq $c.Target) {
            Write-Info "$($c.Name)：$($c.Installed) -> 最新（待查询）"
        } else {
            Write-Info "$($c.Name)：$($c.Installed) -> $($c.Target)"
        }
    }
    if ($AuditOnly -and $Plan.Candidates.Count -eq 0) {
        Write-Info '没有可更新的版本；本次运行用于在 dsh 升级后复查插件兼容性。'
    }

    if ($DryRun) {
        Write-Skip '预览模式：未执行更新'
        foreach ($c in $Plan.Candidates) {
            $status = 'planned'
            if ($null -eq $c.Target) { Add-Result -Item "$($Plan.Name) / $($c.Name)" -Before $c.Installed -Status $status -Note '版本未知' }
            else { Add-Result -Item "$($Plan.Name) / $($c.Name)" -Before $c.Installed -After $c.Target -Status $status }
        }
        foreach ($l in $Plan.Linked) {
            if (-not $UpdateLinked) {
                Add-Result -Item "$($Plan.Name) / $($l.Name)" -Note "本地依赖（$($l.Spec)），不随注册表更新" -Status 'skip'
            }
        }
        return
    }

    $dshArgs = @('plugin', '--profile', $Plan.Name, 'update', '--no-color')
    if (-not $WithinRanges) { $dshArgs += '--latest' }
    if (-not $Plan.AlwaysRun) {
        $names = @($Plan.Candidates | ForEach-Object { $_.Name })
        if ($names.Count -gt 0) { $dshArgs += $names }
    }

    $r = Invoke-Native -Exe $script:Dsh -Arguments $dshArgs -AllowFail
    $out = ($r.Output -join "`n")

    if ($r.ExitCode -ne 0) {
        $isIncompatible = ($out -match 'installation rejected') -or ($out -match 'is incompatible with dsh')
        if ($isIncompatible) {
            Write-Fail '新版本与当前 dsh 本体不兼容，dsh 已自动回滚到更新前的版本。'
            foreach ($h in (Get-AllowVersionHints -Output $r.Output)) { Write-Info $h }
            Write-Info '提示：本脚本默认先更新 dsh 本体；若本体已是最新，请等插件发布兼容版本，或按上面的 allow-version 命令显式授权（有崩溃/数据丢失风险）。'
            Add-Result -Item "$($Plan.Name)（插件）" -Status 'failed' -Note '插件与 dsh 不兼容，已自动回滚'
        } else {
            Write-Fail "插件更新失败（dsh plugin exit $($r.ExitCode)）"
            $tail = @($r.Output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 8)
            foreach ($t in $tail) { Write-Info $t }
            Add-Result -Item "$($Plan.Name)（插件）" -Status 'failed' -Note "dsh plugin exit $($r.ExitCode)"
            if ($out -match 'ERR_PNPM_' -or $out -match 'Ignored build scripts' -or $out -match 'approve-builds') {
                Write-Info "若日志提示 Ignored build scripts：按提示把包名加入 $($Plan.Dir)\pnpm-workspace.yaml 的 allowBuilds 后重跑。"
            }
        }
        if ($out -match 'node_modules could not be reinstalled') {
            Repair-ProfileNodeModules -Plan $Plan
        }
        $script:Failures++
        return
    }

    if ($out -match 'Ignored build scripts|approve-builds') {
        Write-Warn 'pnpm 拦截了部分依赖的构建脚本；相关插件可能功能不完整，请按提示在 pnpm-workspace.yaml 的 allowBuilds 中允许后重跑。'
    }
    if ($out -match 'profile startup denies it') {
        $lines = @($r.Output | Where-Object { $_ -match 'Plugin .+ is incompatible with dsh' } | ForEach-Object { $_.Trim() } | Select-Object -Unique)
        if ($lines.Count -gt 0) {
            Write-Warn '以下已安装插件与当前 dsh 不兼容，启动时会被拒绝加载：'
            foreach ($l in $lines) { Write-Info $l }
            foreach ($h in (Get-AllowVersionHints -Output $r.Output)) { Write-Info $h }
        }
    }

    $changed = 0
    foreach ($c in $Plan.Candidates) {
        $after = Get-InstalledVersion -ProfileDir $Plan.Dir -PackageName $c.Name
        if ($null -ne $after -and $after -ne $c.Installed) {
            Write-Ok "$($c.Name)：$($c.Installed) -> $after"
            Add-Result -Item "$($Plan.Name) / $($c.Name)" -Before $c.Installed -After $after -Status 'updated'
            $changed++
        } else {
            Write-Warn "$($c.Name)：版本未变化（仍是 $after）"
            Add-Result -Item "$($Plan.Name) / $($c.Name)" -Before $c.Installed -After $after -Status 'unchanged' -Note 'pnpm 未升级'
        }
    }
    if ($changed -eq 0 -and $Plan.Candidates.Count -eq 0) {
        Write-Ok '插件均已是可选的最新版本。'
    }
    foreach ($l in $Plan.Linked) {
        if ($UpdateLinked) {
            Write-Info "$($l.Name)：本地依赖（$($l.Spec)），稍后执行 git pull"
        } else {
            Write-Skip "$($l.Name)：本地依赖（$($l.Spec)），不随注册表更新"
            Add-Result -Item "$($Plan.Name) / $($l.Name)" -Note "本地依赖（$($l.Spec)）" -Status 'skip'
        }
    }
}

function Invoke-LinkedUpdate {
    param([object[]]$Plans)
    if (-not $UpdateLinked) { return }
    if ($null -eq $script:Git) {
        Write-Warn '未找到 git，跳过本地 link: 插件更新。'
        return
    }
    Write-Step '更新本地 link: 插件（git pull --ff-only）'
    foreach ($plan in $Plans) {
        foreach ($l in $plan.Linked) {
            $spec = [string]$l.Spec
            if (-not $spec.StartsWith('link:')) {
                Write-Skip "$($plan.Name) / $($l.Name)：$spec 不是 link: 依赖，跳过"
                continue
            }
            $rel = $spec.Substring(5)
            $dir = $rel
            if (-not [System.IO.Path]::IsPathRooted($rel)) { $dir = Join-Path $plan.Dir $rel }
            if (-not (Test-Path -LiteralPath $dir)) {
                Write-Warn "$($plan.Name) / $($l.Name)：目录不存在 -> $dir"
                continue
            }
            if (-not (Test-Path -LiteralPath (Join-Path $dir '.git'))) {
                Write-Skip "$($plan.Name) / $($l.Name)：不是 git 仓库，跳过"
                continue
            }
            $headBefore = (Invoke-Native -Exe $script:Git -Arguments @('-C', $dir, 'rev-parse', '--short', 'HEAD') -Quiet -AllowFail).Output
            if ($DryRun) {
                Write-Info "$($plan.Name) / $($l.Name)：将执行 git pull --ff-only（$dir）"
                continue
            }
            $r = Invoke-Native -Exe $script:Git -Arguments @('-C', $dir, 'pull', '--ff-only', '--no-rebase') -AllowFail
            $headAfter = (Invoke-Native -Exe $script:Git -Arguments @('-C', $dir, 'rev-parse', '--short', 'HEAD') -Quiet -AllowFail).Output
            if ($r.ExitCode -eq 0) {
                if (($headBefore -join '') -ne ($headAfter -join '')) {
                    Write-Ok "$($l.Name)：$($headBefore -join '') -> $($headAfter -join '')"
                    Add-Result -Item "$($plan.Name) / $($l.Name)（git pull）" -Before ($headBefore -join '') -After ($headAfter -join '') -Status 'updated'
                } else {
                    Write-Ok "$($l.Name)：已是最新（$($headAfter -join '')）"
                    Add-Result -Item "$($plan.Name) / $($l.Name)（git pull）" -After ($headAfter -join '') -Status 'unchanged'
                }
            } else {
                Write-Fail "$($l.Name)：git pull 失败（exit $($r.ExitCode)），可能有本地改动或已分叉，请手动处理。"
                Add-Result -Item "$($plan.Name) / $($l.Name)（git pull）" -Status 'failed' -Note 'git pull 失败'
                $script:Failures++
            }
        }
    }
}

function Test-ProfileComposition {
    param([object[]]$Plans)
    $verify = @($Plans | Where-Object { -not $_.Skipped })
    if ($verify.Count -eq 0) { return }
    Write-Step '校验 profile 配置能否正常组合'
    foreach ($plan in $verify) {
        if ($DryRun) { Write-Skip "$($plan.Name)：预览模式跳过"; continue }
        $r = Invoke-Native -Exe $script:Dsh -Arguments @('--profile', $plan.Name, '--dump-config') -Quiet -AllowFail
        if ($r.ExitCode -eq 0) {
            Write-Ok "$($plan.Name)：--dump-config 正常"
        } else {
            Write-Fail "$($plan.Name)：--dump-config 失败（exit $($r.ExitCode)）"
            $tail = @($r.Output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 15)
            foreach ($t in $tail) { Write-Info $t }
            Write-Info "可用 -Rollback 恢复更新前的插件版本。"
            $script:Failures++
            Add-Result -Item "$($plan.Name)（配置校验）" -Status 'failed' -Note '--dump-config 失败'
        }
    }
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { }

$script:DshHome = Resolve-DshHomePath
$script:Pnpm = Resolve-Executable 'pnpm'
$script:Npm = Resolve-Executable 'npm'
$script:Dsh = Resolve-Executable 'dsh'
$script:Git = Resolve-Executable 'git'

Write-Line ''
Write-Line "DeepSeek Harness 更新脚本 v$($script:ScriptVersion)" 'Cyan'
Write-Line "  DSH_HOME   : $($script:DshHome)"
$modeText = '实际更新'
if ($DryRun) { $modeText = '预览（不做修改）' }
$rangeText = 'latest（跨 semver 范围）'
if ($WithinRanges) { $rangeText = '范围内最新' }
Write-Line "  模式       : $modeText / 范围: $Scope / 版本策略: $rangeText"
Write-Line "  dsh        : $(if ($script:Dsh) { $script:Dsh } else { '未找到' })"
Write-Line "  pnpm       : $(if ($script:Pnpm) { $script:Pnpm } else { '未找到' })"
Write-Line "  npm        : $(if ($script:Npm) { $script:Npm } else { '未找到' })"

if ($null -eq $script:Dsh) {
    Write-Fail '未找到 dsh 命令。请先安装：npm install -g @deepseek-ai/dsh'
    exit 1
}
if ($null -eq $script:Pnpm) {
    Write-Fail '未找到 pnpm 命令。请先安装 pnpm（npm install -g pnpm）后再运行。'
    exit 1
}
if ($Scope -ne 'Plugins' -and $null -eq $script:Npm) {
    Write-Fail '未找到 npm 命令，无法更新 dsh 本体。'
    exit 1
}
if ($UpdateLinked -and $null -eq $script:Git) {
    Write-Warn '未找到 git，-UpdateLinked 将被忽略。'
}

$script:DshVersionBefore = Get-DshVersion -DshPath $script:Dsh
if ($null -eq $script:DshVersionBefore) {
    Write-Fail '无法解析 `dsh --version`，请确认 dsh 安装完好。'
    exit 1
}
$script:DshVersionAfter = $script:DshVersionBefore
Write-Line "  当前版本   : dsh $($script:DshVersionBefore)"

# 回滚模式
if ($Rollback) {
    Invoke-Rollback
    Write-Line ''
    if ($script:Failures -gt 0) { Write-Line '回滚存在失败项，请检查上方输出。' 'Red'; exit 1 }
    Write-Line '回滚完成。' 'Green'
    exit 0
}

# 运行中的 DSH
$procInfo = Get-DshProcessInfo
if (-not $procInfo.Supported) {
    Write-Warn '无法枚举进程（被沙箱/权限限制），不能确认 DSH 是否在运行；更新本体前请自行确认已退出 DSH。'
} elseif ($procInfo.Processes.Count -gt 0) {
    $pids = ($procInfo.Processes | ForEach-Object { $_.Id }) -join ', '
    Write-Warn "检测到 DSH 正在运行（node PID: $pids）。"
    if ($DryRun) {
        Write-Info '预览模式不修改任何文件，可继续；真正更新前请完全退出 DSH。'
    } elseif ($SkipIfRunning) {
        Write-Info '按 -SkipIfRunning 跳过本次更新。'
        exit 0
    } elseif ($Force) {
        Write-Warn '已指定 -Force，继续。更新本体可能因文件占用失败。'
    } else {
        if ($Scope -eq 'Plugins') {
            if (-not (Confirm-Action '插件更新会让运行中的 DSH 重新加载模块，继续？建议先退出 DSH。')) {
                Write-Info '已取消。'
                exit 0
            }
        } else {
            Write-Fail '请先完全退出 DSH 再运行（更新本体需要替换被运行中进程占用的文件）。'
            Write-Info '只更新插件可加 -Scope Plugins；自动化的定时任务可加 -SkipIfRunning。'
            exit 1
        }
    }
}

# 收集 profile
$selectedProfiles = Get-ProfileInfos -Requested $Profile
if ($selectedProfiles.Count -eq 0) {
    if ($Scope -ne 'Core') { Write-Warn '没有发现任何带 package.json 的 profile。' }
}

# 本体计划
$latestCore = $null
$corePlan = $false
if ($Scope -ne 'Plugins') {
    $latestCore = Get-LatestDshVersion -NpmPath $script:Npm
    if ($null -eq $latestCore) {
        Write-Fail '无法查询 @deepseek-ai/dsh 的 latest 版本（registry 不可达或 npm 配置异常）。'
        exit 1
    }
    $cmp = Compare-SemVer $latestCore $script:DshVersionBefore
    if ($cmp -gt 0) { $corePlan = $true }
    elseif ($cmp -lt 0) {
        Write-Info "registry 的 latest（$latestCore）低于已安装版本（$($script:DshVersionBefore)），为避免降级将跳过本体更新。"
    }
}

# 插件计划
$plans = New-Object System.Collections.ArrayList
if ($Scope -ne 'Core') {
    foreach ($p in $selectedProfiles) {
        $plan = New-ProfilePlan -ProfileInfo $p
        [void]$plans.Add($plan)
    }
}

# 打印计划
Write-Step '更新计划'
$hasWork = $false
if ($Scope -ne 'Plugins') {
    if ($corePlan) {
        $hasWork = $true
        Write-Info "dsh 本体：$($script:DshVersionBefore) -> $latestCore"
    } else {
        Write-Skip "dsh 本体：已是最新（$($script:DshVersionBefore)）"
        Add-Result -Item 'dsh 本体' -Before $script:DshVersionBefore -After $script:DshVersionBefore -Status 'unchanged'
    }
}
foreach ($plan in $plans) {
    if ($plan.Skipped) {
        Write-Skip "$($plan.Name)：$($plan.Reason)"
        Add-Result -Item $plan.Name -Status 'skip' -Note $plan.Reason
        continue
    }
    if ($plan.Candidates.Count -gt 0) {
        $hasWork = $true
        foreach ($c in $plan.Candidates) {
            if ($null -eq $c.Target) {
                Write-Info "$($plan.Name) / $($c.Name)：$($c.Installed) -> 最新（待查询）"
            } else {
                Write-Info "$($plan.Name) / $($c.Name)：$($c.Installed) -> $($c.Target)"
            }
        }
    } elseif ($plan.OutdatedOk) {
        Write-Skip "$($plan.Name)：$($plan.Registry.Count) 个注册表插件均已是最新"
        Add-Result -Item $plan.Name -Status 'unchanged' -Note '插件均已最新'
    }
    if ($plan.Linked.Count -gt 0) {
        foreach ($l in $plan.Linked) {
            if ($UpdateLinked) { Write-Info "$($plan.Name) / $($l.Name)：本地 link 包，将 git pull（$($l.Spec)）" }
            else { Write-Info "$($plan.Name) / $($l.Name)：本地 link 包（$($l.Spec)），跳过" }
        }
    }
}
if (-not $hasWork) {
    Write-Line ''
    Write-Line '所有内容都已是最新，无需更新。' 'Green'
    if ($script:Results.Count -gt 0) {
        Write-Step '结果'
        foreach ($r in $script:Results) {
            $text = "  $($r.Item)"
            if ($r.Before -or $r.After) { $text += "  $($r.Before) -> $($r.After)" }
            Write-Line $text
        }
    }
    exit 0
}

# 确认 + 备份
Write-Line ''
$backupRoot = Get-BackupRoot
if (-not $DryRun -and -not $NoBackup) { Write-Info "更新前备份到：$backupRoot\<时间戳>\" }
if (-not (Confirm-Action '开始更新？')) {
    Write-Info '已取消。'
    exit 0
}

if (-not $DryRun -and -not $NoBackup) {
    $toBackup = @($plans | Where-Object { -not $_.Skipped } | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Dir = $_.Dir } })
    if ($Scope -ne 'Plugins' -and $toBackup.Count -eq 0) {
        Write-Info '本次只更新本体，无需备份 profile。'
    } elseif ($toBackup.Count -eq 0) {
        Write-Info '没有需要备份的 profile。'
    } else {
        $dir = New-Backup -ProfilesToBackup $toBackup
        Write-Ok "已备份 $($toBackup.Count) 个 profile：$dir"
    }
}

$allOk = $true

# 1) 本体
if ($Scope -ne 'Plugins' -and $corePlan) {
    $ok = Invoke-CoreUpdate -NpmPath $script:Npm -LatestVersion $latestCore
    if (-not $ok) {
        $allOk = $false
        Write-Line ''
        Write-Fail '本体更新失败，已中止后续插件更新（避免插件与旧本体不兼容）。'
        Save-BackupManifest -ProfilePlans $plans
        Save-Log -Path (Join-Path (Get-BackupRoot) ("logs\update-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log'))
        exit 1
    }
}

# 2) 插件
if ($Scope -ne 'Core') {
    foreach ($plan in $plans) {
        if ($plan.Skipped) { continue }
        $run = ($plan.Candidates.Count -gt 0) -or $plan.AlwaysRun -or ($script:CoreUpdated -and $plan.Registry.Count -gt 0)
        if (-not $run) { continue }
        $auditOnly = ($plan.Candidates.Count -eq 0)
        Invoke-ProfilePluginUpdate -Plan $plan -AuditOnly $auditOnly
    }

    # 3) link: 本地插件
    if ($UpdateLinked) { Invoke-LinkedUpdate -Plans $plans }
}

# 4) 校验
Test-ProfileComposition -Plans $plans

# 5) 汇总
$script:DshVersionAfter = Get-DshVersion -DshPath $script:Dsh
Write-Step '结果汇总'
foreach ($r in $script:Results) {
    $icon = '[OK]'
    $color = 'Green'
    if ($r.Status -eq 'failed') { $icon = '[FAIL]'; $color = 'Red' }
    elseif ($r.Status -eq 'skip') { $icon = '[SKIP]'; $color = 'DarkGray' }
    elseif ($r.Status -eq 'unchanged') { $icon = '[SAME]'; $color = 'DarkGray' }
    elseif ($r.Status -eq 'planned') { $icon = '[PLAN]'; $color = 'Cyan' }
    $text = "  $icon $($r.Item)"
    if ($r.Before -or $r.After) {
        $b = $r.Before
        $a = $r.After
        if ([string]::IsNullOrEmpty($b)) { $b = '?' }
        if ([string]::IsNullOrEmpty($a)) { $a = '?' }
        $text += "  $b -> $a"
    }
    if ($r.Note) { $text += "  （$($r.Note)）" }
    Write-Line $text $color
}

Write-Line ''
if ($script:DshVersionAfter -ne $script:DshVersionBefore) {
    Write-Info "dsh 本体当前版本：$($script:DshVersionBefore) -> $($script:DshVersionAfter)"
}
if ($DryRun) {
    Write-Line '预览完成，未做任何修改。去掉 -DryRun 即可实际更新。' 'Cyan'
} elseif ($script:Failures -gt 0) {
    Write-Line '更新过程中有失败项，请检查上方输出。' 'Red'
} else {
    Write-Line '更新完成。请重启 DSH 使插件与本体变更完全生效。' 'Green'
}
if ($script:BackupDir) {
    Write-Info "备份目录：$($script:BackupDir)"
    Write-Info "回滚命令：pwsh -NoProfile -File `"$($PSCommandPath)`" -Rollback"
}

if ($script:BackupDir) {
    Save-BackupManifest -ProfilePlans $plans
    Save-Log -Path (Join-Path $script:BackupDir 'update.log')
} elseif ($DryRun) {
    # 预览模式不落盘日志
} else {
    Save-Log -Path (Join-Path (Get-BackupRoot) ("logs\update-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log'))
}

if ($script:Failures -gt 0) { exit 1 }
exit 0
