#requires -Version 5.1
$ErrorActionPreference = "Stop"

$RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$ReleaseRoot = Join-Path $RepositoryRoot "dist\ClashCloudflareDynamic"
if (-not (Test-Path -LiteralPath $ReleaseRoot -PathType Container)) {
    throw "缺少测试发布包；请先运行 python .\tools\build_release.py"
}

function New-ScheduledTaskSettingsSet {
    [CmdletBinding()]
    param(
        [switch]$StartWhenAvailable,
        [string]$MultipleInstances,
        [TimeSpan]$ExecutionTimeLimit,
        [switch]$AllowStartIfOnBatteries,
        [switch]$DontStopIfGoingOnBatteries,
        [switch]$Hidden,
        [int]$Priority
    )
    return [PSCustomObject]@{
        ExecutionTimeLimit = $ExecutionTimeLimit
        Hidden = [bool]$Hidden
        Priority = $Priority
    }
}

function New-ScheduledTaskAction {
    [CmdletBinding()]
    param([string]$Execute, [string]$Argument, [string]$WorkingDirectory)
    return [PSCustomObject]@{
        Execute = $Execute
        Argument = $Argument
        WorkingDirectory = $WorkingDirectory
    }
}

function New-ScheduledTaskTrigger {
    [CmdletBinding()]
    param(
        [switch]$Once,
        [DateTime]$At,
        [TimeSpan]$RepetitionInterval,
        [TimeSpan]$RepetitionDuration
    )
    return [PSCustomObject]@{ At = $At; Interval = $RepetitionInterval }
}

function Register-ScheduledTask {
    [CmdletBinding()]
    param(
        [string]$TaskName,
        $Action,
        $Trigger,
        $Settings,
        [string]$Description,
        [string]$Xml,
        [switch]$Force
    )
    if ($global:ClashCloudflareDynamicTestFailAggressiveRegistration -and
        $TaskName -eq "Clash Cloudflare Deep Scan 5000 30min") {
        throw "simulated aggressive registration failure"
    }
    if ([string]::IsNullOrWhiteSpace($Xml) -and
        -not [string]::IsNullOrWhiteSpace($global:ClashCloudflareDynamicTestFailHybridTaskName) -and
        $TaskName -eq $global:ClashCloudflareDynamicTestFailHybridTaskName) {
        foreach ($MutationPath in @($global:ClashCloudflareDynamicTestMutationPaths)) {
            [IO.File]::WriteAllBytes(
                [string]$MutationPath,
                [Text.Encoding]::UTF8.GetBytes("fault-injected-$TaskName")
            )
        }
        throw "simulated hybrid registration failure: $TaskName"
    }
    $global:ClashCloudflareDynamicTestUnregisteredTasks = @(
        $global:ClashCloudflareDynamicTestUnregisteredTasks |
            Where-Object { $_ -ne $TaskName }
    )
    $global:ClashCloudflareDynamicTestRegisteredTasks += [PSCustomObject]@{
        TaskName = $TaskName
        Action = $Action
        Trigger = $Trigger
        Settings = $Settings
        Description = $Description
        Xml = $Xml
        Force = [bool]$Force
    }
}

function Unregister-ScheduledTask {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$TaskName)
    if ($TaskName -eq $global:ClashCloudflareDynamicTestFailUnregisterTaskName) {
        throw "simulated unregister failure: $TaskName"
    }
    $global:ClashCloudflareDynamicTestUnregisteredTasks += $TaskName
}

function Stop-ScheduledTask {
    [CmdletBinding()]
    param([string]$TaskName)
    $global:ClashCloudflareDynamicTestStoppedTasks += $TaskName
    $global:ClashCloudflareDynamicTestRunningTasks = @(
        $global:ClashCloudflareDynamicTestRunningTasks |
            Where-Object { $_ -ne $TaskName }
    )
}

function Disable-ScheduledTask {
    [CmdletBinding()]
    param([string]$TaskName)
    $global:ClashCloudflareDynamicTestDisabledTasks += $TaskName
}

function Start-ScheduledTask {
    [CmdletBinding()]
    param([string]$TaskName)
    $global:ClashCloudflareDynamicTestStartedTasks += $TaskName
    if ($global:ClashCloudflareDynamicTestRunningTasks -notcontains $TaskName) {
        $global:ClashCloudflareDynamicTestRunningTasks += $TaskName
    }
}

function Export-ScheduledTask {
    [CmdletBinding()]
    param([string]$TaskName)
    if ($global:ClashCloudflareDynamicTestExportFailure) {
        throw "simulated scheduled task export failure"
    }
    return "<Task><RegistrationInfo><Description>$TaskName</Description></RegistrationInfo></Task>"
}

function Get-ScheduledTask {
    [CmdletBinding()]
    param([string]$TaskName)
    $Tasks = if ($global:ClashCloudflareDynamicTestAggressiveOnly) {
        @(
            [PSCustomObject]@{ TaskName = "Clash Cloudflare Deep Scan 5000 30min" },
            [PSCustomObject]@{ TaskName = "Clash Cloudflare Health Monitor 30min" }
        )
    } else {
        @(
            [PSCustomObject]@{ TaskName = "Clash Cloudflare Light Scan 30min"; State = "Ready" },
            [PSCustomObject]@{ TaskName = "Clash Cloudflare Deep Scan 5000 6h"; State = "Ready" },
            [PSCustomObject]@{ TaskName = "Clash Cloudflare Health Monitor 30min"; State = "Ready" }
        )
    }
    if ($global:ClashCloudflareDynamicTestIncludeAggressiveWithHybrid -and
        $Tasks.TaskName -notcontains "Clash Cloudflare Deep Scan 5000 30min") {
        $Tasks += [PSCustomObject]@{ TaskName = "Clash Cloudflare Deep Scan 5000 30min" }
    }
    foreach ($RegisteredTask in $global:ClashCloudflareDynamicTestRegisteredTasks) {
        if ($Tasks.TaskName -notcontains $RegisteredTask.TaskName) {
            $Tasks += [PSCustomObject]@{
                TaskName = $RegisteredTask.TaskName
                State = "Ready"
            }
        }
    }
    $Tasks = @($Tasks | Where-Object {
        $global:ClashCloudflareDynamicTestUnregisteredTasks -notcontains $_.TaskName
    })
    foreach ($Task in $Tasks) {
        if ($global:ClashCloudflareDynamicTestRunningTasks -contains $Task.TaskName) {
            $Task.State = "Running"
        }
    }
    if ([string]::IsNullOrWhiteSpace($TaskName)) {
        return $Tasks
    }
    return @($Tasks | Where-Object { $_.TaskName -eq $TaskName })
}

function Start-Process {
    [CmdletBinding()]
    param([string]$FilePath, [string[]]$ArgumentList)
}

function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -ne $Actual) {
        throw "$Message；预期：$Expected；实际：$Actual"
    }
}

