#requires -Version 5.1
param(
    [switch]$Check
)

$ErrorActionPreference = "Stop"

function Set-HealthProperty($Object, [string]$Name, $Value) {
    if ($Object.PSObject.Properties.Name -contains $Name) {
        $Object.$Name = $Value
    } else {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Write-HealthJsonAtomic([string]$Path, $Value) {
    $Parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $Parent -Force | Out-Null
    $TempPath = "$Path.$PID.tmp"
    $ReplaceBackupPath = "$Path.$PID.replace.bak"
    $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    try {
        $Json = $Value | ConvertTo-Json -Depth 20
        [IO.File]::WriteAllText($TempPath, $Json, $Utf8NoBom)
        if (Test-Path -LiteralPath $Path) {
            [IO.File]::Replace($TempPath, $Path, $ReplaceBackupPath)
        } else {
            [IO.File]::Move($TempPath, $Path)
        }
    } finally {
        foreach ($CleanupPath in @($TempPath, $ReplaceBackupPath)) {
            if (Test-Path -LiteralPath $CleanupPath) {
                Remove-Item -LiteralPath $CleanupPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function New-HealthState([DateTimeOffset]$Now) {
    return [PSCustomObject]@{
        schema_version = 1
        installed_at = $Now.ToString("o")
        last_success = [PSCustomObject]@{
            light = $null
            deep = $null
        }
        active_issue_keys = @()
        active_mode = $null
        mode_changed_at = $Now.ToString("o")
        last_check = $null
    }
}

function Read-HealthState([string]$Path, [DateTimeOffset]$Now) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return New-HealthState $Now
    }
    try {
        $Text = [IO.File]::ReadAllText($Path)
        if ([string]::IsNullOrWhiteSpace($Text)) {
            throw "状态文件为空"
        }
        $State = $Text | ConvertFrom-Json
        if ($null -eq $State.last_success) {
            Set-HealthProperty $State "last_success" ([PSCustomObject]@{})
        }
        foreach ($Mode in @("light", "deep")) {
            if ($State.last_success.PSObject.Properties.Name -notcontains $Mode) {
                Set-HealthProperty $State.last_success $Mode $null
            }
        }
        foreach ($Property in @(
            "installed_at",
            "active_issue_keys",
            "active_mode",
            "mode_changed_at",
            "last_check"
        )) {
            if ($State.PSObject.Properties.Name -notcontains $Property) {
                $Default = if ($Property -eq "installed_at") {
                    $Now.ToString("o")
                } elseif ($Property -eq "active_issue_keys") {
                    @()
                } elseif ($Property -eq "mode_changed_at") {
                    $Now.ToString("o")
                } else {
                    $null
                }
                Set-HealthProperty $State $Property $Default
            }
        }
        return $State
    } catch {
        return New-HealthState $Now
    }
}

function ConvertTo-HealthTime($Value) {
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }
    $Parsed = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse(
            [string]$Value,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AllowWhiteSpaces,
            [ref]$Parsed
        )) {
        return $Parsed
    }
    return $null
}

function Get-HealthRunStatus([string]$InstallRoot, [string]$Mode) {
    $FileName = if ($Mode -eq "light") {
        "last_run_light.json"
    } else {
        "last_run_deep.json"
    }
    $Path = Join-Path (Join-Path $InstallRoot "logs") $FileName
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    try {
        $Text = [IO.File]::ReadAllText($Path)
        if ([string]::IsNullOrWhiteSpace($Text)) {
            throw "心跳文件为空"
        }
        $Payload = $Text | ConvertFrom-Json
        $Status = [string]$Payload.status
        $PayloadMode = [string]$Payload.mode
        $CompletedAt = ConvertTo-HealthTime $Payload.completed_at
        if ($Status -notin @("success", "skipped", "failed")) {
            throw "未知状态：$Status"
        }
        if ($PayloadMode -ne $Mode) {
            throw "模式不匹配：$PayloadMode"
        }
        if ($null -eq $CompletedAt) {
            throw "完成时间无效"
        }
        return [PSCustomObject]@{
            Valid = $true
            Path = $Path
            Status = $Status
            CompletedAt = $CompletedAt
            Reason = [string]$Payload.reason
            ScanSummary = $Payload.scan_summary
            Error = $null
        }
    } catch {
        return [PSCustomObject]@{
            Valid = $false
            Path = $Path
            Status = ""
            CompletedAt = $null
            Reason = ""
            ScanSummary = $null
            Error = $_.Exception.Message
        }
    }
}

function Format-HealthDuration([TimeSpan]$Duration) {
    if ($Duration.TotalHours -ge 1) {
        return ("{0:F1} 小时" -f $Duration.TotalHours)
    }
    return ("{0:F0} 分钟" -f [Math]::Max(0, $Duration.TotalMinutes))
}

function Format-TaskResultCode($Value) {
    try {
        $NumericValue = [int64]$Value
        $Unsigned = [uint32]($NumericValue -band 0xFFFFFFFFL)
        return ("{0} / 0x{1:X8}" -f $NumericValue, $Unsigned)
    } catch {
        return [string]$Value
    }
}

function Test-HealthPythonInterpreter([string]$PythonwPath) {
    $PythonPath = Join-Path (Split-Path -Parent $PythonwPath) "python.exe"
    if (-not (Test-Path -LiteralPath $PythonPath -PathType Leaf)) {
        return [PSCustomObject]@{
            Valid = $false
            Version = $null
            Error = "同目录 python.exe 不存在：$PythonPath"
        }
    }

    $Process = $null
    try {
        $StartInfo = New-Object Diagnostics.ProcessStartInfo
        $StartInfo.FileName = $PythonPath
        $StartInfo.Arguments = '-c "import sys; print(\".\".join(map(str, sys.version_info[:3])))"'
        $StartInfo.UseShellExecute = $false
        $StartInfo.CreateNoWindow = $true
        $StartInfo.RedirectStandardOutput = $true
        $StartInfo.RedirectStandardError = $true
        $Process = New-Object Diagnostics.Process
        $Process.StartInfo = $StartInfo
        if (-not $Process.Start()) {
            throw "进程启动失败"
        }
        $StandardOutput = $Process.StandardOutput.ReadToEnd()
        $StandardError = $Process.StandardError.ReadToEnd()
        if (-not $Process.WaitForExit(10000)) {
            try { $Process.Kill() } catch {}
            throw "版本检查超过 10 秒"
        }
        $VersionText = [string](@(
            $StandardOutput -split "`r?`n" |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Select-Object -Last 1
        )[0])
        $Version = $null
        if ($Process.ExitCode -ne 0 -or
            -not [Version]::TryParse($VersionText, [ref]$Version)) {
            throw "版本输出无效（退出码 $($Process.ExitCode)）：$VersionText $StandardError"
        }
        if ($Version -lt [Version]"3.10") {
            throw "Python $Version 低于最低要求 3.10"
        }
        return [PSCustomObject]@{
            Valid = $true
            Version = $Version.ToString()
            Error = $null
        }
    } catch {
        return [PSCustomObject]@{
            Valid = $false
            Version = $null
            Error = $_.Exception.Message
        }
    } finally {
        if ($null -ne $Process) {
            $Process.Dispose()
        }
    }
}

function Get-HealthTaskSnapshots([object[]]$Definitions) {
    $Snapshots = @()
    $PythonProbeCache = @{}
    foreach ($Definition in $Definitions) {
        try {
            $Task = Get-ScheduledTask -TaskName $Definition.TaskName -ErrorAction Stop
            if ($null -eq $Task) {
                throw "任务不存在"
            }
            $Task = @($Task)[0]
            $Info = Get-ScheduledTaskInfo -TaskName $Definition.TaskName -ErrorAction Stop
            $Action = @($Task.Actions)[0]
            $Execute = [Environment]::ExpandEnvironmentVariables([string]$Action.Execute).Trim('"')
            $ProbeKey = $Execute.ToLowerInvariant()
            if (-not $PythonProbeCache.ContainsKey($ProbeKey)) {
                $PythonProbeCache[$ProbeKey] = Test-HealthPythonInterpreter $Execute
            }
            $PythonProbe = $PythonProbeCache[$ProbeKey]
            $Enabled = $true
            if ($null -ne $Task.Settings -and
                $Task.Settings.PSObject.Properties.Name -contains "Enabled") {
                $Enabled = [bool]$Task.Settings.Enabled
            }
            $Snapshots += [PSCustomObject]@{
                Mode = $Definition.Mode
                Label = $Definition.Label
                TaskName = $Definition.TaskName
                MaxAge = $Definition.MaxAge
                Exists = $true
                Enabled = $Enabled
                State = [string]$Task.State
                Execute = [string]$Action.Execute
                Arguments = [string]$Action.Arguments
                WorkingDirectory = [string]$Action.WorkingDirectory
                PythonValid = [bool]$PythonProbe.Valid
                PythonVersion = $PythonProbe.Version
                PythonError = $PythonProbe.Error
                LastRunTime = $Info.LastRunTime
                LastTaskResult = $Info.LastTaskResult
                QueryError = $null
            }
        } catch {
            $Snapshots += [PSCustomObject]@{
                Mode = $Definition.Mode
                Label = $Definition.Label
                TaskName = $Definition.TaskName
                MaxAge = $Definition.MaxAge
                Exists = $false
                Enabled = $false
                State = ""
                Execute = ""
                Arguments = ""
                WorkingDirectory = ""
                PythonValid = $false
                PythonVersion = $null
                PythonError = "任务无法读取，未执行 Python 版本检查"
                LastRunTime = $null
                LastTaskResult = $null
                QueryError = $_.Exception.Message
            }
        }
    }
    return $Snapshots
}

function Get-HealthTaskConfiguration {
    $AggressiveTaskName = "Clash Cloudflare Deep Scan 5000 30min"
    $LightTaskName = "Clash Cloudflare Light Scan 30min"
    $DeepTaskName = "Clash Cloudflare Deep Scan 5000 6h"
    $AggressiveExists = $null -ne (
        Get-ScheduledTask -TaskName $AggressiveTaskName -ErrorAction SilentlyContinue
    )
    $LightExists = $null -ne (
        Get-ScheduledTask -TaskName $LightTaskName -ErrorAction SilentlyContinue
    )
    $DeepExists = $null -ne (
        Get-ScheduledTask -TaskName $DeepTaskName -ErrorAction SilentlyContinue
    )
    if ($AggressiveExists -and -not $LightExists -and -not $DeepExists) {
        return [PSCustomObject]@{
            ActiveMode = "aggressive"
            ModeConflict = $false
            Definitions = @([PSCustomObject]@{
                Mode = "deep"
                Label = "激进深度扫描"
                TaskName = $AggressiveTaskName
                MaxAge = [TimeSpan]::FromHours(4)
            })
        }
    }
    return [PSCustomObject]@{
        ActiveMode = "hybrid"
        ModeConflict = ($AggressiveExists -and ($LightExists -or $DeepExists))
        Definitions = @(
            [PSCustomObject]@{
                Mode = "light"
                Label = "轻量扫描"
                TaskName = $LightTaskName
                MaxAge = [TimeSpan]::FromMinutes(90)
            },
            [PSCustomObject]@{
                Mode = "deep"
                Label = "深度扫描"
                TaskName = $DeepTaskName
                MaxAge = [TimeSpan]::FromHours(8)
            }
        )
    }
}

function Update-HealthModeState(
    $State,
    [string]$ActiveMode,
    [DateTimeOffset]$Now
) {
    if ([string]$State.active_mode -eq $ActiveMode) {
        return
    }
    Set-HealthProperty $State "active_mode" $ActiveMode
    Set-HealthProperty $State "mode_changed_at" $Now.ToString("o")
    Set-HealthProperty $State "active_issue_keys" @()
    Set-HealthProperty $State.last_success "light" $null
    Set-HealthProperty $State.last_success "deep" $null
}

function Get-HealthAssessment(
    [object[]]$Snapshots,
    $State,
    [DateTimeOffset]$Now,
    [string]$InstallRoot
) {
    $Issues = @()
    $InstalledAt = ConvertTo-HealthTime $State.installed_at
    if ($null -eq $InstalledAt -or $InstalledAt -gt $Now.AddMinutes(5)) {
        $InstalledAt = $Now
        Set-HealthProperty $State "installed_at" $Now.ToString("o")
    }
    $ModeChangedAt = ConvertTo-HealthTime $State.mode_changed_at
    if ($null -eq $ModeChangedAt -or $ModeChangedAt -gt $Now.AddMinutes(5)) {
        $ModeChangedAt = $Now
        Set-HealthProperty $State "mode_changed_at" $Now.ToString("o")
    }
    $BaselineStart = if ($ModeChangedAt -gt $InstalledAt) {
        $ModeChangedAt
    } else {
        $InstalledAt
    }
    $ExpectedScript = Join-Path $InstallRoot "dynamic_selector.py"

    foreach ($Snapshot in $Snapshots) {
        $Mode = [string]$Snapshot.Mode
        $Label = [string]$Snapshot.Label
        if (-not [bool]$Snapshot.Exists) {
            $Detail = if ($Snapshot.QueryError) { "：$($Snapshot.QueryError)" } else { "" }
            $Issues += [PSCustomObject]@{
                Key = "task.$Mode.missing"
                Message = "$Label 计划任务不存在或无法读取$Detail"
            }
            continue
        }

        if (-not [bool]$Snapshot.Enabled -or [string]$Snapshot.State -eq "Disabled") {
            $Issues += [PSCustomObject]@{
                Key = "task.$Mode.disabled"
                Message = "$Label 计划任务已禁用"
            }
            continue
        }

        $ActionIsValid = $true
        $Execute = [Environment]::ExpandEnvironmentVariables([string]$Snapshot.Execute).Trim('"')
        if ([string]::IsNullOrWhiteSpace($Execute) -or
            -not (Test-Path -LiteralPath $Execute -PathType Leaf)) {
            $ActionIsValid = $false
            $Issues += [PSCustomObject]@{
                Key = "task.$Mode.interpreter_missing"
                Message = "$Label Python 解释器路径无效：$Execute"
            }
        } elseif ((Split-Path -Leaf $Execute) -ine "pythonw.exe") {
            $ActionIsValid = $false
            $Issues += [PSCustomObject]@{
                Key = "task.$Mode.interpreter_invalid"
                Message = "$Label 未使用 pythonw.exe：$Execute"
            }
        } elseif (-not [bool]$Snapshot.PythonValid) {
            $ActionIsValid = $false
            $Issues += [PSCustomObject]@{
                Key = "task.$Mode.python_invalid"
                Message = "$Label Python 解释器无法运行或版本不合格：$($Snapshot.PythonError)"
            }
        }

        $WorkingDirectoryValid = $false
        try {
            $ExpectedWorkingDirectory = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
            $ActualWorkingDirectory = [IO.Path]::GetFullPath(
                [Environment]::ExpandEnvironmentVariables(
                    [string]$Snapshot.WorkingDirectory
                )
            ).TrimEnd('\')
            $WorkingDirectoryValid = $ActualWorkingDirectory.Equals(
                $ExpectedWorkingDirectory,
                [StringComparison]::OrdinalIgnoreCase
            ) -and (Test-Path -LiteralPath $ActualWorkingDirectory -PathType Container)
        } catch {
            $WorkingDirectoryValid = $false
        }
        if (-not $WorkingDirectoryValid) {
            $ActionIsValid = $false
            $Issues += [PSCustomObject]@{
                Key = "task.$Mode.working_directory"
                Message = "$Label 工作目录无效：$($Snapshot.WorkingDirectory)"
            }
        }

        $Arguments = [Environment]::ExpandEnvironmentVariables(
            [string]$Snapshot.Arguments
        ).Trim()
        $ExpectedArguments = if ($Mode -eq "light") {
            "`"$ExpectedScript`" --quick"
        } else {
            "`"$ExpectedScript`""
        }
        $ScriptArgumentValid = $Arguments.Equals(
            $ExpectedArguments,
            [StringComparison]::OrdinalIgnoreCase
        )
        if (-not (Test-Path -LiteralPath $ExpectedScript -PathType Leaf) -or
            -not $ScriptArgumentValid) {
            $ActionIsValid = $false
            $Issues += [PSCustomObject]@{
                Key = "task.$Mode.script_missing"
                Message = "$Label 脚本路径或启动参数无效：$ExpectedScript"
            }
        }

        if (-not $ActionIsValid) {
            continue
        }

        $LastRun = ConvertTo-HealthTime $Snapshot.LastRunTime
        $ResultValue = $null
        if ($null -ne $Snapshot.LastTaskResult -and
            -not [string]::IsNullOrWhiteSpace([string]$Snapshot.LastTaskResult)) {
            try {
                $ResultValue = [int64]$Snapshot.LastTaskResult
            } catch {
                $ResultValue = $null
            }
        }
        $IsRunning = [string]$Snapshot.State -eq "Running"
        $RunStatus = Get-HealthRunStatus $InstallRoot $Mode
        $MayUseTaskResultAsSuccess = $null -eq $RunStatus
        if ($null -ne $RunStatus) {
            if (-not [bool]$RunStatus.Valid) {
                $Issues += [PSCustomObject]@{
                    Key = "scan.$Mode.heartbeat_invalid"
                    Message = "$Label 扫描心跳无效：$($RunStatus.Error)"
                }
            } elseif ([string]$RunStatus.Status -eq "success") {
                $KnownSuccess = ConvertTo-HealthTime $State.last_success.$Mode
                if ($null -eq $KnownSuccess -or $RunStatus.CompletedAt -gt $KnownSuccess) {
                    Set-HealthProperty $State.last_success $Mode $RunStatus.CompletedAt.ToString("o")
                }
                $Passed = 0
                $PoolSize = 0
                try {
                    $Passed = [int]$RunStatus.ScanSummary.speed_passed_count
                    $PoolSize = [int]$RunStatus.ScanSummary.active_pool_size
                } catch {
                    $Passed = 0
                    $PoolSize = 0
                }
                if ($Passed -lt 1 -or $PoolSize -lt 1) {
                    $Issues += [PSCustomObject]@{
                        Key = "scan.$Mode.quality"
                        Message = (
                            "$Label 最近完成但结果质量异常：正式测速通过 $Passed，正式池 $PoolSize"
                        )
                    }
                }
            } elseif ([string]$RunStatus.Status -eq "failed") {
                $Issues += [PSCustomObject]@{
                    Key = "scan.$Mode.reported_failed"
                    Message = "$Label 扫描心跳报告失败：$($RunStatus.Reason)"
                }
            }
            # skipped intentionally does not refresh last_success.
        }
        if ($MayUseTaskResultAsSuccess -and
            $null -ne $LastRun -and $LastRun.Year -ge 2000 -and
            $null -ne $ResultValue -and $ResultValue -eq 0 -and -not $IsRunning) {
            $KnownSuccess = ConvertTo-HealthTime $State.last_success.$Mode
            if ($null -eq $KnownSuccess -or $LastRun -gt $KnownSuccess) {
                Set-HealthProperty $State.last_success $Mode $LastRun.ToString("o")
            }
        }

        if ($null -ne $LastRun -and $LastRun.Year -ge 2000 -and
            $null -ne $ResultValue -and $ResultValue -ne 0 -and -not $IsRunning) {
            $Issues += [PSCustomObject]@{
                Key = "task.$Mode.failed"
                Message = (
                    "$Label 最近一次运行失败（{0}，时间 {1}）" -f
                    (Format-TaskResultCode $ResultValue),
                    $LastRun.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss")
                )
            }
        }

        $LastSuccess = ConvertTo-HealthTime $State.last_success.$Mode
        $Baseline = if ($null -ne $LastSuccess) { $LastSuccess } else { $BaselineStart }
        $Elapsed = $Now - $Baseline
        if ($Elapsed -gt [TimeSpan]$Snapshot.MaxAge) {
            $Issues += [PSCustomObject]@{
                Key = "task.$Mode.stale"
                Message = (
                    "$Label 已 {0} 未观察到成功完成（阈值 {1}）" -f
                    (Format-HealthDuration $Elapsed),
                    (Format-HealthDuration ([TimeSpan]$Snapshot.MaxAge))
                )
            }
        }
    }

    Set-HealthProperty $State "last_check" $Now.ToString("o")
    return [PSCustomObject]@{
        Issues = @($Issues)
        State = $State
    }
}

function Write-HealthLog([string]$Path, [string]$Message) {
    $Directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $File = Get-Item -LiteralPath $Path
        if ($File.Length -ge 1048576) {
            $SecondBackup = "$Path.2"
            $FirstBackup = "$Path.1"
            if (Test-Path -LiteralPath $SecondBackup) {
                Remove-Item -LiteralPath $SecondBackup -Force
            }
            if (Test-Path -LiteralPath $FirstBackup) {
                Move-Item -LiteralPath $FirstBackup -Destination $SecondBackup -Force
            }
            Move-Item -LiteralPath $Path -Destination $FirstBackup -Force
        }
    }
    $Line = "[{0}] {1}{2}" -f [DateTimeOffset]::Now.ToString("o"), $Message, [Environment]::NewLine
    $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::AppendAllText($Path, $Line, $Utf8NoBom)
}

function Send-HealthNotification(
    [string]$InstallRoot,
    [string]$Title,
    [string]$Message
) {
    $NotifyScript = Join-Path $InstallRoot "notify_windows.ps1"
    if (-not (Test-Path -LiteralPath $NotifyScript -PathType Leaf)) {
        throw "通知脚本不存在：$NotifyScript"
    }
    $PowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    if (-not (Test-Path -LiteralPath $PowerShell -PathType Leaf)) {
        throw "PowerShell 5.1 解释器不存在：$PowerShell"
    }
    $RetentionDays = 30.0
    $MaxReportFiles = 100
    $DeliveryLogMaxBytes = 1000000
    $DeliveryLogBackups = 2
    try {
        $Settings = [IO.File]::ReadAllText(
            (Join-Path $InstallRoot "settings.json")
        ) | ConvertFrom-Json
        $ConfiguredRetention = [double]$Settings.notification_report_retention_days
        if (-not [double]::IsNaN($ConfiguredRetention) -and
            -not [double]::IsInfinity($ConfiguredRetention)) {
            $RetentionDays = [Math]::Min(
                3650,
                [Math]::Max(1, $ConfiguredRetention)
            )
        }
        if ($Settings.PSObject.Properties.Name -contains "notification_report_max_files") {
            $MaxReportFiles = [Math]::Min(
                10000,
                [Math]::Max(1, [int]$Settings.notification_report_max_files)
            )
        }
        if ($Settings.PSObject.Properties.Name -contains "notification_delivery_log_max_bytes") {
            $DeliveryLogMaxBytes = [Math]::Max(
                64000,
                [long]$Settings.notification_delivery_log_max_bytes
            )
        }
        if ($Settings.PSObject.Properties.Name -contains "notification_delivery_log_backups") {
            $DeliveryLogBackups = [Math]::Min(
                20,
                [Math]::Max(1, [int]$Settings.notification_delivery_log_backups)
            )
        }
    } catch {
        $RetentionDays = 30.0
        $MaxReportFiles = 100
        $DeliveryLogMaxBytes = 1000000
        $DeliveryLogBackups = 2
    }
    & $PowerShell `
        -NoLogo `
        -NoProfile `
        -NonInteractive `
        -ExecutionPolicy Bypass `
        -WindowStyle Hidden `
        -File $NotifyScript `
        -Title $Title `
        -Message $Message `
        -RetentionDays $RetentionDays `
        -MaxReportFiles $MaxReportFiles `
        -DeliveryLogMaxBytes $DeliveryLogMaxBytes `
        -DeliveryLogBackups $DeliveryLogBackups
    if ($LASTEXITCODE -ne 0) {
        throw "通知脚本返回退出码 $LASTEXITCODE"
    }
}

function Get-HealthNotificationDecision(
    [string[]]$CurrentIssueKeys,
    [string[]]$PreviousIssueKeys
) {
    $CurrentSignature = @($CurrentIssueKeys | Sort-Object -Unique) -join "|"
    $PreviousSignature = @($PreviousIssueKeys | Sort-Object -Unique) -join "|"
    if ($CurrentSignature -eq $PreviousSignature) {
        return "None"
    }
    if (@($CurrentIssueKeys).Count -gt 0) {
        return "Alert"
    }
    if (@($PreviousIssueKeys).Count -gt 0) {
        return "Recovery"
    }
    return "None"
}

function Update-HealthIssueState(
    $State,
    [string[]]$CurrentIssueKeys,
    [ValidateSet("None", "Alert", "Recovery")]
    [string]$Decision,
    [bool]$NotificationSucceeded
) {
    if ($Decision -eq "None" -or $NotificationSucceeded) {
        Set-HealthProperty $State "active_issue_keys" @(
            $CurrentIssueKeys | Sort-Object -Unique
        )
    }
}

function Invoke-HealthMonitor {
    $InstallRoot = $PSScriptRoot
    $LogDirectory = Join-Path $InstallRoot "logs"
    $StatePath = Join-Path $LogDirectory "health_monitor_state.json"
    $LogPath = Join-Path $LogDirectory "health_monitor.log"
    $Now = [DateTimeOffset]::Now
    try {
        $State = Read-HealthState $StatePath $Now
        $TaskConfiguration = Get-HealthTaskConfiguration
        Update-HealthModeState $State $TaskConfiguration.ActiveMode $Now
        $Snapshots = Get-HealthTaskSnapshots $TaskConfiguration.Definitions
        $Assessment = Get-HealthAssessment $Snapshots $State $Now $InstallRoot
        if ($TaskConfiguration.ModeConflict) {
            $Assessment.Issues = @($Assessment.Issues) + @(
                [PSCustomObject]@{
                    Key = "task.mode.conflict"
                    Message = "混合模式与激进模式计划任务同时存在，可能重复扫描"
                }
            )
        }
        $IssueKeys = @($Assessment.Issues | ForEach-Object { $_.Key } | Sort-Object -Unique)
        $PreviousIssueKeys = @($Assessment.State.active_issue_keys | ForEach-Object { [string]$_ } | Sort-Object -Unique)
        $IssueSignature = $IssueKeys -join "|"
        $NotificationDecision = Get-HealthNotificationDecision $IssueKeys $PreviousIssueKeys
        $NotificationSucceeded = $false

        if ($NotificationDecision -eq "Alert") {
            $Message = @($Assessment.Issues | ForEach-Object { "- $($_.Message)" }) -join [Environment]::NewLine
            try {
                Send-HealthNotification `
                    -InstallRoot $InstallRoot `
                    -Title "Clash Cloudflare：任务健康告警" `
                    -Message $Message
                $NotificationSucceeded = $true
                Write-HealthLog $LogPath "已发送健康告警：$IssueSignature"
            } catch {
                Write-HealthLog $LogPath "健康告警发送失败：$($_.Exception.Message)；问题：$IssueSignature"
            }
        } elseif ($NotificationDecision -eq "Recovery") {
            try {
                Send-HealthNotification `
                    -InstallRoot $InstallRoot `
                    -Title "Clash Cloudflare：任务健康已恢复" `
                    -Message "当前扫描任务已恢复正常。"
                $NotificationSucceeded = $true
                Write-HealthLog $LogPath "已发送任务健康恢复通知"
            } catch {
                Write-HealthLog $LogPath "健康恢复通知发送失败：$($_.Exception.Message)"
            }
        } else {
            Write-HealthLog $LogPath "健康检查完成；问题数：$($IssueKeys.Count)"
        }

        Update-HealthIssueState `
            -State $Assessment.State `
            -CurrentIssueKeys $IssueKeys `
            -Decision $NotificationDecision `
            -NotificationSucceeded $NotificationSucceeded
        Write-HealthJsonAtomic $StatePath $Assessment.State
        return 0
    } catch {
        try {
            Write-HealthLog $LogPath "健康监控运行失败：$($_.Exception.Message)"
        } catch {
            # The scheduled task will retain the non-zero result if logging also fails.
        }
        return 1
    }
}

if ($MyInvocation.InvocationName -ne ".") {
    exit (Invoke-HealthMonitor)
}
