#requires -Version 5.1
param(
    [switch]$NonInteractive,
    [switch]$PrepareOnly,
    [switch]$UseExistingConfiguration,
    [ValidateSet("vmess", "vless", "trojan", "custom")]
    [string]$Protocol = "vmess",
    [int]$Port = 0,
    [string]$Controller = "http://127.0.0.1:9090",
    [string]$ControllerSecret = "",
    [string]$MixedProxy = "http://127.0.0.1:7890",
    [string]$Credential = "",
    [string]$ServerName = "",
    [string]$HostName = "",
    [string]$WebSocketPath = "",
    [string]$CustomTemplatePath = "",
    [string]$PreparedConfigurationDirectory = ""
)

$ErrorActionPreference = "Stop"
$ScriptRoot = $PSScriptRoot
$RepositoryRootCandidate = [IO.Path]::GetFullPath((Join-Path $ScriptRoot "..\.."))
$RepositoryScriptsCandidate = Join-Path $RepositoryRootCandidate "scripts\windows"
$IsRepositoryLayout = (
    [IO.Path]::GetFullPath($ScriptRoot).Equals(
        [IO.Path]::GetFullPath($RepositoryScriptsCandidate),
        [StringComparison]::OrdinalIgnoreCase
    ) -and
    (Test-Path -LiteralPath (Join-Path $RepositoryRootCandidate "examples") -PathType Container)
)
$Root = if ($IsRepositoryLayout) { $RepositoryRootCandidate } else { $ScriptRoot }
$ExamplesRoot = Join-Path $Root "examples"
$InstallerPath = Join-Path $ScriptRoot "install_hybrid_5000.ps1"
$InstalledRoot = Join-Path $env:LOCALAPPDATA "ClashCloudflareDynamic"
$InstalledSettingsPath = Join-Path $InstalledRoot "settings.json"
$InstalledNodeTemplatePath = Join-Path $InstalledRoot "node_template.json"
$CloudflareHttpsPorts = @(443, 2053, 2083, 2087, 2096, 8443)
$Utf8NoBom = New-Object Text.UTF8Encoding($false)
$OwnedStagePath = $null

function Test-LoopbackHttpUri([string]$Value) {
    $Parsed = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$Parsed)) {
        return $false
    }
    if ($Parsed.Scheme -notin @("http", "https")) {
        return $false
    }
    return $Parsed.IsLoopback
}

function Assert-CommonInput([hashtable]$InputData) {
    if (-not (Test-LoopbackHttpUri $InputData.Controller)) {
        throw "Mihomo API 必须是本机 HTTP(S) 地址，例如 http://127.0.0.1:9090。"
    }
    if (-not (Test-LoopbackHttpUri $InputData.MixedProxy)) {
        throw "Mixed Proxy 必须是本机 HTTP(S) 地址，例如 http://127.0.0.1:7890。"
    }
    if ($InputData.Port -lt 0 -or $InputData.Port -gt 65535) {
        throw "端口必须为 1 到 65535；自定义模板可使用 0 表示保留模板端口。"
    }
    if ($InputData.Protocol -ne "custom" -and $InputData.Port -eq 0) {
        $InputData.Port = 443
    }
    if ($InputData.Protocol -eq "custom") {
        if ([string]::IsNullOrWhiteSpace($InputData.CustomTemplatePath) -or
            -not (Test-Path -LiteralPath $InputData.CustomTemplatePath -PathType Leaf)) {
            throw "请选择存在的自定义 Mihomo 节点模板。"
        }
        return
    }

    if ($InputData.Protocol -in @("vmess", "vless")) {
        $Uuid = [Guid]::Empty
        if (-not [Guid]::TryParse($InputData.Credential, [ref]$Uuid) -or
            $Uuid -eq [Guid]::Empty) {
            throw "$($InputData.Protocol.ToUpperInvariant()) 必须填写非零 UUID。"
        }
    } elseif ([string]::IsNullOrWhiteSpace($InputData.Credential) -or
        $InputData.Credential -eq "replace-with-your-password") {
        throw "Trojan 必须填写真实密码。"
    }

    foreach ($FieldName in @("ServerName", "HostName")) {
        $Value = [string]$InputData[$FieldName]
        if ([string]::IsNullOrWhiteSpace($Value) -or
            $Value -match "(?i)(^|\.)example\.(com|net|org)$|\.example$") {
            throw "$FieldName 必须填写节点实际使用的域名。"
        }
    }
    if ([string]::IsNullOrWhiteSpace($InputData.WebSocketPath) -or
        -not $InputData.WebSocketPath.StartsWith("/") -or
        $InputData.WebSocketPath -eq "/your-websocket-path") {
        throw "WebSocket 路径必须以 / 开头，并且不能使用示例占位值。"
    }
}

