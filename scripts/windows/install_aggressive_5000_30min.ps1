#requires -Version 5.1
$ErrorActionPreference = "Stop"

function New-CompatibleTaskSettings {
    param(
        [Parameter(Mandatory = $true)]
        [TimeSpan]$ExecutionTimeLimit
    )

    $SettingsArgs = @{
        StartWhenAvailable = $true
        MultipleInstances = "IgnoreNew"
        ExecutionTimeLimit = $ExecutionTimeLimit
        Hidden = $true
        Priority = 7
    }

    # 不同 Windows / ScheduledTasks 模块版本支持的电池参数可能不同。
    $Supported = (Get-Command New-ScheduledTaskSettingsSet).Parameters
    if ($Supported.ContainsKey("AllowStartIfOnBatteries")) {
        $SettingsArgs["AllowStartIfOnBatteries"] = $true
    }
    if ($Supported.ContainsKey("DontStopIfGoingOnBatteries")) {
        $SettingsArgs["DontStopIfGoingOnBatteries"] = $true
    }

    return New-ScheduledTaskSettingsSet @SettingsArgs
}

$InstallDir = Join-Path $env:LOCALAPPDATA "ClashCloudflareDynamic"
$Script = Join-Path $InstallDir "dynamic_selector.py"
$OldTask = "Clash Cloudflare Dynamic Discovery 30min"
$LightTask = "Clash Cloudflare Light Scan 2h"
$DeepTask = "Clash Cloudflare Deep Scan 5000 12h"
$LegacyLightTask = "Clash Cloudflare Light Scan 30min"
$LegacyDeepTask = "Clash Cloudflare Deep Scan 5000 6h"
$HealthTask = "Clash Cloudflare Health Monitor 30min"
$AggressiveTask = "Clash Cloudflare Deep Scan 5000 30min"

if (-not (Test-Path $Script)) {
    throw "请先运行 install_hybrid_5000.ps1 完成程序安装。"
}

$PythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue
$Python = if ($PythonCommand) { $PythonCommand.Source } else { $null }
if (-not $Python) {
    $PyLauncherCommand = Get-Command py.exe -ErrorAction SilentlyContinue
    if ($PyLauncherCommand) {
        $ResolvedPythonLines = @(
            & $PyLauncherCommand.Source -3 -c "import sys; print(sys.executable)" 2>$null
        )
        if ($LASTEXITCODE -eq 0) {
            $Python = [string]($ResolvedPythonLines |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Select-Object -Last 1)
        }
    }
}
if (-not $Python -or -not (Test-Path -LiteralPath $Python -PathType Leaf)) {
    throw "未找到可供计划任务使用的 Python 3.10+ 解释器。"
}
$VersionProbeLines = @(
    & $Python -c "import sys; print('.'.join(map(str, sys.version_info[:3])))" 2>$null
)
$VersionProbeExitCode = $LASTEXITCODE
$VersionText = [string]($VersionProbeLines |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Select-Object -Last 1)
$PythonVersion = $null
if ($VersionProbeExitCode -ne 0 -or
    -not [Version]::TryParse($VersionText, [ref]$PythonVersion) -or
    $PythonVersion -lt [Version]"3.10") {
    throw "计划任务 Python 解释器不可用或版本低于 3.10：$Python ($VersionText)"
}
$Pythonw = Join-Path (Split-Path -Parent $Python) "pythonw.exe"
if (-not (Test-Path -LiteralPath $Pythonw -PathType Leaf)) {
    throw "未找到与 python.exe 同目录的 pythonw.exe；为保证后台运行，未修改现有任务。"
}
$Arguments = "`"$Script`""

$BackupRoot = Join-Path $InstallDir "backups"
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$BackupBaseName = "aggressive-mode-$Stamp"
$BackupDir = Join-Path $BackupRoot $BackupBaseName
$BackupSuffix = 1
while (Test-Path -LiteralPath $BackupDir) {
    $BackupDir = Join-Path $BackupRoot "$BackupBaseName-$BackupSuffix"
    $BackupSuffix += 1
}
New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
$ExistingTaskNames = @()
try {
    $ExistingTasks = @(Get-ScheduledTask -ErrorAction Stop)
    $ExistingTaskNames = @($ExistingTasks | ForEach-Object { $_.TaskName })
    @(
        @{ TaskName = $OldTask; Name = "old-task.xml" },
        @{ TaskName = $LightTask; Name = "light-task.xml" },
        @{ TaskName = $DeepTask; Name = "deep-task.xml" },
        @{ TaskName = $LegacyLightTask; Name = "legacy-light-task.xml" },
        @{ TaskName = $LegacyDeepTask; Name = "legacy-deep-task.xml" },
        @{ TaskName = $HealthTask; Name = "health-task.xml" },
        @{ TaskName = $AggressiveTask; Name = "aggressive-task.xml" }
    ) | ForEach-Object {
        if ($ExistingTaskNames -contains $_.TaskName) {
            $TaskXml = Export-ScheduledTask -TaskName $_.TaskName -ErrorAction Stop
            if ([string]::IsNullOrWhiteSpace([string]$TaskXml)) {
                throw "计划任务备份为空：$($_.TaskName)"
            }
            Set-Content -LiteralPath (Join-Path $BackupDir $_.Name) -Value $TaskXml -Encoding Unicode
        }
    }
} catch {
    Remove-Item -LiteralPath $BackupDir -Recurse -Force -ErrorAction SilentlyContinue
    throw
}

$Action = New-ScheduledTaskAction `
    -Execute $Pythonw `
    -Argument $Arguments `
    -WorkingDirectory $InstallDir