$OriginalLocalAppData = $env:LOCALAPPDATA
$OriginalAppData = $env:APPDATA
$HadOriginalExampleConfigFlag = Test-Path Env:CCFD_ALLOW_EXAMPLE_CONFIG_FOR_TESTS
$OriginalExampleConfigFlag = $env:CCFD_ALLOW_EXAMPLE_CONFIG_FOR_TESTS
$TestRoot = Join-Path ([IO.Path]::GetTempPath()) ("cfdyn-install-test-" + [Guid]::NewGuid().ToString("N"))
$InstallScript = $null
$global:ClashCloudflareDynamicTestRegisteredTasks = @()
$global:ClashCloudflareDynamicTestExportFailure = $false
$global:ClashCloudflareDynamicTestAggressiveOnly = $false
$global:ClashCloudflareDynamicTestFailAggressiveRegistration = $false
$global:ClashCloudflareDynamicTestUnregisteredTasks = @()
$global:ClashCloudflareDynamicTestFailHybridTaskName = $null
$global:ClashCloudflareDynamicTestMutationPaths = @()
$global:ClashCloudflareDynamicTestFailUnregisterTaskName = $null
$global:ClashCloudflareDynamicTestIncludeAggressiveWithHybrid = $false
$global:ClashCloudflareDynamicTestRunningTasks = @()
$global:ClashCloudflareDynamicTestStoppedTasks = @()
$global:ClashCloudflareDynamicTestDisabledTasks = @()
$global:ClashCloudflareDynamicTestStartedTasks = @()

