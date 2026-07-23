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
            $Value -match "(?i)(^|\.)example\.(com|net|org)$") {
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
    $TempPath = Join-Path $Directory (".{0}.{1}.tmp" -f ([IO.Path]::GetFileName($Path)), [Guid]::NewGuid().ToString("N"))
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

function Show-InstallForm {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()

    $Form = New-Object Windows.Forms.Form
    $Form.Text = "Clash Cloudflare Dynamic 安装向导"
    $Form.StartPosition = "CenterScreen"
    $Form.ClientSize = New-Object Drawing.Size(650, 570)
    $Form.FormBorderStyle = "FixedDialog"
    $Form.MaximizeBox = $false
    $Form.MinimizeBox = $false
    $Form.AutoScaleMode = "Dpi"

    $Title = New-Object Windows.Forms.Label
    $Title.Text = "填写你自己的节点参数"
    $Title.Font = New-Object Drawing.Font("Microsoft YaHei UI", 14, [Drawing.FontStyle]::Bold)
    $Title.SetBounds(22, 18, 590, 32)
    $Form.Controls.Add($Title)

    $Hint = New-Object Windows.Forms.Label
    $Hint.Text = "凭据仅保存在本机；向导不会上传、输出或写入公开 Release。"
    $Hint.SetBounds(24, 54, 590, 22)
    $Form.Controls.Add($Hint)

    function Add-Label([string]$Text, [int]$Y) {
        $Label = New-Object Windows.Forms.Label
        $Label.Text = $Text
        $Label.SetBounds(24, $Y + 3, 158, 24)
        $Form.Controls.Add($Label)
    }
    function Add-TextBox([int]$Y, [string]$Text = "") {
        $TextBox = New-Object Windows.Forms.TextBox
        $TextBox.Text = $Text
        $TextBox.SetBounds(184, $Y, 430, 27)
        $Form.Controls.Add($TextBox)
        return $TextBox
    }

    Add-Label "协议" 90
    $ProtocolBox = New-Object Windows.Forms.ComboBox
    $ProtocolBox.DropDownStyle = "DropDownList"
    $null = $ProtocolBox.Items.AddRange(@("VMess", "VLESS", "Trojan", "自定义模板"))
    $ProtocolBox.SelectedIndex = 0
    $ProtocolBox.SetBounds(184, 88, 200, 28)
    $Form.Controls.Add($ProtocolBox)

    Add-Label "Cloudflare 入口端口" 128
    $PortBox = New-Object Windows.Forms.ComboBox
    $PortBox.DropDownStyle = "DropDown"
    $null = $PortBox.Items.AddRange(@("443", "2053", "2083", "2087", "2096", "8443"))
    $PortBox.Text = "443"
    $PortBox.SetBounds(184, 126, 200, 28)
    $Form.Controls.Add($PortBox)

    Add-Label "Mihomo API" 166
    $ControllerBox = Add-TextBox 164 "http://127.0.0.1:9090"
    Add-Label "Mihomo API 密钥" 204
    $SecretBox = Add-TextBox 202
    $SecretBox.UseSystemPasswordChar = $true
    Add-Label "Mixed Proxy" 242
    $MixedBox = Add-TextBox 240 "http://127.0.0.1:7890"
    Add-Label "UUID" 280
    $CredentialLabel = $Form.Controls[$Form.Controls.Count - 1]
    $CredentialBox = Add-TextBox 278
    Add-Label "SNI / Server Name" 318
    $ServerBox = Add-TextBox 316
    Add-Label "WebSocket Host" 356
    $HostBox = Add-TextBox 354
    Add-Label "WebSocket 路径" 394
    $PathBox = Add-TextBox 392 "/"
    Add-Label "自定义模板" 432
    $CustomBox = Add-TextBox 430
    $CustomBox.Width = 350
    $BrowseButton = New-Object Windows.Forms.Button
    $BrowseButton.Text = "浏览..."
    $BrowseButton.SetBounds(544, 429, 70, 29)
    $Form.Controls.Add($BrowseButton)

    $Warning = New-Object Windows.Forms.Label
    $Warning.Text = "安装后仍需在 Clash Verge Rev 导入生成的 YAML，并选择「节点选择 → 自动选择」。"
    $Warning.ForeColor = [Drawing.Color]::FromArgb(150, 85, 0)
    $Warning.SetBounds(24, 475, 590, 40)
    $Form.Controls.Add($Warning)

    $InstallButton = New-Object Windows.Forms.Button
    $InstallButton.Text = "生成配置并安装"
    $InstallButton.SetBounds(354, 520, 150, 34)
    $CancelButton = New-Object Windows.Forms.Button
    $CancelButton.Text = "取消"
    $CancelButton.SetBounds(514, 520, 100, 34)
    $CancelButton.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $Form.Controls.AddRange(@($InstallButton, $CancelButton))
    $Form.CancelButton = $CancelButton

    $UpdateProtocolControls = {
        $IsCustom = $ProtocolBox.SelectedIndex -eq 3
        $CredentialBox.Enabled = -not $IsCustom
        $ServerBox.Enabled = -not $IsCustom
        $HostBox.Enabled = -not $IsCustom
        $PathBox.Enabled = -not $IsCustom
        $CustomBox.Enabled = $IsCustom
        $BrowseButton.Enabled = $IsCustom
        $CredentialLabel.Text = switch ($ProtocolBox.SelectedIndex) {
            0 { "UUID" }
            1 { "UUID" }
            2 { "Trojan 密码" }
            default { "认证信息" }
        }
        $CredentialBox.UseSystemPasswordChar = $true
        if ($IsCustom) {
            $PortBox.Text = ""
        } elseif ([string]::IsNullOrWhiteSpace($PortBox.Text)) {
            $PortBox.Text = "443"
        }
    }
    $ProtocolBox.Add_SelectedIndexChanged($UpdateProtocolControls)
    & $UpdateProtocolControls

    $BrowseButton.Add_Click({
        $Dialog = New-Object Windows.Forms.OpenFileDialog
        $Dialog.Title = "选择 Mihomo 节点模板"
        $Dialog.Filter = "JSON 文件 (*.json)|*.json|所有文件 (*.*)|*.*"
        if ($Dialog.ShowDialog($Form) -eq [Windows.Forms.DialogResult]::OK) {
            $CustomBox.Text = $Dialog.FileName
        }
    })

    $InstallButton.Add_Click({
        try {
            $SelectedProtocol = @("vmess", "vless", "trojan", "custom")[$ProtocolBox.SelectedIndex]
            $ParsedPort = 0
            if (-not [string]::IsNullOrWhiteSpace($PortBox.Text) -and
                -not [int]::TryParse($PortBox.Text, [ref]$ParsedPort)) {
                throw "端口必须是数字。"
            }
            $Candidate = @{
                Protocol = $SelectedProtocol
                Port = $ParsedPort
                Controller = $ControllerBox.Text.Trim()
                ControllerSecret = $SecretBox.Text
                MixedProxy = $MixedBox.Text.Trim()
                Credential = $CredentialBox.Text.Trim()
                ServerName = $ServerBox.Text.Trim()
                HostName = $HostBox.Text.Trim()
                WebSocketPath = $PathBox.Text.Trim()
                CustomTemplatePath = $CustomBox.Text.Trim()
            }
            Assert-CommonInput $Candidate
            if ($Candidate.Port -gt 0 -and
                $Candidate.Port -notin $CloudflareHttpsPorts) {
                $Choice = [Windows.Forms.MessageBox]::Show(
                    "端口 $($Candidate.Port) 不在 Cloudflare 普通代理的标准 HTTPS 端口列表中。仍要继续吗？",
                    "确认非标准端口",
                    [Windows.Forms.MessageBoxButtons]::YesNo,
                    [Windows.Forms.MessageBoxIcon]::Warning
                )
                if ($Choice -ne [Windows.Forms.DialogResult]::Yes) {
                    return
                }
            }
            $script:WizardResult = $Candidate
            $Form.DialogResult = [Windows.Forms.DialogResult]::OK
            $Form.Close()
        } catch {
            [Windows.Forms.MessageBox]::Show(
                $_.Exception.Message,
                "输入有误",
                [Windows.Forms.MessageBoxButtons]::OK,
                [Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
        }
    })

    if ($Form.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) {
        return $null
    }
    return $script:WizardResult
}

function Show-Message([string]$Text, [bool]$Error = $false) {
    if ($NonInteractive) {
        if ($Error) { Write-Error $Text } else { Write-Host $Text }
        return
    }
    Add-Type -AssemblyName System.Windows.Forms
    $Icon = if ($Error) {
        [Windows.Forms.MessageBoxIcon]::Error
    } else {
        [Windows.Forms.MessageBoxIcon]::Information
    }
    [Windows.Forms.MessageBox]::Show(
        $Text,
        "Clash Cloudflare Dynamic",
        [Windows.Forms.MessageBoxButtons]::OK,
        $Icon
    ) | Out-Null
}

try {
    if (-not (Test-Path -LiteralPath $InstallerPath -PathType Leaf)) {
        throw "Release 缺少 install_hybrid_5000.ps1。"
    }
    $HasExistingConfiguration = (
        (Test-Path -LiteralPath $InstalledSettingsPath -PathType Leaf) -and
        (Test-Path -LiteralPath $InstalledNodeTemplatePath -PathType Leaf)
    )
    $HasExistingInstall = Test-Path -LiteralPath $InstalledRoot -PathType Container
    if (-not $NonInteractive -and $HasExistingConfiguration) {
        Add-Type -AssemblyName System.Windows.Forms
        $ExistingChoice = [Windows.Forms.MessageBox]::Show(
            "检测到已有本地配置。选择「是」将保留现有协议和凭据直接安装；选择「否」重新填写并备份旧配置。",
            "使用现有配置？",
            [Windows.Forms.MessageBoxButtons]::YesNoCancel,
            [Windows.Forms.MessageBoxIcon]::Question
        )
        if ($ExistingChoice -eq [Windows.Forms.DialogResult]::Cancel) {
            exit 0
        }
        $UseExistingConfiguration = $ExistingChoice -eq [Windows.Forms.DialogResult]::Yes
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
    $InstalledConfig = Join-Path $env:LOCALAPPDATA "ClashCloudflareDynamic\clash_cloudflare_dynamic_verge_safe.yaml"
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
                try {
                    Add-Type -AssemblyName System.Windows.Forms
                    [Windows.Forms.MessageBox]::Show(
                        $CleanupFailureMessage,
                        "需要清理临时配置",
                        [Windows.Forms.MessageBoxButtons]::OK,
                        [Windows.Forms.MessageBoxIcon]::Warning
                    ) | Out-Null
                } catch {
                    Write-Warning $CleanupFailureMessage
                }
            }
        }
    }
}