function Read-JsonObject([string]$Path) {
    try {
        return [IO.File]::ReadAllText($Path) | ConvertFrom-Json
    } catch {
        throw "无法解析 JSON $Path：$($_.Exception.Message)"
    }
}

function Write-JsonAtomic([string]$Path, [object]$Value) {
    $Directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        throw "配置目录不存在：$Directory"
    }
    $TempPath = Join-Path $Directory (
        ".{0}.{1}.tmp" -f
        ([IO.Path]::GetFileName($Path)),
        [Guid]::NewGuid().ToString("N")
    )
    $ReplaceBackupPath = "$TempPath.replace.bak"
    try {
        [IO.File]::WriteAllText(
            $TempPath,
            ($Value | ConvertTo-Json -Depth 30),
            $Utf8NoBom
        )
        $null = Read-JsonObject $TempPath
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            [IO.File]::Replace($TempPath, $Path, $ReplaceBackupPath)
        } else {
            [IO.File]::Move($TempPath, $Path)
        }
    } finally {
        if (Test-Path -LiteralPath $TempPath) {
            [IO.File]::Delete($TempPath)
        }
        if (Test-Path -LiteralPath $ReplaceBackupPath) {
            [IO.File]::Delete($ReplaceBackupPath)
        }
    }
}