try {
    $env:LOCALAPPDATA = Join-Path $TestRoot "Local"
    $env:APPDATA = Join-Path $TestRoot "Roaming"
    New-Item -ItemType Directory -Path $env:LOCALAPPDATA, $env:APPDATA -Force | Out-Null

    # Build an isolated source tree so tests never read or overwrite a
    # contributor's ignored local credentials in the repository root.
    $TestSource = Join-Path $TestRoot "source"
    New-Item -ItemType Directory -Path $TestSource -Force | Out-Null
    Get-ChildItem -LiteralPath $ReleaseRoot -File | Where-Object {
        $_.Name -notin @("settings.json", "node_template.json")
    } | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $TestSource
    }
    Copy-Item `
        -LiteralPath (Join-Path $ReleaseRoot "examples\settings.example.json") `
        -Destination (Join-Path $TestSource "settings.json")
    Copy-Item `
        -LiteralPath (Join-Path $ReleaseRoot "examples\node_template.example.json") `
        -Destination (Join-Path $TestSource "node_template.json")
    foreach ($RepositoryDirectory in @(".git", ".github", "examples", "tools")) {
        New-Item `
            -ItemType Directory `
            -Path (Join-Path $TestSource $RepositoryDirectory) `
            -Force | Out-Null
    }
    $InstallScript = Join-Path $TestSource "install_hybrid_5000.ps1"

    Remove-Item Env:CCFD_ALLOW_EXAMPLE_CONFIG_FOR_TESTS -ErrorAction SilentlyContinue
    $ExampleConfigRejected = $false
    try {
        & $InstallScript
    } catch {
        $ExampleConfigRejected = $_.Exception.Message -like "*公开示例配置*"
    }
    Assert-Equal $true $ExampleConfigRejected "安装器未拒绝公开示例节点配置"
    Assert-Equal $false (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA "ClashCloudflareDynamic")) "示例配置预检失败前已写入安装目录"

    Copy-Item `
        -LiteralPath (Join-Path $ReleaseRoot "examples\node_template.trojan.example.json") `
        -Destination (Join-Path $TestSource "node_template.json") `
        -Force
    $TrojanExampleRejected = $false
    try {
        & $InstallScript
    } catch {
        $TrojanExampleRejected = $_.Exception.Message -like "*公开示例配置*示例密码*"
    }
    Assert-Equal $true $TrojanExampleRejected "安装器未拒绝 Trojan 示例密码"
    Assert-Equal $false (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA "ClashCloudflareDynamic")) "Trojan 示例预检失败前已写入安装目录"

    $UdpOnlyTemplate = [PSCustomObject]@{
        type = "hysteria2"
        port = 443
        password = "test-only"
    } | ConvertTo-Json
    [IO.File]::WriteAllText(
        (Join-Path $TestSource "node_template.json"),
        $UdpOnlyTemplate,
        (New-Object Text.UTF8Encoding($false))
    )
    $UdpOnlyRejected = $false
    try {
        & $InstallScript
    } catch {
        $UdpOnlyRejected = $_.Exception.Message -like "*不支持 UDP/QUIC 专用协议*"
    }
    Assert-Equal $true $UdpOnlyRejected "安装器未拒绝 TCP 初筛不兼容的 UDP 协议"
    Assert-Equal $false (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA "ClashCloudflareDynamic")) "UDP 协议预检失败前已写入安装目录"
    $VlessTestTemplate = [IO.File]::ReadAllText(
        (Join-Path $ReleaseRoot "examples\node_template.vless.example.json")
    ) | ConvertFrom-Json
    $VlessTestTemplate.port = 8443
    $VlessTestTemplate.uuid = "11111111-1111-4111-8111-111111111111"
    $VlessTestTemplate.servername = "proxy.example.invalid"
    $VlessTestTemplate.'ws-opts'.path = "/test-only"
    $VlessTestTemplate.'ws-opts'.headers.Host = "proxy.example.invalid"
    [IO.File]::WriteAllText(
        (Join-Path $TestSource "node_template.json"),
        ($VlessTestTemplate | ConvertTo-Json -Depth 30),
        (New-Object Text.UTF8Encoding($false))
    )

    $MissingConfigSource = Join-Path $TestRoot "missing-config-source"
    $MissingConfigLocal = Join-Path $TestRoot "missing-config-local"
    $MissingConfigRoaming = Join-Path $TestRoot "missing-config-roaming"
    New-Item -ItemType Directory -Path $MissingConfigSource -Force | Out-Null
    Copy-Item -LiteralPath $InstallScript -Destination (Join-Path $MissingConfigSource "install_hybrid_5000.ps1")
    $env:LOCALAPPDATA = $MissingConfigLocal
    $env:APPDATA = $MissingConfigRoaming
    $MissingConfigRejected = $false
    try {
        & (Join-Path $MissingConfigSource "install_hybrid_5000.ps1")
    } catch {
        $MissingConfigRejected = $_.Exception.Message -like "*JSON 文件不存在*settings.json*"
    }
    Assert-Equal $true $MissingConfigRejected "安装源缺少 settings.json 时未在写入前中止"
    Assert-Equal $false (Test-Path -LiteralPath $MissingConfigLocal) "安装源缺少配置时写入了 LOCALAPPDATA"
    Assert-Equal $false (Test-Path -LiteralPath $MissingConfigRoaming) "安装源缺少配置时写入了 APPDATA"

    $FreshFailureLocal = Join-Path $TestRoot "fresh-failure-local"
    $FreshFailureRoaming = Join-Path $TestRoot "fresh-failure-roaming"
    $env:LOCALAPPDATA = $FreshFailureLocal
    $env:APPDATA = $FreshFailureRoaming
    $env:CCFD_ALLOW_EXAMPLE_CONFIG_FOR_TESTS = "1"
    $global:ClashCloudflareDynamicTestFailHybridTaskName = "Clash Cloudflare Health Monitor 30min"
    $FreshFailureRaised = $false
    try {
        & $InstallScript
    } catch {
        $FreshFailureRaised = $_.Exception.Message -like "*已恢复原调度*已恢复安装前文件状态*"
    } finally {
        $global:ClashCloudflareDynamicTestFailHybridTaskName = $null
    }
    Assert-Equal $true $FreshFailureRaised "全新安装任务注册失败后未完成双层回滚"
    $FreshFailureInstall = Join-Path $FreshFailureLocal "ClashCloudflareDynamic"
    $FreshFailureProvider = Join-Path $FreshFailureRoaming "io.github.clash-verge-rev.clash-verge-rev\providers\ClashCloudflareDynamic"
    $FreshFailureShortcut = Join-Path $FreshFailureRoaming "Microsoft\Windows\Start Menu\Programs\Clash Cloudflare Dynamic.lnk"
    foreach ($UnexpectedPath in @(
        (Join-Path $FreshFailureInstall "dynamic_selector.py"),
        (Join-Path $FreshFailureInstall "settings.json"),
        (Join-Path $FreshFailureInstall "node_template.json"),
        (Join-Path $FreshFailureInstall "clash_cloudflare_dynamic_verge_safe.yaml"),
        (Join-Path $FreshFailureInstall "logs\health_monitor_state.json"),
        (Join-Path $FreshFailureProvider "cloudflare_active.yaml"),
        (Join-Path $FreshFailureProvider "cloudflare_discovery.yaml"),
        $FreshFailureShortcut
    )) {
        Assert-Equal $false (Test-Path -LiteralPath $UnexpectedPath) "全新安装回滚后残留受管文件：$UnexpectedPath"
    }
    $global:ClashCloudflareDynamicTestRegisteredTasks = @()
    $global:ClashCloudflareDynamicTestUnregisteredTasks = @()
    $env:LOCALAPPDATA = Join-Path $TestRoot "Local"
    $env:APPDATA = Join-Path $TestRoot "Roaming"

    & $InstallScript

    $InstallDir = Join-Path $env:LOCALAPPDATA "ClashCloudflareDynamic"
    $ProviderDir = Join-Path $env:APPDATA "io.github.clash-verge-rev.clash-verge-rev\providers\ClashCloudflareDynamic"
    $SettingsPath = Join-Path $InstallDir "settings.json"
    $NodeTemplatePath = Join-Path $InstallDir "node_template.json"
    $ConfigPath = Join-Path $InstallDir "clash_cloudflare_dynamic_verge_safe.yaml"
    $ActiveProviderPath = Join-Path $ProviderDir "cloudflare_active.yaml"
    $DiscoveryProviderPath = Join-Path $ProviderDir "cloudflare_discovery.yaml"
    $HealthStatePath = Join-Path $InstallDir "logs\health_monitor_state.json"
    $HealthLauncherPath = Join-Path $InstallDir "health_monitor_launcher.py"
    $ToastShortcutPath = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Clash Cloudflare Dynamic.lnk"
    $InstalledTemplate = [IO.File]::ReadAllText($NodeTemplatePath) |
        ConvertFrom-Json
    Assert-Equal "vless" $InstalledTemplate.type "安装器未接受 VLESS 自定义节点模板"
    Assert-Equal 8443 $InstalledTemplate.port "安装器未保留用户选择的节点端口"

    foreach ($ForbiddenInstallPath in @(
        (Join-Path $InstallDir ".git"),
        (Join-Path $InstallDir ".github"),
        (Join-Path $InstallDir "tools"),
        (Join-Path $InstallDir "examples"),
        (Join-Path $InstallDir "test_dynamic_selector.py"),
        (Join-Path $InstallDir "test_install_hybrid.ps1"),
        (Join-Path $InstallDir "setup.ps1"),
        (Join-Path $InstallDir "README.md")
    )) {
        Assert-Equal $false (Test-Path -LiteralPath $ForbiddenInstallPath) "仓库/测试/文档内容被复制到运行目录：$ForbiddenInstallPath"
    }

    $LightTask = @($global:ClashCloudflareDynamicTestRegisteredTasks | Where-Object {
        $_.TaskName -eq "Clash Cloudflare Light Scan 30min"
    })
    $DeepTask = @($global:ClashCloudflareDynamicTestRegisteredTasks | Where-Object {
        $_.TaskName -eq "Clash Cloudflare Deep Scan 5000 6h"
    })
    $HealthTask = @($global:ClashCloudflareDynamicTestRegisteredTasks | Where-Object {
        $_.TaskName -eq "Clash Cloudflare Health Monitor 30min"
    })
    Assert-Equal 1 $LightTask.Count "轻量任务注册次数异常"
    Assert-Equal 1 $DeepTask.Count "深度任务注册次数异常"
    Assert-Equal 1 $HealthTask.Count "健康监控任务注册次数异常"
    Assert-Equal ([TimeSpan]::FromMinutes(20)) $LightTask[0].Settings.ExecutionTimeLimit "轻量任务执行上限错误"
    Assert-Equal ([TimeSpan]::FromMinutes(150)) $DeepTask[0].Settings.ExecutionTimeLimit "深度任务执行上限错误"
    Assert-Equal ([TimeSpan]::FromMinutes(5)) $HealthTask[0].Settings.ExecutionTimeLimit "健康监控任务执行上限错误"
    Assert-Equal $true $LightTask[0].Settings.Hidden "轻量任务未隐藏"
    Assert-Equal $true $DeepTask[0].Settings.Hidden "深度任务未隐藏"
    Assert-Equal $true $HealthTask[0].Settings.Hidden "健康监控任务未隐藏"
    Assert-Equal 7 $LightTask[0].Settings.Priority "轻量任务优先级错误"
    Assert-Equal 7 $DeepTask[0].Settings.Priority "深度任务优先级错误"
    Assert-Equal 7 $HealthTask[0].Settings.Priority "健康监控任务优先级错误"
    Assert-Equal "pythonw.exe" (Split-Path -Leaf $LightTask[0].Action.Execute) "轻量任务未使用 pythonw.exe"
    Assert-Equal "pythonw.exe" (Split-Path -Leaf $DeepTask[0].Action.Execute) "深度任务未使用 pythonw.exe"
    Assert-Equal "pythonw.exe" (Split-Path -Leaf $HealthTask[0].Action.Execute) "健康监控未使用无控制台 Python 启动器"
    Assert-Equal ([IO.Path]::GetFullPath($LightTask[0].Action.Execute)) ([IO.Path]::GetFullPath($HealthTask[0].Action.Execute)) "健康监控与扫描任务未使用同一 pythonw.exe"
    Assert-Equal ([TimeSpan]::FromMinutes(30)) $HealthTask[0].Trigger.Interval "健康监控执行周期错误"
    if ($HealthTask[0].Action.Argument -notmatch "(?i)health_monitor_launcher\.py") {
        throw "健康监控任务未按无控制台 pythonw 方式注册"
    }
    if (-not (Test-Path -LiteralPath $HealthLauncherPath -PathType Leaf)) {
        throw "安装目录缺少健康监控隐藏启动器"
    }
    $HealthLauncherText = [IO.File]::ReadAllText($HealthLauncherPath)
    foreach ($RequiredText in "CREATE_NO_WINDOW", "subprocess.DEVNULL", "health_monitor.ps1") {
        if ($HealthLauncherText -notlike "*$RequiredText*") {
            throw "健康监控隐藏启动器缺少关键行为：$RequiredText"
        }
    }

    $Settings = [IO.File]::ReadAllText($SettingsPath) | ConvertFrom-Json
    $Settings.controller = "http://127.0.0.1:9191"
    $Settings.secret = "preserved-secret"
    $Settings.mixed_proxy = "http://127.0.0.1:7999"
    $Settings | Add-Member -NotePropertyName "custom_setting" -NotePropertyValue 42
    $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($SettingsPath, ($Settings | ConvertTo-Json -Depth 30), $Utf8NoBom)

    $NodeTemplate = [IO.File]::ReadAllText($NodeTemplatePath) | ConvertFrom-Json
    $NodeTemplate.uuid = "preserved-uuid"
    [IO.File]::WriteAllText($NodeTemplatePath, ($NodeTemplate | ConvertTo-Json -Depth 30), $Utf8NoBom)
    [IO.File]::WriteAllText($ActiveProviderPath, '{"proxies":[{"name":"preserved","server":"1.1.1.1"}]}', $Utf8NoBom)
    [IO.File]::WriteAllText($ConfigPath, "preserved-config", $Utf8NoBom)
    $HealthState = [IO.File]::ReadAllText($HealthStatePath) | ConvertFrom-Json
    $HealthState.installed_at = "2026-01-02T03:04:05+08:00"
    [IO.File]::WriteAllText(
        $HealthStatePath,
        ($HealthState | ConvertTo-Json -Depth 20),
        $Utf8NoBom
    )

    & $InstallScript

    $ReinstalledSettings = [IO.File]::ReadAllText($SettingsPath) | ConvertFrom-Json
    $ReinstalledTemplate = [IO.File]::ReadAllText($NodeTemplatePath) | ConvertFrom-Json
    Assert-Equal "http://127.0.0.1:9191" $ReinstalledSettings.controller "controller 被覆盖"
    Assert-Equal "preserved-secret" $ReinstalledSettings.secret "secret 被覆盖"
    Assert-Equal "http://127.0.0.1:7999" $ReinstalledSettings.mixed_proxy "mixed_proxy 被覆盖"
    Assert-Equal 42 $ReinstalledSettings.custom_setting "自定义设置丢失"
    Assert-Equal "preserved-uuid" $ReinstalledTemplate.uuid "节点认证模板被覆盖"
    Assert-Equal "preserved-config" ([IO.File]::ReadAllText($ConfigPath)) "Clash 配置被覆盖"
    Assert-Equal '{"proxies":[{"name":"preserved","server":"1.1.1.1"}]}' ([IO.File]::ReadAllText($ActiveProviderPath)) "正式 provider 被覆盖"
    $ReinstalledHealthState = [IO.File]::ReadAllText($HealthStatePath) | ConvertFrom-Json
    Assert-Equal "2026-01-02T03:04:05+08:00" $ReinstalledHealthState.installed_at "健康监控安装宽限期状态被重置"
    Assert-Equal 0 @(Get-ChildItem -LiteralPath $InstallDir -Filter "*.tmp" -Force).Count "安装后残留临时文件"

    $Backups = @(Get-ChildItem -LiteralPath (Join-Path $InstallDir "backups") -Directory | Sort-Object LastWriteTime -Descending)
    Assert-Equal 2 $Backups.Count "首次迁移和重装未分别创建备份目录"
    $ReinstallBackup = $Backups[0]
    foreach ($Name in "settings.json", "node_template.json", "clash_cloudflare_dynamic_verge_safe.yaml", "cloudflare_active.yaml", "cloudflare_discovery.yaml", "health_monitor_state.json", "notify_windows.ps1", "health_monitor.ps1", "health_monitor_launcher.py", "install_hybrid_5000.ps1", "light-task.xml", "deep-task.xml", "health-task.xml") {
        if (-not (Test-Path -LiteralPath (Join-Path $ReinstallBackup.FullName $Name))) {
            throw "备份缺少文件：$Name"
        }
    }

    $InstalledProgramPath = Join-Path $InstallDir "dynamic_selector.py"
    [IO.File]::WriteAllText($InstalledProgramPath, "# preserve-on-backup-failure", $Utf8NoBom)
    $BeforeFailedInstallHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $InstalledProgramPath).Hash
    $DisabledBeforeExportFailure = @($global:ClashCloudflareDynamicTestDisabledTasks).Count
    $StoppedBeforeExportFailure = @($global:ClashCloudflareDynamicTestStoppedTasks).Count
    $global:ClashCloudflareDynamicTestExportFailure = $true
    $ExportFailureRaised = $false
    try {
        & $InstallScript
    } catch {
        $ExportFailureRaised = $_.Exception.Message -like "*simulated scheduled task export failure*"
    } finally {
        $global:ClashCloudflareDynamicTestExportFailure = $false
    }
    Assert-Equal $true $ExportFailureRaised "计划任务备份失败未中止安装"
    $AfterFailedInstallHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $InstalledProgramPath).Hash
    Assert-Equal $BeforeFailedInstallHash $AfterFailedInstallHash "任务备份失败后仍覆盖了程序文件"
    Assert-Equal $DisabledBeforeExportFailure @($global:ClashCloudflareDynamicTestDisabledTasks).Count "任务备份失败前错误禁用了现有任务"
    Assert-Equal $StoppedBeforeExportFailure @($global:ClashCloudflareDynamicTestStoppedTasks).Count "任务备份失败前错误停止了现有任务"
    $BackupsAfterFailure = @(Get-ChildItem -LiteralPath (Join-Path $InstallDir "backups") -Directory)
    Assert-Equal 2 $BackupsAfterFailure.Count "任务备份失败后残留不完整备份目录"

    $global:ClashCloudflareDynamicTestUnregisteredTasks = @()
    $BeforeHybridFailureRegistrationCount = @($global:ClashCloudflareDynamicTestRegisteredTasks).Count
    $RollbackPaths = @(
        $InstalledProgramPath,
        $SettingsPath,
        $NodeTemplatePath,
        $ConfigPath,
        $ActiveProviderPath,
        $DiscoveryProviderPath,
        $HealthStatePath,
        $ToastShortcutPath
    )
    $BeforeHybridFailureHashes = @{}
    foreach ($RollbackPath in $RollbackPaths) {
        $BeforeHybridFailureHashes[$RollbackPath] = (Get-FileHash -Algorithm SHA256 -LiteralPath $RollbackPath).Hash
    }
    $global:ClashCloudflareDynamicTestMutationPaths = $RollbackPaths
    $global:ClashCloudflareDynamicTestFailHybridTaskName = "Clash Cloudflare Health Monitor 30min"
    $global:ClashCloudflareDynamicTestRunningTasks = @(
        "Clash Cloudflare Light Scan 30min"
    )
    $global:ClashCloudflareDynamicTestStartedTasks = @()
    $HybridFailureRaised = $false
    try {
        & $InstallScript
    } catch {
        $HybridFailureRaised = $_.Exception.Message -like "*已恢复原调度*"
    } finally {
        $global:ClashCloudflareDynamicTestFailHybridTaskName = $null
        $global:ClashCloudflareDynamicTestMutationPaths = @()
    }
    Assert-Equal $true $HybridFailureRaised "混合任务注册失败后未报告回滚"
    Assert-Equal $true ($global:ClashCloudflareDynamicTestStartedTasks -contains "Clash Cloudflare Light Scan 30min") "安装失败后未重启原先正在运行的任务"
    $HybridFailureRegistrations = @($global:ClashCloudflareDynamicTestRegisteredTasks | Select-Object -Skip $BeforeHybridFailureRegistrationCount)
    $RestoredTaskNames = @($HybridFailureRegistrations | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_.Xml)
    } | ForEach-Object { $_.TaskName })
    foreach ($TaskName in "Clash Cloudflare Light Scan 30min", "Clash Cloudflare Deep Scan 5000 6h", "Clash Cloudflare Health Monitor 30min") {
        if ($RestoredTaskNames -notcontains $TaskName) {
            throw "混合任务注册失败后未从 XML 恢复：$TaskName"
        }
    }
    Assert-Equal 0 @($global:ClashCloudflareDynamicTestUnregisteredTasks).Count "混合任务注册失败时错误清理了旧模式"
    foreach ($RollbackPath in $RollbackPaths) {
        $RestoredHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $RollbackPath).Hash
        Assert-Equal $BeforeHybridFailureHashes[$RollbackPath] $RestoredHash "任务注册失败后文件未恢复：$RollbackPath"
    }

    $global:ClashCloudflareDynamicTestUnregisteredTasks = @()
    $global:ClashCloudflareDynamicTestIncludeAggressiveWithHybrid = $true
    $global:ClashCloudflareDynamicTestFailUnregisterTaskName = "Clash Cloudflare Deep Scan 5000 30min"
    $HybridCleanupFailureRaised = $false
    try {
        & $InstallScript
    } catch {
        $HybridCleanupFailureRaised = $_.Exception.Message -like "*已恢复原调度*"
    } finally {
        $global:ClashCloudflareDynamicTestFailUnregisterTaskName = $null
        $global:ClashCloudflareDynamicTestIncludeAggressiveWithHybrid = $false
    }
    Assert-Equal $true $HybridCleanupFailureRaised "混合模式清理旧任务失败后未回滚"
    Assert-Equal $false ($global:ClashCloudflareDynamicTestUnregisteredTasks -contains "Clash Cloudflare Deep Scan 5000 30min") "混合模式回滚后未恢复 Aggressive"
    $global:ClashCloudflareDynamicTestRegisteredTasks = @(
        $global:ClashCloudflareDynamicTestRegisteredTasks | Where-Object {
            $_.TaskName -ne "Clash Cloudflare Deep Scan 5000 30min"
        }
    )
    $global:ClashCloudflareDynamicTestUnregisteredTasks = @()

    $AggressiveScript = Join-Path $ReleaseRoot "install_aggressive_5000_30min.ps1"
    $global:ClashCloudflareDynamicTestUnregisteredTasks = @()
    $global:ClashCloudflareDynamicTestFailAggressiveRegistration = $true
    $AggressiveFailureRaised = $false
    try {
        & $AggressiveScript
    } catch {
        $AggressiveFailureRaised = $_.Exception.Message -like "*simulated aggressive registration failure*"
    } finally {
        $global:ClashCloudflareDynamicTestFailAggressiveRegistration = $false
    }
    Assert-Equal $true $AggressiveFailureRaised "激进任务注册失败未向上报告"
    Assert-Equal 0 @($global:ClashCloudflareDynamicTestUnregisteredTasks).Count "激进任务注册失败前已删除现有任务"

    $global:ClashCloudflareDynamicTestFailUnregisterTaskName = "Clash Cloudflare Deep Scan 5000 6h"
    $AggressiveCleanupFailureRaised = $false
    $AggressiveCleanupFailureMessage = ""
    try {
        & $AggressiveScript
    } catch {
        $AggressiveCleanupFailureMessage = $_.Exception.Message
        $AggressiveCleanupFailureRaised = $AggressiveCleanupFailureMessage -like "*激进模式迁移失败*"
    } finally {
        $global:ClashCloudflareDynamicTestFailUnregisterTaskName = $null
    }
    Assert-Equal $true $AggressiveCleanupFailureRaised "激进模式清理旧任务失败未报告：$AggressiveCleanupFailureMessage"
    Assert-Equal $false ($global:ClashCloudflareDynamicTestUnregisteredTasks -contains "Clash Cloudflare Light Scan 30min") "激进模式回滚后未恢复 Light"
    Assert-Equal $true ($global:ClashCloudflareDynamicTestUnregisteredTasks -contains "Clash Cloudflare Deep Scan 5000 30min") "激进模式回滚后未移除新 Aggressive；异常=$AggressiveCleanupFailureMessage；注销=$($global:ClashCloudflareDynamicTestUnregisteredTasks -join ',')"

    & $AggressiveScript
    $AggressiveTasks = @($global:ClashCloudflareDynamicTestRegisteredTasks | Where-Object {
        $_.TaskName -eq "Clash Cloudflare Deep Scan 5000 30min" -and
        [string]::IsNullOrWhiteSpace([string]$_.Xml)
    })
    Assert-Equal 2 $AggressiveTasks.Count "激进任务故障注入与成功注册次数异常"
    $SuccessfulAggressiveTask = $AggressiveTasks[-1]
    Assert-Equal "pythonw.exe" (Split-Path -Leaf $SuccessfulAggressiveTask.Action.Execute) "激进任务未使用 pythonw.exe"
    Assert-Equal $true $SuccessfulAggressiveTask.Settings.Hidden "激进任务未隐藏"
    Assert-Equal 7 $SuccessfulAggressiveTask.Settings.Priority "激进任务优先级错误"
    Assert-Equal ([TimeSpan]::FromMinutes(150)) $SuccessfulAggressiveTask.Settings.ExecutionTimeLimit "激进任务执行上限错误"
    Assert-Equal ([TimeSpan]::FromMinutes(30)) $SuccessfulAggressiveTask.Trigger.Interval "激进任务周期错误"
    $AggressiveBackups = @(Get-ChildItem -LiteralPath (Join-Path $InstallDir "backups") -Directory -Filter "aggressive-mode-*")
    if ($AggressiveBackups.Count -lt 2) {
        throw "激进模式注册失败和成功前未分别备份任务"
    }
    $LatestAggressiveBackup = $AggressiveBackups | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    foreach ($Name in "light-task.xml", "deep-task.xml") {
        if (-not (Test-Path -LiteralPath (Join-Path $LatestAggressiveBackup.FullName $Name))) {
            throw "激进模式备份缺少文件：$Name"
        }
    }
    $global:ClashCloudflareDynamicTestUnregisteredTasks = @()
    $global:ClashCloudflareDynamicTestRegisteredTasks = @(
        $global:ClashCloudflareDynamicTestRegisteredTasks | Where-Object {
            $_.TaskName -ne "Clash Cloudflare Deep Scan 5000 30min"
        }
    )

    $InstallerText = [IO.File]::ReadAllText($InstallScript)
    if ($InstallerText -match 'Get-ChildItem\s+-Path\s+\$Source' -or
        $InstallerText -match '\$CopyExclusions') {
        throw "混合安装器重新引入了源码目录排除式递归复制"
    }
    foreach ($RequiredWhitelistText in '$RuntimeFileNames = @(', '-LiteralPath $RuntimeSourcePath') {
        if ($InstallerText -notlike "*$RequiredWhitelistText*") {
            throw "混合安装器缺少运行时白名单行为：$RequiredWhitelistText"
        }
    }
    $HealthRegistrationIndex = $InstallerText.IndexOf('-TaskName $HealthTask')
    $ObsoleteCleanupIndex = $InstallerText.IndexOf('foreach ($TaskName in @($OldTask, $AggressiveTask))')
    if ($HealthRegistrationIndex -lt 0 -or $ObsoleteCleanupIndex -le $HealthRegistrationIndex) {
        throw "混合安装器在替代任务成功前清理旧任务"
    }
    $UninstallText = [IO.File]::ReadAllText((Join-Path $ReleaseRoot "uninstall.ps1"))
    foreach ($RequiredText in "Stop-ScheduledTask", "-ErrorAction Stop", "Clash Cloudflare Dynamic.lnk", "ClashCloudflareDynamic", "RemoveData") {
        if ($UninstallText -notlike "*$RequiredText*") {
            throw "卸载器缺少安全行为：$RequiredText"
        }
    }

    . (Join-Path $ReleaseRoot "health_monitor.ps1")
    $Now = [DateTimeOffset]::Parse("2026-07-23T12:00:00+08:00")
    $HealthyState = New-HealthState $Now
    $HealthySnapshots = @(
        [PSCustomObject]@{
            Mode = "light"
            Label = "轻量扫描"
            TaskName = "Clash Cloudflare Light Scan 30min"
            MaxAge = [TimeSpan]::FromMinutes(90)
            Exists = $true
            Enabled = $true
            State = "Ready"
            Execute = $LightTask[0].Action.Execute
            Arguments = $LightTask[0].Action.Argument
            WorkingDirectory = $InstallDir
            PythonValid = $true
            PythonVersion = "3.13.5"
            PythonError = $null
            LastRunTime = $Now.AddMinutes(-30)
            LastTaskResult = 0
            QueryError = $null
        },
        [PSCustomObject]@{
            Mode = "deep"
            Label = "深度扫描"
            TaskName = "Clash Cloudflare Deep Scan 5000 6h"
            MaxAge = [TimeSpan]::FromHours(8)
            Exists = $true
            Enabled = $true
            State = "Ready"
            Execute = $DeepTask[0].Action.Execute
            Arguments = $DeepTask[0].Action.Argument
            WorkingDirectory = $InstallDir
            PythonValid = $true
            PythonVersion = "3.13.5"
            PythonError = $null
            LastRunTime = $null
            LastTaskResult = $null
            QueryError = $null
        }
    )
    $HealthyAssessment = Get-HealthAssessment $HealthySnapshots $HealthyState $Now $InstallDir
    Assert-Equal 0 $HealthyAssessment.Issues.Count "首次深扫宽限期内产生误报"
    Assert-Equal $Now.AddMinutes(-30).ToString("o") $HealthyAssessment.State.last_success.light "轻量扫描成功时间未记录"

    $global:ClashCloudflareDynamicTestRegisteredTasks = @()
    $global:ClashCloudflareDynamicTestUnregisteredTasks = @()
    $HybridConfiguration = Get-HealthTaskConfiguration
    Assert-Equal "hybrid" $HybridConfiguration.ActiveMode "健康监控未识别混合模式"
    Assert-Equal 2 @($HybridConfiguration.Definitions).Count "混合模式健康定义数量错误"
    $global:ClashCloudflareDynamicTestAggressiveOnly = $true
    $AggressiveConfiguration = Get-HealthTaskConfiguration
    Assert-Equal "aggressive" $AggressiveConfiguration.ActiveMode "健康监控未识别激进模式"
    Assert-Equal 1 @($AggressiveConfiguration.Definitions).Count "激进模式健康定义数量错误"
    Assert-Equal "Clash Cloudflare Deep Scan 5000 30min" $AggressiveConfiguration.Definitions[0].TaskName "激进模式健康任务名错误"
    Assert-Equal ([TimeSpan]::FromHours(4)) $AggressiveConfiguration.Definitions[0].MaxAge "激进模式健康超时错误"
    $global:ClashCloudflareDynamicTestAggressiveOnly = $false
    $global:ClashCloudflareDynamicTestIncludeAggressiveWithHybrid = $true
    $ConflictConfiguration = Get-HealthTaskConfiguration
    Assert-Equal $true $ConflictConfiguration.ModeConflict "健康监控未识别混合/激进任务并存"
    $global:ClashCloudflareDynamicTestIncludeAggressiveWithHybrid = $false

    $ModeState = New-HealthState $Now.AddHours(-9)
    $ModeState.active_mode = "hybrid"
    $ModeState.mode_changed_at = $Now.AddHours(-9).ToString("o")
    $ModeState.last_success.deep = $Now.AddHours(-8).ToString("o")
    Update-HealthModeState $ModeState "aggressive" $Now
    Assert-Equal "aggressive" $ModeState.active_mode "切换激进模式后状态未更新"
    Assert-Equal $Now.ToString("o") $ModeState.mode_changed_at "切换激进模式后宽限基线错误"
    Assert-Equal 0 @($ModeState.active_issue_keys).Count "切换模式后旧告警未清除"
    Assert-Equal $null $ModeState.last_success.deep "切换模式后复用了旧深扫成功时间"
    $AggressiveSnapshot = $HealthySnapshots[1].PSObject.Copy()
    $AggressiveSnapshot.TaskName = "Clash Cloudflare Deep Scan 5000 30min"
    $AggressiveSnapshot.Label = "激进深度扫描"
    $AggressiveSnapshot.MaxAge = [TimeSpan]::FromHours(4)
    $AggressiveSnapshot.LastRunTime = $null
    $AggressiveSnapshot.LastTaskResult = $null
    $AggressiveAssessment = Get-HealthAssessment @($AggressiveSnapshot) $ModeState $Now $InstallDir
    Assert-Equal 0 $AggressiveAssessment.Issues.Count "刚切换激进模式时产生超时误报"

    $BadArguments = @($HealthySnapshots | ForEach-Object { $_.PSObject.Copy() })
    $BadArguments[0].Arguments = "`"$InstalledProgramPath.bak`" --quick"
    $BadArgumentsAssessment = Get-HealthAssessment $BadArguments (New-HealthState $Now) $Now $InstallDir
    if ($BadArgumentsAssessment.Issues.Key -notcontains "task.light.script_missing") {
        throw "健康监控接受了带后缀的错误脚本路径"
    }
    $BadArguments[0].Arguments = "`"$InstalledProgramPath`" --quick --extra"
    $ExtraArgumentsAssessment = Get-HealthAssessment $BadArguments (New-HealthState $Now) $Now $InstallDir
    if ($ExtraArgumentsAssessment.Issues.Key -notcontains "task.light.script_missing") {
        throw "健康监控接受了额外启动参数"
    }

    $StaleState = New-HealthState $Now.AddHours(-9)
    $StaleState.last_success.light = $Now.AddHours(-2).ToString("o")
    $StaleSnapshots = @($HealthySnapshots | ForEach-Object { $_.PSObject.Copy() })
    $StaleSnapshots[0].LastRunTime = $null
    $StaleSnapshots[0].LastTaskResult = $null
    $StaleAssessment = Get-HealthAssessment $StaleSnapshots $StaleState $Now $InstallDir
    if ($StaleAssessment.Issues.Key -notcontains "task.light.stale" -or
        $StaleAssessment.Issues.Key -notcontains "task.deep.stale") {
        throw "健康监控未识别轻扫或深扫超时"
    }

    $BrokenState = New-HealthState $Now
    $BrokenSnapshots = @($HealthySnapshots | ForEach-Object { $_.PSObject.Copy() })
    $BrokenSnapshots[0].Enabled = $false
    $BrokenSnapshots[1].Execute = Join-Path $TestRoot "missing\pythonw.exe"
    $BrokenAssessment = Get-HealthAssessment $BrokenSnapshots $BrokenState $Now $InstallDir
    if ($BrokenAssessment.Issues.Key -notcontains "task.light.disabled" -or
        $BrokenAssessment.Issues.Key -notcontains "task.deep.interpreter_missing") {
        throw "健康监控未识别禁用任务或失效解释器"
    }

    $InvalidVersionState = New-HealthState $Now
    $InvalidVersionSnapshots = @($HealthySnapshots | ForEach-Object { $_.PSObject.Copy() })
    $InvalidVersionSnapshots[0].PythonValid = $false
    $InvalidVersionSnapshots[0].PythonError = "Python 3.9.13 低于最低要求 3.10"
    $InvalidVersionAssessment = Get-HealthAssessment `
        $InvalidVersionSnapshots `
        $InvalidVersionState `
        $Now `
        $InstallDir
    if ($InvalidVersionAssessment.Issues.Key -notcontains "task.light.python_invalid") {
        throw "健康监控未识别无法运行或低版本 Python"
    }

    $AlertState = New-HealthState $Now
    $AlertKeys = @("task.light.stale")
    Assert-Equal "Alert" (Get-HealthNotificationDecision $AlertKeys @()) "新问题未触发告警"
    Update-HealthIssueState $AlertState $AlertKeys "Alert" $false
    Assert-Equal 0 @($AlertState.active_issue_keys).Count "通知失败后错误抑制了重试"
    Assert-Equal "Alert" (Get-HealthNotificationDecision $AlertKeys @($AlertState.active_issue_keys)) "通知失败后未重试"
    Update-HealthIssueState $AlertState $AlertKeys "Alert" $true
    Assert-Equal "None" (Get-HealthNotificationDecision $AlertKeys @($AlertState.active_issue_keys)) "相同告警未去重"
    Assert-Equal "Recovery" (Get-HealthNotificationDecision @() @($AlertState.active_issue_keys)) "恢复状态未触发通知"
    Update-HealthIssueState $AlertState @() "Recovery" $false
    Assert-Equal 1 @($AlertState.active_issue_keys).Count "恢复通知失败后未保留重试状态"

    # The release wizard uses this transactional path when the user chooses
    # to replace protocol or credentials. Existing provider IPs must survive,
    # while settings, template and generated Clash YAML change together.
    $ReconfigureSource = Join-Path $TestRoot "reconfigure-source"
    New-Item -ItemType Directory -Path $ReconfigureSource -Force | Out-Null
    $ReconfigureSettings = [IO.File]::ReadAllText(
        (Join-Path $ReleaseRoot "examples\settings.example.json")
    ) | ConvertFrom-Json
    $ReconfigureSettings.controller = "http://127.0.0.1:9292"
    $ReconfigureSettings.secret = "fixture-reconfigure-secret"
    $ReconfigureSettings.mixed_proxy = "http://127.0.0.1:7998"
    $ReconfigureSettingsPath = Join-Path $ReconfigureSource "settings.json"
    [IO.File]::WriteAllText(
        $ReconfigureSettingsPath,
        ($ReconfigureSettings | ConvertTo-Json -Depth 30),
        $Utf8NoBom
    )
    $ReconfigureTemplate = [IO.File]::ReadAllText(
        (Join-Path $ReleaseRoot "examples\node_template.trojan.example.json")
    ) | ConvertFrom-Json
    $ReconfigureTemplate.port = 2096
    $ReconfigureTemplate.password = "fixture-reconfigure-password"
    $ReconfigureTemplate.sni = "reconfigure.test.invalid"
    $ReconfigureTemplate.'ws-opts'.path = "/reconfigure"
    $ReconfigureTemplate.'ws-opts'.headers.Host = "reconfigure.test.invalid"
    $ReconfigureTemplatePath = Join-Path $ReconfigureSource "node_template.json"
    [IO.File]::WriteAllText(
        $ReconfigureTemplatePath,
        ($ReconfigureTemplate | ConvertTo-Json -Depth 30),
        $Utf8NoBom
    )
    $ActiveIpsBeforeReconfigure = @(
        ([IO.File]::ReadAllText($ActiveProviderPath) | ConvertFrom-Json).proxies |
            ForEach-Object { [string]$_.server }
    )
    $DiscoveryIpsBeforeReconfigure = @(
        ([IO.File]::ReadAllText($DiscoveryProviderPath) | ConvertFrom-Json).proxies |
            ForEach-Object { [string]$_.server }
    )
    $ActiveProviderBytes = [IO.File]::ReadAllBytes($ActiveProviderPath)
    $PreflightProtectedPaths = @(
        $SettingsPath,
        $NodeTemplatePath,
        $ConfigPath,
        $DiscoveryProviderPath
    )
    $PreflightProtectedHashes = @{}
    foreach ($ProtectedPath in $PreflightProtectedPaths) {
        $PreflightProtectedHashes[$ProtectedPath] = (
            Get-FileHash -Algorithm SHA256 -LiteralPath $ProtectedPath
        ).Hash
    }
    [IO.File]::WriteAllText($ActiveProviderPath, "not valid provider json", $Utf8NoBom)
    $MalformedProviderRejected = $false
    try {
        & $InstallScript `
            -SourceSettingsPath $ReconfigureSettingsPath `
            -SourceNodeTemplatePath $ReconfigureTemplatePath `
            -ReplaceInstalledConfiguration `
            -NoOpenExplorer
    } catch {
        $MalformedProviderRejected = (
            $_.Exception.Message -like "*重新配置已中止以免丢失原 IP*"
        )
    }
    Assert-Equal $true $MalformedProviderRejected "损坏的现有 provider 未阻止重新配置"
    Assert-Equal "not valid provider json" ([IO.File]::ReadAllText($ActiveProviderPath)) "provider 预检失败后仍改写了原文件"
    foreach ($ProtectedPath in $PreflightProtectedPaths) {
        Assert-Equal $PreflightProtectedHashes[$ProtectedPath] (Get-FileHash -Algorithm SHA256 -LiteralPath $ProtectedPath).Hash "provider 预检失败后修改了受保护文件：$ProtectedPath"
    }
    [IO.File]::WriteAllBytes($ActiveProviderPath, $ActiveProviderBytes)

    $ReconfigureOutput = @(
        $global:ClashCloudflareDynamicTestRunningTasks = @(
            "Clash Cloudflare Light Scan 30min"
        )
        & $InstallScript `
            -SourceSettingsPath $ReconfigureSettingsPath `
            -SourceNodeTemplatePath $ReconfigureTemplatePath `
            -ReplaceInstalledConfiguration `
            -NoOpenExplorer
    ) -join "`n"
    Assert-Equal $true ($global:ClashCloudflareDynamicTestStoppedTasks -contains "Clash Cloudflare Light Scan 30min") "重新配置前未停止正在运行的扫描任务"
    foreach ($TaskName in "Clash Cloudflare Light Scan 30min", "Clash Cloudflare Deep Scan 5000 6h", "Clash Cloudflare Health Monitor 30min") {
        Assert-Equal $true ($global:ClashCloudflareDynamicTestDisabledTasks -contains $TaskName) "重新配置期间未禁用计划任务：$TaskName"
    }
    if ($ReconfigureOutput -match "fixture-reconfigure-(secret|password)") {
        throw "重新配置输出泄露节点或 API 凭据"
    }
    $ReconfiguredSettings = [IO.File]::ReadAllText($SettingsPath) | ConvertFrom-Json
    $ReconfiguredTemplate = [IO.File]::ReadAllText($NodeTemplatePath) | ConvertFrom-Json
    Assert-Equal "http://127.0.0.1:9292" $ReconfiguredSettings.controller "重新配置未替换 controller"
    Assert-Equal "fixture-reconfigure-secret" $ReconfiguredSettings.secret "重新配置未替换 secret"
    Assert-Equal "http://127.0.0.1:7998" $ReconfiguredSettings.mixed_proxy "重新配置未替换 mixed proxy"
    Assert-Equal "trojan" $ReconfiguredTemplate.type "重新配置未替换协议"
    Assert-Equal 2096 $ReconfiguredTemplate.port "重新配置未替换端口"
    $ReconfiguredYaml = [IO.File]::ReadAllText($ConfigPath)
    if ($ReconfiguredYaml -notmatch "(?m)^mixed-port:\s*7998\s*$" -or
        $ReconfiguredYaml -notmatch "(?m)^external-controller:\s*127\.0\.0\.1:9292\s*$") {
        throw "重新配置未同步重建 Clash YAML"
    }
    $ReconfiguredActive = [IO.File]::ReadAllText($ActiveProviderPath) | ConvertFrom-Json
    $ReconfiguredDiscovery = [IO.File]::ReadAllText($DiscoveryProviderPath) | ConvertFrom-Json
    Assert-Equal ($ActiveIpsBeforeReconfigure -join ",") (@($ReconfiguredActive.proxies | ForEach-Object { $_.server }) -join ",") "重新配置未保留正式 provider IP"
    Assert-Equal ($DiscoveryIpsBeforeReconfigure -join ",") (@($ReconfiguredDiscovery.proxies | ForEach-Object { $_.server }) -join ",") "重新配置未保留发现 provider IP"
    foreach ($Proxy in @($ReconfiguredActive.proxies) + @($ReconfiguredDiscovery.proxies)) {
        Assert-Equal "trojan" $Proxy.type "provider 未使用新协议重建"
        Assert-Equal 2096 $Proxy.port "provider 未使用新端口重建"
        Assert-Equal "fixture-reconfigure-password" $Proxy.password "provider 未使用新凭据重建"
    }

    Write-Output "install_hybrid_5000.ps1 and health monitor isolation tests: OK"
} finally {
    $env:LOCALAPPDATA = $OriginalLocalAppData
    $env:APPDATA = $OriginalAppData
    if ($HadOriginalExampleConfigFlag) {
        $env:CCFD_ALLOW_EXAMPLE_CONFIG_FOR_TESTS = $OriginalExampleConfigFlag
    } else {
        Remove-Item Env:CCFD_ALLOW_EXAMPLE_CONFIG_FOR_TESTS -ErrorAction SilentlyContinue
    }
    Remove-Variable -Name ClashCloudflareDynamicTestRegisteredTasks -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable -Name ClashCloudflareDynamicTestExportFailure -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable -Name ClashCloudflareDynamicTestAggressiveOnly -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable -Name ClashCloudflareDynamicTestFailAggressiveRegistration -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable -Name ClashCloudflareDynamicTestUnregisteredTasks -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable -Name ClashCloudflareDynamicTestFailHybridTaskName -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable -Name ClashCloudflareDynamicTestMutationPaths -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable -Name ClashCloudflareDynamicTestFailUnregisterTaskName -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable -Name ClashCloudflareDynamicTestIncludeAggressiveWithHybrid -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable -Name ClashCloudflareDynamicTestRunningTasks -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable -Name ClashCloudflareDynamicTestStoppedTasks -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable -Name ClashCloudflareDynamicTestDisabledTasks -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable -Name ClashCloudflareDynamicTestStartedTasks -Scope Global -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $TestRoot) {
        $ResolvedTestRoot = [IO.Path]::GetFullPath($TestRoot)
        $ResolvedTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (-not $ResolvedTestRoot.StartsWith($ResolvedTempRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "拒绝清理非临时测试目录：$ResolvedTestRoot"
        }
        Remove-Item -LiteralPath $ResolvedTestRoot -Recurse -Force
    }
}
