#requires -Version 5.1
param(
    [switch]$NonInteractive,
    [switch]$PrepareOnly,
    [string]$V2rayNRoot = "",
    [int]$Port = 0,
    [string]$Uuid = "",
    [string]$ServerName = "",
    [string]$HostName = "",
    [string]$WebSocketPath = "",
    [string]$MixedProxy = "",
    [string]$PreparedConfigurationDirectory = ""
)

$ErrorActionPreference = "Stop"
$ScriptRoot = $PSScriptRoot
$RepositoryRootCandidate = [IO.Path]::GetFullPath((Join-Path $ScriptRoot "..\.."))
$RepositoryCoreCandidate = Join-Path $RepositoryRootCandidate "src\clash_cloudflare_dynamic"
$RepositoryScriptsCandidate = Join-Path $RepositoryRootCandidate "scripts\windows"
$IsRepositoryLayout = (
    [IO.Path]::GetFullPath($ScriptRoot).Equals(
        [IO.Path]::GetFullPath($RepositoryScriptsCandidate),
        [StringComparison]::OrdinalIgnoreCase
    ) -and (Test-Path -LiteralPath $RepositoryCoreCandidate -PathType Container)
)
$SourceRoot = if ($IsRepositoryLayout) { $RepositoryRootCandidate } else { $ScriptRoot }
$CoreRoot = if ($IsRepositoryLayout) { $RepositoryCoreCandidate } else { $ScriptRoot }
$ExamplesRoot = Join-Path $SourceRoot "examples"
$InstalledRoot = Join-Path $env:LOCALAPPDATA "ClashCloudflareDynamic"
$Utf8NoBom = New-Object Text.UTF8Encoding($false)

function New-CompatibleTaskSettings([TimeSpan]$ExecutionTimeLimit) {
    $Arguments = @{
        StartWhenAvailable = $true
        MultipleInstances = "IgnoreNew"
        ExecutionTimeLimit = $ExecutionTimeLimit
    }
    $Supported = (Get-Command New-ScheduledTaskSettingsSet).Parameters
    if ($Supported.ContainsKey("AllowStartIfOnBatteries")) {
        $Arguments["AllowStartIfOnBatteries"] = $true
    }
    if ($Supported.ContainsKey("DontStopIfGoingOnBatteries")) {
        $Arguments["DontStopIfGoingOnBatteries"] = $true
    }
    if ($Supported.ContainsKey("Hidden")) { $Arguments["Hidden"] = $true }
    if ($Supported.ContainsKey("Priority")) { $Arguments["Priority"] = 7 }
    return New-ScheduledTaskSettingsSet @Arguments
}

function Read-JsonObject([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "JSON 文件不存在：$Path"
    }
    try { return [IO.File]::ReadAllText($Path) | ConvertFrom-Json }
    catch { throw "无法解析 JSON $Path：$($_.Exception.Message)" }
}

function Write-JsonAtomic([string]$Path, [object]$Value) {
    $Directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    $TempPath = Join-Path $Directory ("." + [IO.Path]::GetFileName($Path) + ".tmp")
    try {
        [IO.File]::WriteAllText($TempPath, ($Value | ConvertTo-Json -Depth 30), $Utf8NoBom)
        $null = Read-JsonObject $TempPath
        Move-Item -LiteralPath $TempPath -Destination $Path -Force
    } finally {
        if (Test-Path -LiteralPath $TempPath) { Remove-Item -LiteralPath $TempPath -Force }
    }
}

function Read-Input([string]$Prompt, [string]$Default = "") {
    if ($NonInteractive) { return $Default }
    $suffix = if ($Default) { " [$Default]" } else { "" }
    $value = Read-Host "$Prompt$suffix"
    if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
    return $value.Trim()
}