function Backup-LocalConfiguration([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    $Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $BackupPath = "$Path.backup-$Stamp"
    $Suffix = 1
    while (Test-Path -LiteralPath $BackupPath) {
        $BackupPath = "$Path.backup-$Stamp-$Suffix"
        $Suffix += 1
    }
    Copy-Item -LiteralPath $Path -Destination $BackupPath
    return $BackupPath
}

function Protect-ConfigurationDirectory([string]$Path) {
    $CurrentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $SystemSid = New-Object Security.Principal.SecurityIdentifier("S-1-5-18")
    $Rights = [Security.AccessControl.FileSystemRights]::FullControl
    $Inheritance = (
        [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [Security.AccessControl.InheritanceFlags]::ObjectInherit
    )
    $Propagation = [Security.AccessControl.PropagationFlags]::None
    $Allow = [Security.AccessControl.AccessControlType]::Allow
    $Security = New-Object Security.AccessControl.DirectorySecurity
    $Security.SetAccessRuleProtection($true, $false)
    foreach ($Sid in @($CurrentSid, $SystemSid)) {
        $Rule = New-Object Security.AccessControl.FileSystemAccessRule(
            $Sid,
            $Rights,
            $Inheritance,
            $Propagation,
            $Allow
        )
        $Security.AddAccessRule($Rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $Security
}

function New-NodeTemplate([hashtable]$InputData) {
    if ($InputData.Protocol -eq "custom") {
        $Template = Read-JsonObject $InputData.CustomTemplatePath
        $TemplateType = [string]$Template.type
        $TemplatePort = 0
        if ([string]::IsNullOrWhiteSpace($TemplateType) -or
            -not [int]::TryParse([string]$Template.port, [ref]$TemplatePort) -or
            $TemplatePort -lt 1 -or $TemplatePort -gt 65535) {
            throw "自定义模板必须包含有效的 type 和 1 到 65535 端口。"
        }
        if ($InputData.Port -gt 0) {
            $Template.port = $InputData.Port
        }
        return $Template
    }

    $WsOptions = [ordered]@{
        path = $InputData.WebSocketPath
        headers = [ordered]@{ Host = $InputData.HostName }
    }
    if ($InputData.Protocol -eq "trojan") {
        return [ordered]@{
            type = "trojan"
            port = $InputData.Port
            password = $InputData.Credential
            udp = $true
            sni = $InputData.ServerName
            network = "ws"
            "ws-opts" = $WsOptions
        }
    }
    $Template = [ordered]@{
        type = $InputData.Protocol
        port = $InputData.Port
        uuid = $InputData.Credential
    }
    if ($InputData.Protocol -eq "vmess") {
        $Template.alterId = 0
        $Template.cipher = "auto"
    }
    $Template.udp = $true
    $Template.tls = $true
    $Template.network = "ws"
    $Template.servername = $InputData.ServerName
    $Template["ws-opts"] = $WsOptions
    return $Template
}

function Save-PreparedConfiguration(
    [hashtable]$InputData,
    [string]$TargetSettingsPath,
    [string]$TargetNodeTemplatePath
) {
    Assert-CommonInput $InputData
    $SettingsExamplePath = Join-Path $ExamplesRoot "settings.example.json"
    if (-not (Test-Path -LiteralPath $SettingsExamplePath -PathType Leaf)) {
        throw "Release 缺少 examples\settings.example.json。"
    }
    $Settings = Read-JsonObject $SettingsExamplePath
    $Settings.controller = $InputData.Controller
    $Settings.secret = $InputData.ControllerSecret
    $Settings.mixed_proxy = $InputData.MixedProxy
    $Template = New-NodeTemplate $InputData

    $SettingsExisted = Test-Path -LiteralPath $TargetSettingsPath -PathType Leaf
    $TemplateExisted = Test-Path -LiteralPath $TargetNodeTemplatePath -PathType Leaf
    $SettingsBackup = Backup-LocalConfiguration $TargetSettingsPath
    $TemplateBackup = Backup-LocalConfiguration $TargetNodeTemplatePath
    try {
        Write-JsonAtomic $TargetSettingsPath $Settings
        Write-JsonAtomic $TargetNodeTemplatePath $Template
    } catch {
        foreach ($Pair in @(
            @{ Target = $TargetSettingsPath; Backup = $SettingsBackup; Existed = $SettingsExisted },
            @{ Target = $TargetNodeTemplatePath; Backup = $TemplateBackup; Existed = $TemplateExisted }
        )) {
            if ($Pair.Backup -and (Test-Path -LiteralPath $Pair.Backup -PathType Leaf)) {
                Copy-Item -LiteralPath $Pair.Backup -Destination $Pair.Target -Force
            } elseif (-not $Pair.Existed -and (Test-Path -LiteralPath $Pair.Target)) {
                [IO.File]::Delete($Pair.Target)
            }
        }
        throw
    }
    return $Template
}

try {
    $WpfUiPath = Join-Path $ScriptRoot "install_wizard_ui.ps1"
    if (-not (Test-Path -LiteralPath $WpfUiPath -PathType Leaf)) {
        throw "Release 缺少 install_wizard_ui.ps1。"
    }
    . $WpfUiPath

    if (-not (Test-Path -LiteralPath $InstallerPath -PathType Leaf)) {
        throw "Release 缺少 install_hybrid_5000.ps1。"
    }
    $HasExistingConfiguration = (
        (Test-Path -LiteralPath $InstalledSettingsPath -PathType Leaf) -and
        (Test-Path -LiteralPath $InstalledNodeTemplatePath -PathType Leaf)
    )
    $HasExistingInstall = Test-Path -LiteralPath $InstalledRoot -PathType Container
    if (-not $NonInteractive -and $HasExistingConfiguration) {
        $ExistingChoice = Show-ExistingConfigurationChoice
        if ($ExistingChoice -eq "cancel") {
            exit 0
        }
        $UseExistingConfiguration = $ExistingChoice -eq "keep"
    }

    if ($UseExistingConfiguration) {
        if (-not $HasExistingConfiguration) {
            throw "本机安装目录没有可使用的 settings.json 和 node_template.json。"
        }
        $PreparedSettingsPath = $InstalledSettingsPath
        $PreparedNodeTemplatePath = $InstalledNodeTemplatePath
        $PreparedTemplate = Read-JsonObject $PreparedNodeTemplatePath
    } else {
        $InputData = if ($NonInteractive) {
            @{
                Protocol = $Protocol
                Port = $Port
                Controller = $Controller
                ControllerSecret = $ControllerSecret
                MixedProxy = $MixedProxy
                Credential = $Credential
                ServerName = $ServerName
                HostName = $HostName
                WebSocketPath = $WebSocketPath
                CustomTemplatePath = $CustomTemplatePath
            }
        } else {
            Show-InstallForm
        }
        if ($null -eq $InputData) {
            exit 0
        }
        if ($PrepareOnly) {
            if ([string]::IsNullOrWhiteSpace($PreparedConfigurationDirectory)) {
                throw "PrepareOnly 必须同时指定 PreparedConfigurationDirectory。"
            }
            $StagePath = [IO.Path]::GetFullPath($PreparedConfigurationDirectory)
            New-Item -ItemType Directory -Path $StagePath -Force | Out-Null
        } else {
            $StagePath = Join-Path $env:TEMP (
                "ClashCloudflareDynamicInstaller-" + [Guid]::NewGuid().ToString("N")
            )
            New-Item -ItemType Directory -Path $StagePath | Out-Null
            $ResolvedStage = (Resolve-Path -LiteralPath $StagePath).Path
            $ResolvedTemp = (Resolve-Path -LiteralPath $env:TEMP).Path
            if (-not $ResolvedStage.StartsWith(
                $ResolvedTemp + [IO.Path]::DirectorySeparatorChar,
                [StringComparison]::OrdinalIgnoreCase
            )) {
                throw "临时配置目录超出用户 TEMP：$ResolvedStage"
            }
            $OwnedStagePath = $ResolvedStage
        }
        Protect-ConfigurationDirectory $StagePath
        $PreparedSettingsPath = Join-Path $StagePath "settings.json"
        $PreparedNodeTemplatePath = Join-Path $StagePath "node_template.json"
        $PreparedTemplate = Save-PreparedConfiguration `
            $InputData `
            $PreparedSettingsPath `
            $PreparedNodeTemplatePath
    }

    $PreparedProtocol = [string]$PreparedTemplate.type
    $PreparedPort = [int]$PreparedTemplate.port
    Write-Host "配置已准备：协议 $PreparedProtocol，端口 $PreparedPort。" -ForegroundColor Cyan
    Write-Host "敏感字段未输出；配置只进入受保护临时目录和本机安装目录。"

    if ($PrepareOnly) {
        Write-Host "PrepareOnly 完成，未修改计划任务或安装目录。"
        exit 0
    }

    $InstallerArguments = @{
        NoOpenExplorer = $true
        SourceSettingsPath = $PreparedSettingsPath
        SourceNodeTemplatePath = $PreparedNodeTemplatePath
    }
    if (-not $UseExistingConfiguration -and $HasExistingInstall) {
        $InstallerArguments.ReplaceInstalledConfiguration = $true
    }
    & $InstallerPath @InstallerArguments
    if (-not $?) {
        throw "安装脚本返回失败。"
    }
    $InstalledConfig = Join-Path $env:LOCALAPPDATA (
        "ClashCloudflareDynamic\clash_cloudflare_dynamic_verge_safe.yaml"
    )
    Show-Message (
        "安装完成。`n`n请在 Clash Verge Rev 中导入：`n$InstalledConfig`n`n" +
        "然后选择：节点选择 → 自动选择。"
    )
    if (-not $NonInteractive -and (Test-Path -LiteralPath $InstalledConfig -PathType Leaf)) {
        try {
            Start-Process explorer.exe -ArgumentList "/select,`"$InstalledConfig`""
        } catch {
            Write-Warning "无法自动打开安装目录；请手工打开：$InstalledConfig"
        }
    }
    exit 0
} catch {
    $Message = "安装向导失败：$($_.Exception.Message)"
    try { Show-Message $Message $true } catch { Write-Error $Message }
    exit 1
} finally {
    if ($OwnedStagePath -and (Test-Path -LiteralPath $OwnedStagePath -PathType Container)) {
        $CleanupFailureMessage = $null
        try {
            $ResolvedStage = (Resolve-Path -LiteralPath $OwnedStagePath).Path
            $ResolvedTemp = (Resolve-Path -LiteralPath $env:TEMP).Path
            if (-not $ResolvedStage.StartsWith(
                $ResolvedTemp + [IO.Path]::DirectorySeparatorChar,
                [StringComparison]::OrdinalIgnoreCase
            )) {
                throw "拒绝清理非 TEMP 目录：$ResolvedStage"
            }
            for ($Attempt = 1; $Attempt -le 3; $Attempt += 1) {
                try {
                    [IO.Directory]::Delete($ResolvedStage, $true)
                    break
                } catch {
                    if ($Attempt -eq 3) {
                        throw
                    }
                    Start-Sleep -Milliseconds 200
                }
            }
        } catch {
            $CleanupFailureMessage = (
                "临时配置清理失败。该目录受当前用户 ACL 保护，但可能包含节点凭据；" +
                "请手工删除：$OwnedStagePath"
            )
        }
        if ($CleanupFailureMessage) {
            if ($NonInteractive) {
                Write-Warning $CleanupFailureMessage
            } else {
                try { Show-Message $CleanupFailureMessage $true } catch {
                    Write-Warning $CleanupFailureMessage
                }
            }
        }
    }
}