$Trigger = New-ScheduledTaskTrigger `
    -Once `
    -At ((Get-Date).AddMinutes(3)) `
    -RepetitionInterval (New-TimeSpan -Minutes 30) `
    -RepetitionDuration (New-TimeSpan -Days 3650)
$TaskSettings = New-CompatibleTaskSettings -ExecutionTimeLimit (New-TimeSpan -Minutes 150)

try {
    Register-ScheduledTask `
        -TaskName $AggressiveTask `
        -Action $Action `
        -Trigger $Trigger `
        -Settings $TaskSettings `
        -Description "激进模式：每 30 分钟随机抽样 5000 个 Cloudflare IPv4。每天约 24 万次 TCP 探测。" `
        -Force `
        -ErrorAction Stop | Out-Null

    foreach ($TaskName in @($OldTask, $LightTask, $DeepTask, $LegacyLightTask, $LegacyDeepTask)) {
        if ($ExistingTaskNames -notcontains $TaskName) {
            continue
        }
        $TaskToRemove = @(
            $ExistingTasks | Where-Object { $_.TaskName -eq $TaskName }
        )[0]
        if ([string]$TaskToRemove.State -eq "Running") {
            Stop-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        }
        Unregister-ScheduledTask `
            -TaskName $TaskName `
            -Confirm:$false `
            -ErrorAction Stop
    }
    $RemainingTaskNames = @(
        Get-ScheduledTask -ErrorAction Stop |
            ForEach-Object { [string]$_.TaskName }
    )
    foreach ($TaskName in @($OldTask, $LightTask, $DeepTask, $LegacyLightTask, $LegacyDeepTask)) {
        if ($RemainingTaskNames -contains $TaskName) {
            throw "混合模式任务删除后仍然存在：$TaskName"
        }
    }
} catch {
    $MigrationError = $_.Exception.Message
    $RollbackErrors = New-Object System.Collections.Generic.List[string]
    foreach ($TaskSpec in @(
        @{ TaskName = $OldTask; Name = "old-task.xml" },
        @{ TaskName = $LightTask; Name = "light-task.xml" },
        @{ TaskName = $DeepTask; Name = "deep-task.xml" },
        @{ TaskName = $LegacyLightTask; Name = "legacy-light-task.xml" },
        @{ TaskName = $LegacyDeepTask; Name = "legacy-deep-task.xml" },
        @{ TaskName = $AggressiveTask; Name = "aggressive-task.xml" }
    )) {
        $TaskName = $TaskSpec.TaskName
        try {
            if ($ExistingTaskNames -contains $TaskName) {
                $TaskBackupPath = Join-Path $BackupDir $TaskSpec.Name
                if (-not (Test-Path -LiteralPath $TaskBackupPath -PathType Leaf)) {
                    throw "缺少原任务备份：$TaskBackupPath"
                }
                $TaskXml = Get-Content -LiteralPath $TaskBackupPath -Raw -Encoding Unicode
                Register-ScheduledTask `
                    -TaskName $TaskName `
                    -Xml $TaskXml `
                    -Force `
                    -ErrorAction Stop | Out-Null
            } else {
                $CurrentTaskNames = @(
                    Get-ScheduledTask -ErrorAction Stop |
                        ForEach-Object { [string]$_.TaskName }
                )
                if ($CurrentTaskNames -contains $TaskName) {
                    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
                    Unregister-ScheduledTask `
                        -TaskName $TaskName `
                        -Confirm:$false `
                        -ErrorAction Stop
                }
            }
        } catch {
            [void]$RollbackErrors.Add("$TaskName：$($_.Exception.Message)")
        }
    }
    if ($RollbackErrors.Count -gt 0) {
        throw "激进模式迁移失败：$MigrationError；回滚未完全成功：$($RollbackErrors -join '；')"
    }
    throw "激进模式迁移失败，已恢复原调度：$MigrationError"
}

Write-Host ""
Write-Host "已启用激进模式：每 30 分钟抽样 5000 个 IP。" -ForegroundColor Yellow
Write-Host "计划任务解释器：$Pythonw（Python $PythonVersion，隐藏窗口）"
Write-Host "原任务定义已备份到：$BackupDir"
Write-Host "注意：每天约 24 万次 TCP 连接，可能增加路由器和网络负担。"