function Read-CredentialInput([string]$Prompt, [string]$Default = "") {
    if ($NonInteractive) { return $Default }
    $secure = Read-Host $Prompt -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function Resolve-V2rayNRoot([string]$Requested) {
    $Candidates = @()
    if ($Requested) { $Candidates += [Environment]::ExpandEnvironmentVariables($Requested) }
    $Running = Get-CimInstance Win32_Process -Filter "Name = 'v2rayN.exe'" -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty ExecutablePath
    if ($Running) { $Candidates += Split-Path -Parent $Running }
    $Candidates += @(
        (Join-Path $env:LOCALAPPDATA "v2rayN"),
        (Join-Path $env:ProgramFiles "v2rayN")
    )
    foreach ($Candidate in $Candidates) {
        if ([string]::IsNullOrWhiteSpace($Candidate)) { continue }
        $Resolved = [IO.Path]::GetFullPath($Candidate)
        if ((Test-Path -LiteralPath (Join-Path $Resolved "v2rayN.exe") -PathType Leaf) -and
            (Test-Path -LiteralPath (Join-Path $Resolved "guiConfigs\guiNDB.db") -PathType Leaf) -and
            (Test-Path -LiteralPath (Join-Path $Resolved "guiConfigs\guiNConfig.json") -PathType Leaf) -and
            (Test-Path -LiteralPath (Join-Path $Resolved "bin\xray\xray.exe") -PathType Leaf)) {
            return $Resolved
        }
    }
    if ($NonInteractive) { throw "未找到 v2rayN 根目录；请使用 -V2rayNRoot 指定便携版目录。" }
    $Manual = Read-Host "请输入 v2rayN 根目录（包含 v2rayN.exe）"
    if (-not $Manual) { throw "未指定 v2rayN 根目录。" }
    return Resolve-V2rayNRoot $Manual
}

function Assert-Inputs([string]$Root, [hashtable]$InputData) {
    foreach ($Relative in @("v2rayN.exe", "guiConfigs\guiNDB.db", "guiConfigs\guiNConfig.json", "bin\xray\xray.exe")) {
        if (-not (Test-Path -LiteralPath (Join-Path $Root $Relative) -PathType Leaf)) {
            throw "v2rayN 安装缺少 $Relative：$Root"
        }
    }
    $GuidValue = [Guid]::Empty
    if (-not [Guid]::TryParse($InputData.Uuid, [ref]$GuidValue) -or $GuidValue -eq [Guid]::Empty) {
        throw "VMess UUID 必须是有效的非零 UUID。"
    }
    if ($InputData.Port -lt 1 -or $InputData.Port -gt 65535) { throw "端口必须为 1 到 65535。" }
    foreach ($Name in @("ServerName", "HostName")) {
        $Value = [string]$InputData[$Name]
        if (-not $Value -or $Value -match "(?i)(^|\.)example\.(com|net|org)$|\.example$") {
            throw "$Name 必须填写真实域名，不能使用公开示例域名。"
        }
    }
    if (-not [string]$InputData.WebSocketPath -or -not [string]$InputData.WebSocketPath.StartsWith("/")) {
        throw "WebSocket 路径必须以 / 开头。"
    }
    $ProxyUri = $null
    if (-not [Uri]::TryCreate([string]$InputData.MixedProxy, [UriKind]::Absolute, [ref]$ProxyUri) -or
        $ProxyUri.Scheme -notin @("http", "https") -or
        -not $ProxyUri.IsLoopback -or $ProxyUri.Port -lt 1) {
        throw "本地代理必须是带端口的回环 HTTP(S) URL。"
    }
}

function New-V2rayNSettings([string]$Root, [string]$ProxyUrl) {
    $Settings = Read-JsonObject (Join-Path $ExamplesRoot "settings.example.json")
    $Settings.client_mode = "v2rayn"
    $Settings.v2rayn_root = $Root
    $Settings.v2rayn_auto_switch = $true
    $Settings.controller = "http://127.0.0.1:9090"
    $Settings.secret = ""
    $Settings.mixed_proxy = $ProxyUrl
    return $Settings
}

function New-VmessTemplate([hashtable]$InputData) {
    return [ordered]@{
        type = "vmess"
        port = [int]$InputData.Port
        uuid = [string]$InputData.Uuid
        alterId = 0
        cipher = "auto"
        udp = $true
        tls = $true
        network = "ws"
        servername = [string]$InputData.ServerName
        "ws-opts" = [ordered]@{
            path = [string]$InputData.WebSocketPath
            headers = [ordered]@{ Host = [string]$InputData.HostName }
        }
    }
}

function Save-FileState([string]$Path, [string]$BackupRoot) {
    $Exists = Test-Path -LiteralPath $Path -PathType Leaf
    $BackupPath = Join-Path $BackupRoot ("file-" + [IO.Path]::GetFileName($Path))
    if ($Exists) {
        Copy-Item -LiteralPath $Path -Destination $BackupPath -Force
    }
    return [PSCustomObject]@{
        Path = $Path
        Existed = $Exists
        BackupPath = $BackupPath
    }
}

$MutationStarted = $false
$FileStates = @()
$TaskSnapshots = @{}
$ManagedTaskNames = @()

try {
    $Root = Resolve-V2rayNRoot $V2rayNRoot
    $InputData = @{
        Port = if ($Port -gt 0) { $Port } else { [int](Read-Input "VMess 端口" "443") }
        Uuid = if ($Uuid) { $Uuid } else { Read-CredentialInput "VMess UUID（不会显示）" }
        ServerName = if ($ServerName) { $ServerName } else { Read-Input "TLS SNI / Server Name" }
        HostName = if ($HostName) { $HostName } else { Read-Input "WebSocket Host" }
        WebSocketPath = if ($WebSocketPath) { $WebSocketPath } else { Read-Input "WebSocket 路径" "/ws" }
        MixedProxy = if ($MixedProxy) { $MixedProxy } else { Read-Input "v2rayN 本地 HTTP 代理" "http://127.0.0.1:10808" }
    }
    Assert-Inputs $Root $InputData
    $Settings = New-V2rayNSettings $Root $InputData.MixedProxy
    $Template = New-VmessTemplate $InputData

    if ($PrepareOnly) {
        if (-not $PreparedConfigurationDirectory) { throw "PrepareOnly 必须指定 PreparedConfigurationDirectory。" }
        $Target = [IO.Path]::GetFullPath($PreparedConfigurationDirectory)
        New-Item -ItemType Directory -Path $Target -Force | Out-Null
        Write-JsonAtomic (Join-Path $Target "settings.json") $Settings
        Write-JsonAtomic (Join-Path $Target "node_template.json") $Template
        Write-Host "v2rayN 配置已生成：$Target"
        exit 0
    }

    $PythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue
    if (-not $PythonCommand) { throw "未找到 Python 3.10+；请先安装 Python 并确保 python.exe 在 PATH 中。" }
    $Python = $PythonCommand.Source
    $Pythonw = Join-Path (Split-Path -Parent $Python) "pythonw.exe"
    if (-not (Test-Path -LiteralPath $Pythonw -PathType Leaf)) { throw "未找到 pythonw.exe。" }
    $PythonVersion = & $Python -c "import sys; print(sys.version_info.major * 100 + sys.version_info.minor)"
    if ($LASTEXITCODE -ne 0 -or [int]$PythonVersion -lt 310) {
        throw "需要 Python 3.10 或更高版本。"
    }

    $CoreNames = @(
        "dynamic_selector.py",
        "v2rayn_mode.py",
        "health_monitor_launcher.py",
        "storage_maintenance.py"
    )
    $WindowsNames = @("health_monitor.ps1", "notify_windows.ps1", "uninstall.ps1")
    foreach ($Name in $CoreNames) {
        if (-not (Test-Path -LiteralPath (Join-Path $CoreRoot $Name) -PathType Leaf)) {
            throw "Release 缺少运行时文件：$Name"
        }
    }
    foreach ($Name in $WindowsNames) {
        if (-not (Test-Path -LiteralPath (Join-Path $ScriptRoot $Name) -PathType Leaf)) {
            throw "Release 缺少 Windows 运行时文件：$Name"
        }
    }

    $LightTask = "v2rayN Cloudflare Light Scan 2h"
    $DeepTask = "v2rayN Cloudflare Deep Scan 5000 12h"
    $HealthTask = "v2rayN Cloudflare Health Monitor 30min"
    $Stamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
    $BackupRoot = Join-Path $InstalledRoot "backups\v2rayn-install-$Stamp"
    New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
    $ConflictingTasks = @(
        "Clash Cloudflare Dynamic Discovery 30min",
        "Clash Cloudflare Light Scan 2h",
        "Clash Cloudflare Deep Scan 5000 12h",
        "Clash Cloudflare Serial Light Scan 30min",
        "Clash Cloudflare Serial Deep Scan 5000 6h",
        "Clash Cloudflare Health Monitor 30min",
        "Clash Cloudflare Light Scan 30min",
        "Clash Cloudflare Deep Scan 5000 6h",
        "Clash Cloudflare Deep Scan 5000 30min",
        "Clash Cloudflare SG Light Scan 30min",
        "Clash Cloudflare SG Deep Scan 5000 6h",
        "v2rayN Cloudflare Light Scan 30min",
        "v2rayN Cloudflare Deep Scan 5000 6h"
    )
    $ManagedTaskNames = @($LightTask, $DeepTask, $HealthTask) + $ConflictingTasks
    foreach ($TaskName in $ManagedTaskNames) {
        $Task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($null -ne $Task) {
            $TaskXml = Export-ScheduledTask -TaskName $TaskName -ErrorAction Stop
            $TaskSnapshots[$TaskName] = [PSCustomObject]@{
                Xml = $TaskXml
                Enabled = [bool]$Task.Settings.Enabled
                Running = [string]$Task.State -eq "Running"
            }
            $TaskBackupName = ($TaskName -replace '[^A-Za-z0-9.-]', '_') + ".xml"
            Set-Content -LiteralPath (Join-Path $BackupRoot $TaskBackupName) -Value $TaskXml -Encoding Unicode
        }
    }
    foreach ($Name in @($CoreNames + $WindowsNames + @("settings.json", "node_template.json"))) {
        $FileStates += Save-FileState (Join-Path $InstalledRoot $Name) $BackupRoot
    }
    $MutationStarted = $true
    New-Item -ItemType Directory -Path $InstalledRoot -Force | Out-Null
    foreach ($Name in $CoreNames) {
        $Source = Join-Path $CoreRoot $Name
        Copy-Item -LiteralPath $Source -Destination (Join-Path $InstalledRoot $Name) -Force
    }
    foreach ($Name in $WindowsNames) {
        $Source = Join-Path $ScriptRoot $Name
        Copy-Item -LiteralPath $Source -Destination (Join-Path $InstalledRoot $Name) -Force
    }
    New-Item -ItemType Directory -Path (Join-Path $InstalledRoot "logs") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $InstalledRoot "v2rayn") -Force | Out-Null
    Write-JsonAtomic (Join-Path $InstalledRoot "settings.json") $Settings
    Write-JsonAtomic (Join-Path $InstalledRoot "node_template.json") $Template

    $LightSettings = New-CompatibleTaskSettings -ExecutionTimeLimit (New-TimeSpan -Minutes 20)
    $DeepSettings = New-CompatibleTaskSettings -ExecutionTimeLimit (New-TimeSpan -Minutes 150)
    $LightAction = New-ScheduledTaskAction -Execute $Pythonw -Argument "`"$(Join-Path $InstalledRoot 'dynamic_selector.py')`" --quick" -WorkingDirectory $InstalledRoot
    $DeepAction = New-ScheduledTaskAction -Execute $Pythonw -Argument "`"$(Join-Path $InstalledRoot 'dynamic_selector.py')`"" -WorkingDirectory $InstalledRoot
    Register-ScheduledTask -TaskName $LightTask -Action $LightAction -Trigger (New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(3)) -RepetitionInterval (New-TimeSpan -Hours 2) -RepetitionDuration (New-TimeSpan -Days 3650)) -Settings $LightSettings -Description "每 2 小时验证 Cloudflare IP，并更新 v2rayN 原生 Xray 优选池。" -Force -ErrorAction Stop | Out-Null
    Register-ScheduledTask -TaskName $DeepTask -Action $DeepAction -Trigger (New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(63)) -RepetitionInterval (New-TimeSpan -Hours 12) -RepetitionDuration (New-TimeSpan -Days 3650)) -Settings $DeepSettings -Description "每 12 小时深度抽样 5000 个 Cloudflare IP；深扫活动期间轻扫跳过。" -Force -ErrorAction Stop | Out-Null
    if (Test-Path -LiteralPath (Join-Path $InstalledRoot "health_monitor.ps1")) {
        $HealthAction = New-ScheduledTaskAction -Execute $Pythonw -Argument "`"$(Join-Path $InstalledRoot 'health_monitor_launcher.py')`"" -WorkingDirectory $InstalledRoot
        Register-ScheduledTask -TaskName $HealthTask -Action $HealthAction -Trigger (New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(10)) -RepetitionInterval (New-TimeSpan -Minutes 30) -RepetitionDuration (New-TimeSpan -Days 3650)) -Settings (New-CompatibleTaskSettings -ExecutionTimeLimit (New-TimeSpan -Minutes 5)) -Description "检查 v2rayN 轻扫、深扫任务及最近成功心跳。" -Force -ErrorAction Stop | Out-Null
    }
    foreach ($TaskName in $ConflictingTasks) {
        if ($null -ne (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)) {
            Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
            Disable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        }
    }
    Write-Host "v2rayN 后端已安装到：$InstalledRoot" -ForegroundColor Cyan
    Write-Host "已创建：$LightTask、$DeepTask、$HealthTask"
    Write-Host "请先启动 v2rayN，确认基础 VMess 节点可用，然后运行：" -ForegroundColor Yellow
    Write-Host "python `"$InstalledRoot\dynamic_selector.py`" --diagnose"
    Write-Host "确认无误后运行 --setup-v2rayn-auto 建立通用 AUTO-CF。"
} catch {
    $InstallError = $_.Exception.Message
    $RollbackErrors = New-Object System.Collections.Generic.List[string]
    if ($MutationStarted) {
        foreach ($TaskName in $ManagedTaskNames) {
            try {
                Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
                Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
            } catch {
                [void]$RollbackErrors.Add("移除任务 $TaskName：$($_.Exception.Message)")
            }
        }
        foreach ($TaskName in $TaskSnapshots.Keys) {
            try {
                $Snapshot = $TaskSnapshots[$TaskName]
                Register-ScheduledTask -TaskName $TaskName -Xml ([string]$Snapshot.Xml) -Force -ErrorAction Stop | Out-Null
                if (-not $Snapshot.Enabled) {
                    Disable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null
                }
                if ($Snapshot.Running) {
                    Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
                }
            } catch {
                [void]$RollbackErrors.Add("恢复任务 $TaskName：$($_.Exception.Message)")
            }
        }
        for ($Index = $FileStates.Count - 1; $Index -ge 0; $Index--) {
            $State = $FileStates[$Index]
            try {
                if ($State.Existed) {
                    Copy-Item -LiteralPath $State.BackupPath -Destination $State.Path -Force
                } elseif (Test-Path -LiteralPath $State.Path -PathType Leaf) {
                    Remove-Item -LiteralPath $State.Path -Force
                }
            } catch {
                [void]$RollbackErrors.Add("恢复文件 $($State.Path)：$($_.Exception.Message)")
            }
        }
    }
    $Message = "v2rayN 安装失败：$InstallError"
    if ($RollbackErrors.Count -gt 0) {
        $Message += "；回滚未完全成功：$($RollbackErrors -join '；')"
    } elseif ($MutationStarted) {
        $Message += "；已恢复安装前文件和计划任务"
    }
    [Console]::Error.WriteLine($Message)
    exit 1
}
