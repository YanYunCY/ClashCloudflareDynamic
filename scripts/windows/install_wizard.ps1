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

    $PageColor = [Drawing.Color]::FromArgb(246, 248, 252)
    $CardColor = [Drawing.Color]::White
    $SidebarColor = [Drawing.Color]::FromArgb(15, 23, 42)
    $SidebarMuted = [Drawing.Color]::FromArgb(148, 163, 184)
    $TextColor = [Drawing.Color]::FromArgb(15, 23, 42)
    $MutedColor = [Drawing.Color]::FromArgb(100, 116, 139)
    $BorderColor = [Drawing.Color]::FromArgb(226, 232, 240)
    $AccentColor = [Drawing.Color]::FromArgb(37, 99, 235)
    $AccentSoft = [Drawing.Color]::FromArgb(239, 246, 255)
    $SuccessSoft = [Drawing.Color]::FromArgb(240, 253, 244)
    $SuccessColor = [Drawing.Color]::FromArgb(22, 101, 52)
    $ErrorColor = [Drawing.Color]::FromArgb(185, 28, 28)
    $FontFamily = "Microsoft YaHei UI"

    function New-UiFont(
        [float]$Size,
        [Drawing.FontStyle]$Style = [Drawing.FontStyle]::Regular
    ) {
        return New-Object Drawing.Font(
            $FontFamily,
            $Size,
            $Style,
            [Drawing.GraphicsUnit]::Point
        )
    }

    function New-UiLabel(
        $Parent,
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$Width,
        [int]$Height,
        [float]$Size = 9.0,
        [bool]$Bold = $false,
        $Color = $TextColor
    ) {
        $Label = New-Object Windows.Forms.Label
        $Label.Text = $Text
        $Label.ForeColor = $Color
        $Style = if ($Bold) {
            [Drawing.FontStyle]::Bold
        } else {
            [Drawing.FontStyle]::Regular
        }
        $Label.Font = New-UiFont $Size $Style
        $Label.SetBounds($X, $Y, $Width, $Height)
        $Label.AutoEllipsis = $true
        [void]$Parent.Controls.Add($Label)
        return $Label
    }

    function New-UiTextBox(
        $Parent,
        [int]$X,
        [int]$Y,
        [int]$Width,
        [string]$Text = ""
    ) {
        $TextBox = New-Object Windows.Forms.TextBox
        $TextBox.Text = $Text
        $TextBox.Font = New-UiFont 9.5
        $TextBox.BorderStyle = [Windows.Forms.BorderStyle]::FixedSingle
        $TextBox.BackColor = $CardColor
        $TextBox.ForeColor = $TextColor
        $TextBox.SetBounds($X, $Y, $Width, 30)
        [void]$Parent.Controls.Add($TextBox)
        return $TextBox
    }

    function New-UiButton(
        $Parent,
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$Width,
        [int]$Height,
        $BackColor,
        $ForeColor
    ) {
        $Button = New-Object Windows.Forms.Button
        $Button.Text = $Text
        $Button.Font = New-UiFont 9.5 ([Drawing.FontStyle]::Bold)
        $Button.FlatStyle = [Windows.Forms.FlatStyle]::Flat
        $Button.FlatAppearance.BorderSize = 0
        $Button.BackColor = $BackColor
        $Button.ForeColor = $ForeColor
        $Button.Cursor = [Windows.Forms.Cursors]::Hand
        $Button.SetBounds($X, $Y, $Width, $Height)
        [void]$Parent.Controls.Add($Button)
        return $Button
    }

    function New-Card($Parent, [int]$X, [int]$Y, [int]$Width, [int]$Height) {
        $Card = New-Object Windows.Forms.Panel
        $Card.BackColor = $CardColor
        $Card.BorderStyle = [Windows.Forms.BorderStyle]::FixedSingle
        $Card.SetBounds($X, $Y, $Width, $Height)
        [void]$Parent.Controls.Add($Card)
        return $Card
    }

    $Form = New-Object Windows.Forms.Form
    $Form.Text = "Clash Cloudflare Dynamic 安装向导"
    $Form.StartPosition = [Windows.Forms.FormStartPosition]::CenterScreen
    $WorkingArea = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $InitialWidth = [Math]::Min(960, [Math]::Max(700, $WorkingArea.Width - 40))
    $InitialHeight = [Math]::Min(660, [Math]::Max(480, $WorkingArea.Height - 60))
    $Form.ClientSize = New-Object Drawing.Size($InitialWidth, $InitialHeight)
    $Form.MinimumSize = New-Object Drawing.Size(720, 520)
    $Form.FormBorderStyle = [Windows.Forms.FormBorderStyle]::Sizable
    $Form.MaximizeBox = $true
    $Form.MinimizeBox = $true
    $Form.AutoScaleMode = [Windows.Forms.AutoScaleMode]::Dpi
    $Form.AutoScaleDimensions = New-Object Drawing.SizeF(96.0, 96.0)
    $Form.AutoScroll = $true
    $Form.AutoScrollMinSize = New-Object Drawing.Size(960, 660)
    $Form.Font = New-UiFont 9.0
    $Form.BackColor = $PageColor

    $Sidebar = New-Object Windows.Forms.Panel
    $Sidebar.SetBounds(0, 0, 240, 660)
    $Sidebar.Anchor = (
        [Windows.Forms.AnchorStyles]::Top -bor
        [Windows.Forms.AnchorStyles]::Bottom -bor
        [Windows.Forms.AnchorStyles]::Left
    )
    $Sidebar.BackColor = $SidebarColor
    $Sidebar.TabStop = $false
    [void]$Form.Controls.Add($Sidebar)

    $BrandMark = New-Object Windows.Forms.Label
    $BrandMark.Text = "CF"
    $BrandMark.TextAlign = [Drawing.ContentAlignment]::MiddleCenter
    $BrandMark.Font = New-UiFont 12 ([Drawing.FontStyle]::Bold)
    $BrandMark.BackColor = $AccentColor
    $BrandMark.ForeColor = [Drawing.Color]::White
    $BrandMark.SetBounds(24, 28, 42, 42)
    [void]$Sidebar.Controls.Add($BrandMark)
    $null = New-UiLabel $Sidebar "Clash Cloudflare" 78 28 140 24 11 $true ([Drawing.Color]::White)
    $null = New-UiLabel $Sidebar "Dynamic Installer" 78 52 140 20 8.5 $false $SidebarMuted
    $null = New-UiLabel $Sidebar "安装进度" 24 106 180 22 8.5 $true $SidebarMuted

    $StepDefinitions = @(
        @{ Number = "01"; Title = "连接与协议"; Detail = "Mihomo 与入口设置" },
        @{ Number = "02"; Title = "节点参数"; Detail = "认证、SNI 与传输" },
        @{ Number = "03"; Title = "确认安装"; Detail = "脱敏检查后写入" }
    )
    $StepViews = @()
    for ($Index = 0; $Index -lt $StepDefinitions.Count; $Index += 1) {
        $Y = 142 + ($Index * 86)
        $Indicator = New-Object Windows.Forms.Panel
        $Indicator.BackColor = $SidebarColor
        $Indicator.SetBounds(0, $Y - 8, 4, 66)
        [void]$Sidebar.Controls.Add($Indicator)
        $Number = New-UiLabel $Sidebar $StepDefinitions[$Index].Number 24 $Y 38 30 9.5 $true $SidebarMuted
        $Number.TextAlign = [Drawing.ContentAlignment]::MiddleCenter
        $Number.BackColor = [Drawing.Color]::FromArgb(30, 41, 59)
        $Title = New-UiLabel $Sidebar $StepDefinitions[$Index].Title 76 ($Y - 1) 140 25 10 $true ([Drawing.Color]::White)
        $Detail = New-UiLabel $Sidebar $StepDefinitions[$Index].Detail 76 ($Y + 25) 140 22 8.2 $false $SidebarMuted
        $StepViews += [PSCustomObject]@{
            Indicator = $Indicator
            Number = $Number
            Title = $Title
            Detail = $Detail
        }
    }

    $PrivacyPanel = New-Object Windows.Forms.Panel
    $PrivacyPanel.BackColor = [Drawing.Color]::FromArgb(30, 41, 59)
    $PrivacyPanel.SetBounds(20, 522, 200, 108)
    [void]$Sidebar.Controls.Add($PrivacyPanel)
    $null = New-UiLabel $PrivacyPanel "本地隐私保护" 16 14 168 24 9.5 $true ([Drawing.Color]::White)
    $PrivacyText = New-UiLabel $PrivacyPanel "凭据仅写入受保护的临时目录和本机安装目录，不会上传。" 16 42 168 54 8.2 $false $SidebarMuted
    $PrivacyText.AutoEllipsis = $false

    $MainPanel = New-Object Windows.Forms.Panel
    $MainPanel.SetBounds(240, 0, 720, 660)
    $MainPanel.Anchor = (
        [Windows.Forms.AnchorStyles]::Top -bor
        [Windows.Forms.AnchorStyles]::Bottom -bor
        [Windows.Forms.AnchorStyles]::Left -bor
        [Windows.Forms.AnchorStyles]::Right
    )
    $MainPanel.BackColor = $PageColor
    $MainPanel.TabIndex = 0
    [void]$Form.Controls.Add($MainPanel)

    $Header = New-Object Windows.Forms.Panel
    $Header.SetBounds(0, 0, 720, 76)
    $Header.Anchor = (
        [Windows.Forms.AnchorStyles]::Top -bor
        [Windows.Forms.AnchorStyles]::Left -bor
        [Windows.Forms.AnchorStyles]::Right
    )
    $Header.BackColor = $PageColor
    $Header.TabStop = $false
    [void]$MainPanel.Controls.Add($Header)
    $HeaderTitle = New-UiLabel $Header "连接与协议" 28 18 430 30 17 $true $TextColor
    $HeaderHint = New-UiLabel $Header "配置 Mihomo 本地连接与 Cloudflare 入口" 28 49 520 21 8.7 $false $MutedColor
    $PageBadge = New-UiLabel $Header "步骤 1 / 3" 590 25 100 24 8.5 $true $AccentColor
    $PageBadge.TextAlign = [Drawing.ContentAlignment]::MiddleRight

    $Footer = New-Object Windows.Forms.Panel
    $Footer.SetBounds(0, 584, 720, 76)
    $Footer.Anchor = (
        [Windows.Forms.AnchorStyles]::Bottom -bor
        [Windows.Forms.AnchorStyles]::Left -bor
        [Windows.Forms.AnchorStyles]::Right
    )
    $Footer.BackColor = $CardColor
    $Footer.TabIndex = 1
    [void]$MainPanel.Controls.Add($Footer)
    $FooterBorder = New-Object Windows.Forms.Panel
    $FooterBorder.Dock = [Windows.Forms.DockStyle]::Top
    $FooterBorder.Height = 1
    $FooterBorder.BackColor = $BorderColor
    [void]$Footer.Controls.Add($FooterBorder)
    $ErrorLabel = New-UiLabel $Footer "" 28 14 315 48 8.4 $false $ErrorColor
    $ErrorLabel.AutoEllipsis = $false
    $ErrorLabel.AccessibleName = "输入错误"
    $ErrorLabel.Cursor = [Windows.Forms.Cursors]::Hand
    $ErrorToolTip = New-Object Windows.Forms.ToolTip
    $ErrorToolTip.SetToolTip($ErrorLabel, "单击复制完整错误信息")
    $CancelButton = New-UiButton $Footer "取消" 350 18 94 40 $CardColor $MutedColor
    $CancelButton.FlatAppearance.BorderSize = 1
    $CancelButton.FlatAppearance.BorderColor = $BorderColor
    $BackButton = New-UiButton $Footer "返回" 454 18 94 40 $AccentSoft $AccentColor
    $NextButton = New-UiButton $Footer "继续" 558 18 134 40 $AccentColor ([Drawing.Color]::White)
    $CancelButton.TabIndex = 0
    $BackButton.TabIndex = 1
    $NextButton.TabIndex = 2
    $CancelButton.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $Form.CancelButton = $CancelButton
    $Form.AcceptButton = $NextButton

    $PageHost = New-Object Windows.Forms.Panel
    $PageHost.SetBounds(0, 76, 720, 508)
    $PageHost.Anchor = (
        [Windows.Forms.AnchorStyles]::Top -bor
        [Windows.Forms.AnchorStyles]::Bottom -bor
        [Windows.Forms.AnchorStyles]::Left -bor
        [Windows.Forms.AnchorStyles]::Right
    )
    $PageHost.BackColor = $PageColor
    $PageHost.TabIndex = 0
    [void]$MainPanel.Controls.Add($PageHost)

    $ConnectionPage = New-Object Windows.Forms.Panel
    $ConnectionPage.Dock = [Windows.Forms.DockStyle]::Fill
    $ConnectionPage.BackColor = $PageColor
    [void]$PageHost.Controls.Add($ConnectionPage)
    $ConnectionCard = New-Card $ConnectionPage 28 6 664 336

    $null = New-UiLabel $ConnectionCard "节点协议" 22 16 290 22 8.5 $true $MutedColor
    $ProtocolBox = New-Object Windows.Forms.ComboBox
    $ProtocolBox.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDownList
    $ProtocolBox.FlatStyle = [Windows.Forms.FlatStyle]::Flat
    $ProtocolBox.Font = New-UiFont 9.5
    $null = $ProtocolBox.Items.AddRange(@("VMess", "VLESS", "Trojan", "自定义模板"))
    $ProtocolBox.SelectedIndex = 0
    $ProtocolBox.SetBounds(22, 42, 292, 30)
    $ProtocolBox.TabIndex = 0
    $ProtocolBox.AccessibleName = "节点协议"
    [void]$ConnectionCard.Controls.Add($ProtocolBox)

    $null = New-UiLabel $ConnectionCard "Cloudflare 入口端口" 340 16 290 22 8.5 $true $MutedColor
    $PortBox = New-Object Windows.Forms.ComboBox
    $PortBox.DropDownStyle = [Windows.Forms.ComboBoxStyle]::DropDown
    $PortBox.FlatStyle = [Windows.Forms.FlatStyle]::Flat
    $PortBox.Font = New-UiFont 9.5
    $null = $PortBox.Items.AddRange(@("443", "2053", "2083", "2087", "2096", "8443"))
    $PortBox.Text = "443"
    $PortBox.SetBounds(340, 42, 292, 30)
    $PortBox.TabIndex = 1
    $PortBox.AccessibleName = "Cloudflare 入口端口"
    [void]$ConnectionCard.Controls.Add($PortBox)

    $null = New-UiLabel $ConnectionCard "Mihomo API" 22 91 610 22 8.5 $true $MutedColor
    $ControllerBox = New-UiTextBox $ConnectionCard 22 116 610 "http://127.0.0.1:9090"
    $ControllerBox.TabIndex = 2
    $ControllerBox.AccessibleName = "Mihomo API"
    $null = New-UiLabel $ConnectionCard "外部控制必须已在 Clash Verge Rev 中启用" 22 148 610 19 8 $false $MutedColor

    $null = New-UiLabel $ConnectionCard "Mihomo API 密钥（可选）" 22 176 610 22 8.5 $true $MutedColor
    $SecretBox = New-UiTextBox $ConnectionCard 22 201 610
    $SecretBox.UseSystemPasswordChar = $true
    $SecretBox.TabIndex = 3
    $SecretBox.AccessibleName = "Mihomo API 密钥"

    $null = New-UiLabel $ConnectionCard "Mixed Proxy" 22 253 610 22 8.5 $true $MutedColor
    $MixedBox = New-UiTextBox $ConnectionCard 22 278 610 "http://127.0.0.1:7890"
    $MixedBox.TabIndex = 4
    $MixedBox.AccessibleName = "Mixed Proxy"

    $ConnectionInfo = New-Object Windows.Forms.Panel
    $ConnectionInfo.BackColor = $AccentSoft
    $ConnectionInfo.SetBounds(28, 354, 664, 62)
    [void]$ConnectionPage.Controls.Add($ConnectionInfo)
    $null = New-UiLabel $ConnectionInfo "仅允许本机访问" 18 10 180 22 8.8 $true $AccentColor
    $ConnectionInfoText = New-UiLabel $ConnectionInfo "建议保持 127.0.0.1；不要把 Mihomo 外部控制端口暴露到局域网或公网。" 18 32 620 22 8.2 $false $MutedColor
    $ConnectionInfoText.AutoEllipsis = $false

    $NodePage = New-Object Windows.Forms.Panel
    $NodePage.Dock = [Windows.Forms.DockStyle]::Fill
    $NodePage.BackColor = $PageColor
    [void]$PageHost.Controls.Add($NodePage)
    $NodeCard = New-Card $NodePage 28 6 664 370

    $CredentialLabel = New-UiLabel $NodeCard "UUID" 22 16 610 22 8.5 $true $MutedColor
    $CredentialBox = New-UiTextBox $NodeCard 22 41 610
    $CredentialBox.UseSystemPasswordChar = $true
    $CredentialBox.TabIndex = 0
    $CredentialBox.AccessibleName = "节点认证"

    $null = New-UiLabel $NodeCard "SNI / Server Name" 22 92 292 22 8.5 $true $MutedColor
    $ServerBox = New-UiTextBox $NodeCard 22 117 292
    $ServerBox.TabIndex = 1
    $ServerBox.AccessibleName = "SNI Server Name"
    $null = New-UiLabel $NodeCard "WebSocket Host" 340 92 292 22 8.5 $true $MutedColor
    $HostBox = New-UiTextBox $NodeCard 340 117 292
    $HostBox.TabIndex = 2
    $HostBox.AccessibleName = "WebSocket Host"

    $null = New-UiLabel $NodeCard "WebSocket 路径" 22 168 610 22 8.5 $true $MutedColor
    $PathBox = New-UiTextBox $NodeCard 22 193 610 "/"
    $PathBox.TabIndex = 3
    $PathBox.AccessibleName = "WebSocket 路径"

    $CustomLabel = New-UiLabel $NodeCard "自定义 Mihomo JSON 模板" 22 244 610 22 8.5 $true $MutedColor
    $CustomBox = New-UiTextBox $NodeCard 22 269 500
    $BrowseButton = New-UiButton $NodeCard "浏览" 534 268 98 32 $AccentSoft $AccentColor
    $CustomBox.TabIndex = 4
    $CustomBox.AccessibleName = "自定义 Mihomo JSON 模板"
    $BrowseButton.TabIndex = 5
    $NodeHint = New-UiLabel $NodeCard "SNI 与 Host 必须指向你自己的 CDN 节点域名，不能使用公开示例域名。" 22 318 610 34 8.2 $false $MutedColor
    $NodeHint.AutoEllipsis = $false

    $NodeInfo = New-Object Windows.Forms.Panel
    $NodeInfo.BackColor = $SuccessSoft
    $NodeInfo.SetBounds(28, 388, 664, 58)
    [void]$NodePage.Controls.Add($NodeInfo)
    $null = New-UiLabel $NodeInfo "敏感字段会被隐藏" 18 9 200 22 8.8 $true $SuccessColor
    $null = New-UiLabel $NodeInfo "确认页只显示「已设置」，不会回显 UUID、密码或 API 密钥。" 18 30 620 21 8.2 $false $MutedColor

    $ReviewPage = New-Object Windows.Forms.Panel
    $ReviewPage.Dock = [Windows.Forms.DockStyle]::Fill
    $ReviewPage.BackColor = $PageColor
    [void]$PageHost.Controls.Add($ReviewPage)
    $ReviewCard = New-Card $ReviewPage 28 6 664 326
    $null = New-UiLabel $ReviewCard "安装摘要" 22 15 610 26 11 $true $TextColor
    $null = New-UiLabel $ReviewCard "敏感信息已脱敏" 22 42 610 20 8.2 $false $MutedColor

    $SummaryDefinitions = @(
        @{ Key = "Protocol"; Label = "协议与端口" },
        @{ Key = "Controller"; Label = "Mihomo API" },
        @{ Key = "Mixed"; Label = "Mixed Proxy" },
        @{ Key = "Domain"; Label = "SNI / Host" },
        @{ Key = "Transport"; Label = "WS 路径 / 模板" },
        @{ Key = "NodeCredential"; Label = "节点认证" },
        @{ Key = "ApiCredential"; Label = "API 密钥" }
    )
    $SummaryValueLabels = @{}
    for ($Index = 0; $Index -lt $SummaryDefinitions.Count; $Index += 1) {
        $Y = 72 + ($Index * 34)
        $null = New-UiLabel $ReviewCard $SummaryDefinitions[$Index].Label 22 $Y 150 22 8.3 $false $MutedColor
        $ValueLabel = New-UiLabel $ReviewCard "—" 180 $Y 450 22 8.7 $true $TextColor
        $ValueLabel.AccessibleName = "$($SummaryDefinitions[$Index].Label) 值"
        $SummaryValueLabels[$SummaryDefinitions[$Index].Key] = $ValueLabel
    }

    $ReviewInfo = New-Object Windows.Forms.Panel
    $ReviewInfo.BackColor = $SuccessSoft
    $ReviewInfo.SetBounds(28, 346, 664, 92)
    [void]$ReviewPage.Controls.Add($ReviewInfo)
    $null = New-UiLabel $ReviewInfo "安装器将安全完成以下操作" 18 11 620 24 9 $true $SuccessColor
    $ReviewInfoText = New-UiLabel $ReviewInfo "备份现有文件 · 写入本机配置 · 更新计划任务 · 保持 provider 位于 Clash Verge Rev SAFE_PATHS" 18 40 620 40 8.2 $false $MutedColor
    $ReviewInfoText.AutoEllipsis = $false

    $script:WizardResult = $null
    $UiState = @{
        CurrentPage = 0
        ConfirmedCustomPort = $null
    }

    $GetCandidate = {
        $SelectedProtocol = @("vmess", "vless", "trojan", "custom")[$ProtocolBox.SelectedIndex]
        $ParsedPort = 0
        if (-not [string]::IsNullOrWhiteSpace($PortBox.Text) -and
            -not [int]::TryParse($PortBox.Text, [ref]$ParsedPort)) {
            throw "端口必须是数字。"
        }
        return @{
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
    }

    $ValidateConnectionPage = {
        $Candidate = & $GetCandidate
        if (-not (Test-LoopbackHttpUri $Candidate.Controller)) {
            [void]$ControllerBox.Select()
            throw "Mihomo API 必须是本机 HTTP(S) 地址，例如 http://127.0.0.1:9090。"
        }
        if (-not (Test-LoopbackHttpUri $Candidate.MixedProxy)) {
            [void]$MixedBox.Select()
            throw "Mixed Proxy 必须是本机 HTTP(S) 地址，例如 http://127.0.0.1:7890。"
        }
        if ($Candidate.Port -lt 0 -or $Candidate.Port -gt 65535) {
            [void]$PortBox.Select()
            throw "端口必须为 1 到 65535；自定义模板可留空以保留模板端口。"
        }
        if ($Candidate.Protocol -ne "custom" -and $Candidate.Port -eq 0) {
            $PortBox.Text = "443"
        }
    }

    $FormatSummaryUri = {
        param([string]$Value)
        $Parsed = $null
        if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$Parsed)) {
            return $Value
        }
        $PortSuffix = if ($Parsed.IsDefaultPort) { "" } else { ":$($Parsed.Port)" }
        $UserInfo = if ([string]::IsNullOrWhiteSpace($Parsed.UserInfo)) { "" } else { "***@" }
        return (
            "{0}://{1}{2}{3}" -f
            $Parsed.Scheme,
            $UserInfo,
            $Parsed.Host,
            $PortSuffix
        )
    }

    $UpdateSummary = {
        $Candidate = & $GetCandidate
        Assert-CommonInput $Candidate
        $PreparedTemplate = New-NodeTemplate $Candidate
        $TemplatePort = [int]$PreparedTemplate.port
        $TemplateType = [string]$PreparedTemplate.type
        $SummaryValueLabels["Protocol"].Text = "$($TemplateType.ToUpperInvariant()) · $TemplatePort"
        $SummaryValueLabels["Controller"].Text = & $FormatSummaryUri $Candidate.Controller
        $SummaryValueLabels["Mixed"].Text = & $FormatSummaryUri $Candidate.MixedProxy
        $SummaryValueLabels["Domain"].Text = if ($Candidate.Protocol -eq "custom") {
            "由自定义模板提供"
        } else {
            "$($Candidate.ServerName) · $($Candidate.HostName)"
        }
        $SummaryValueLabels["Transport"].Text = if ($Candidate.Protocol -eq "custom") {
            [IO.Path]::GetFileName($Candidate.CustomTemplatePath)
        } else {
            $Candidate.WebSocketPath
        }
        $SummaryValueLabels["NodeCredential"].Text = if ($Candidate.Protocol -eq "custom") {
            "由自定义模板提供（已隐藏）"
        } else {
            "已设置（已隐藏）"
        }
        $SummaryValueLabels["ApiCredential"].Text = if (
            [string]::IsNullOrWhiteSpace($Candidate.ControllerSecret)
        ) {
            "未设置"
        } else {
            "已设置（已隐藏）"
        }
    }

    $ShowFormError = {
        param([string]$Message)
        $ErrorLabel.Text = $Message
        $ErrorLabel.Visible = -not [string]::IsNullOrWhiteSpace($Message)
        $ErrorLabel.AccessibleDescription = $Message
        $ErrorToolTip.SetToolTip($ErrorLabel, $(if ($Message) { "$Message`n`n单击复制" } else { "" }))
    }

    $FocusInvalidField = {
        param([string]$Message)
        if ($UiState.CurrentPage -eq 0) {
            if ($Message -like "Mihomo API*") {
                [void]$ControllerBox.Select()
            } elseif ($Message -like "Mixed Proxy*") {
                [void]$MixedBox.Select()
            } else {
                [void]$PortBox.Select()
            }
            return
        }
        if ($UiState.CurrentPage -ne 1) {
            return
        }
        if ($ProtocolBox.SelectedIndex -eq 3 -or $Message -like "自定义模板*") {
            [void]$CustomBox.Select()
        } elseif ($Message -match "UUID|Trojan|认证") {
            [void]$CredentialBox.Select()
        } elseif ($Message -like "ServerName*") {
            [void]$ServerBox.Select()
        } elseif ($Message -like "HostName*") {
            [void]$HostBox.Select()
        } elseif ($Message -like "WebSocket 路径*") {
            [void]$PathBox.Select()
        } else {
            [void]$CredentialBox.Select()
        }
    }

    $UpdatePage = {
        $ConnectionPage.Visible = $UiState.CurrentPage -eq 0
        $NodePage.Visible = $UiState.CurrentPage -eq 1
        $ReviewPage.Visible = $UiState.CurrentPage -eq 2
        $Headers = @(
            @{ Title = "连接与协议"; Hint = "配置 Mihomo 本地连接与 Cloudflare 入口" },
            @{ Title = "节点参数"; Hint = "填写你自己的认证、域名与传输设置" },
            @{ Title = "确认安装"; Hint = "检查脱敏摘要，然后开始本机安装" }
        )
        $HeaderTitle.Text = $Headers[$UiState.CurrentPage].Title
        $HeaderHint.Text = $Headers[$UiState.CurrentPage].Hint
        $PageBadge.Text = "步骤 $($UiState.CurrentPage + 1) / 3"
        for ($Index = 0; $Index -lt $StepViews.Count; $Index += 1) {
            $Active = $Index -eq $UiState.CurrentPage
            $StepViews[$Index].Indicator.BackColor = if ($Active) {
                $AccentColor
            } else {
                $SidebarColor
            }
            $StepViews[$Index].Number.BackColor = if ($Active) {
                $AccentColor
            } else {
                [Drawing.Color]::FromArgb(30, 41, 59)
            }
            $StepViews[$Index].Number.ForeColor = if ($Active) {
                [Drawing.Color]::White
            } else {
                $SidebarMuted
            }
            $StepViews[$Index].Title.ForeColor = if ($Active) {
                [Drawing.Color]::White
            } else {
                $SidebarMuted
            }
        }
        $BackButton.Enabled = $UiState.CurrentPage -gt 0
        $BackButton.Visible = $UiState.CurrentPage -gt 0
        $NextButton.Text = if ($UiState.CurrentPage -eq 2) { "开始安装" } else { "继续" }
        & $ShowFormError ""
        if ($UiState.CurrentPage -eq 0) {
            [void]$ProtocolBox.Select()
        } elseif ($UiState.CurrentPage -eq 1) {
            if ($ProtocolBox.SelectedIndex -eq 3) {
                [void]$CustomBox.Select()
            } else {
                [void]$CredentialBox.Select()
            }
        } else {
            [void]$NextButton.Select()
        }
    }

    $UpdateProtocolControls = {
        $IsCustom = $ProtocolBox.SelectedIndex -eq 3
        $CredentialBox.Enabled = -not $IsCustom
        $ServerBox.Enabled = -not $IsCustom
        $HostBox.Enabled = -not $IsCustom
        $PathBox.Enabled = -not $IsCustom
        $CustomBox.Enabled = $IsCustom
        $BrowseButton.Enabled = $IsCustom
        $CredentialLabel.Text = switch ($ProtocolBox.SelectedIndex) {
            0 { "VMess UUID" }
            1 { "VLESS UUID" }
            2 { "Trojan 密码" }
            default { "认证信息由模板提供" }
        }
        $CredentialBox.AccessibleName = $CredentialLabel.Text
        $CredentialBox.UseSystemPasswordChar = $true
        if ($IsCustom) {
            $PortBox.Text = ""
            $NodeHint.Text = "自定义模板必须包含 type、port 和完整认证/传输字段；向导只允许覆盖端口。"
        } else {
            if ([string]::IsNullOrWhiteSpace($PortBox.Text)) {
                $PortBox.Text = "443"
            }
            $NodeHint.Text = "SNI 与 Host 必须指向你自己的 CDN 节点域名，不能使用公开示例域名。"
        }
        $CustomLabel.ForeColor = if ($IsCustom) { $AccentColor } else { $MutedColor }
    }
    $ProtocolBox.Add_SelectedIndexChanged($UpdateProtocolControls)
    & $UpdateProtocolControls

    $BrowseButton.Add_Click({
        $Dialog = New-Object Windows.Forms.OpenFileDialog
        try {
            $Dialog.Title = "选择 Mihomo 节点模板"
            $Dialog.Filter = "JSON 文件 (*.json)|*.json|所有文件 (*.*)|*.*"
            if ($Dialog.ShowDialog($Form) -eq [Windows.Forms.DialogResult]::OK) {
                $CustomBox.Text = $Dialog.FileName
            }
        } finally {
            $Dialog.Dispose()
        }
    })

    $ErrorLabel.Add_Click({
        if (-not [string]::IsNullOrWhiteSpace($ErrorLabel.Text)) {
            try {
                [Windows.Forms.Clipboard]::SetText($ErrorLabel.Text)
                $ErrorToolTip.SetToolTip($ErrorLabel, "错误信息已复制")
            } catch {
                $ErrorToolTip.SetToolTip($ErrorLabel, "复制失败，请稍后重试")
            }
        }
    })

    $BackButton.Add_Click({
        if ($UiState.CurrentPage -gt 0) {
            $UiState.CurrentPage -= 1
            & $UpdatePage
        }
    })

    $NextButton.Add_Click({
        try {
            if ($UiState.CurrentPage -eq 0) {
                & $ValidateConnectionPage
                $UiState.CurrentPage = 1
                & $UpdatePage
                return
            }
            if ($UiState.CurrentPage -eq 1) {
                $Candidate = & $GetCandidate
                Assert-CommonInput $Candidate
                if ($Candidate.Port -gt 0 -and
                    $Candidate.Port -notin $CloudflareHttpsPorts -and
                    $UiState.ConfirmedCustomPort -ne $Candidate.Port) {
                    $Choice = [Windows.Forms.MessageBox]::Show(
                        $Form,
                        "端口 $($Candidate.Port) 不在 Cloudflare 普通代理的标准 HTTPS 端口列表中。仍要继续吗？",
                        "确认非标准端口",
                        [Windows.Forms.MessageBoxButtons]::YesNo,
                        [Windows.Forms.MessageBoxIcon]::Warning
                    )
                    if ($Choice -ne [Windows.Forms.DialogResult]::Yes) {
                        return
                    }
                    $UiState.ConfirmedCustomPort = $Candidate.Port
                }
                & $UpdateSummary
                $UiState.CurrentPage = 2
                & $UpdatePage
                return
            }
            $Candidate = & $GetCandidate
            Assert-CommonInput $Candidate
            $script:WizardResult = $Candidate
            $Form.DialogResult = [Windows.Forms.DialogResult]::OK
            $Form.Close()
        } catch {
            $ValidationMessage = $_.Exception.Message
            & $ShowFormError $ValidationMessage
            & $FocusInvalidField $ValidationMessage
        }
    })

    & $UpdatePage
    try {
        $DialogResult = $Form.ShowDialog()
    } finally {
        $ErrorToolTip.Dispose()
        $Form.Dispose()
    }
    if ($DialogResult -ne [Windows.Forms.DialogResult]::OK) {
        return $null
    }
    return $script:WizardResult
}

function Show-ExistingConfigurationChoice {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()

    $Form = New-Object Windows.Forms.Form
    $Form.Text = "Clash Cloudflare Dynamic"
    $Form.StartPosition = [Windows.Forms.FormStartPosition]::CenterScreen
    $Form.ClientSize = New-Object Drawing.Size(680, 390)
    $Form.FormBorderStyle = [Windows.Forms.FormBorderStyle]::FixedDialog
    $Form.MaximizeBox = $false
    $Form.MinimizeBox = $false
    $Form.AutoScaleMode = [Windows.Forms.AutoScaleMode]::Dpi
    $Form.AutoScaleDimensions = New-Object Drawing.SizeF(96.0, 96.0)
    $Form.BackColor = [Drawing.Color]::FromArgb(246, 248, 252)
    $Form.Font = New-Object Drawing.Font("Microsoft YaHei UI", 9)

    $Title = New-Object Windows.Forms.Label
    $Title.Text = "检测到已有安装"
    $Title.Font = New-Object Drawing.Font("Microsoft YaHei UI", 17, [Drawing.FontStyle]::Bold)
    $Title.ForeColor = [Drawing.Color]::FromArgb(15, 23, 42)
    $Title.SetBounds(30, 24, 610, 36)
    [void]$Form.Controls.Add($Title)
    $Hint = New-Object Windows.Forms.Label
    $Hint.Text = "选择升级方式。无论选择哪一种，安装器都会先创建事务备份。"
    $Hint.ForeColor = [Drawing.Color]::FromArgb(100, 116, 139)
    $Hint.SetBounds(32, 66, 610, 25)
    [void]$Form.Controls.Add($Hint)

    function New-ChoiceCard(
        [string]$TitleText,
        [string]$Description,
        [int]$Y,
        [bool]$Primary
    ) {
        $Button = New-Object Windows.Forms.Button
        $Button.FlatStyle = [Windows.Forms.FlatStyle]::Flat
        $Button.FlatAppearance.BorderSize = 1
        $Button.FlatAppearance.BorderColor = if ($Primary) {
            [Drawing.Color]::FromArgb(37, 99, 235)
        } else {
            [Drawing.Color]::FromArgb(203, 213, 225)
        }
        $Button.BackColor = if ($Primary) {
            [Drawing.Color]::FromArgb(239, 246, 255)
        } else {
            [Drawing.Color]::White
        }
        $Button.Cursor = [Windows.Forms.Cursors]::Hand
        $Button.AccessibleName = $TitleText
        $Button.AccessibleDescription = $Description
        $Button.AccessibleRole = [Windows.Forms.AccessibleRole]::PushButton
        $Button.SetBounds(30, $Y, 620, 92)
        [void]$Form.Controls.Add($Button)

        $TitleLabel = New-Object Windows.Forms.Label
        $TitleLabel.Text = $TitleText
        $TitleLabel.Font = New-Object Drawing.Font("Microsoft YaHei UI", 10.5, [Drawing.FontStyle]::Bold)
        $TitleLabel.ForeColor = if ($Primary) {
            [Drawing.Color]::FromArgb(29, 78, 216)
        } else {
            [Drawing.Color]::FromArgb(15, 23, 42)
        }
        $TitleLabel.BackColor = $Button.BackColor
        $TitleLabel.SetBounds(18, 15, 574, 26)
        $TitleLabel.Cursor = [Windows.Forms.Cursors]::Hand
        [void]$Button.Controls.Add($TitleLabel)

        $DescriptionLabel = New-Object Windows.Forms.Label
        $DescriptionLabel.Text = $Description
        $DescriptionLabel.ForeColor = [Drawing.Color]::FromArgb(100, 116, 139)
        $DescriptionLabel.BackColor = $Button.BackColor
        $DescriptionLabel.SetBounds(18, 45, 574, 25)
        $DescriptionLabel.Cursor = [Windows.Forms.Cursors]::Hand
        [void]$Button.Controls.Add($DescriptionLabel)
        return [PSCustomObject]@{
            Button = $Button
            Title = $TitleLabel
            Description = $DescriptionLabel
        }
    }

    $KeepCard = New-ChoiceCard "保留配置并升级（推荐）" "更新程序和计划任务，保留现有协议、端口、域名与凭据。" 108 $true
    $ReplaceCard = New-ChoiceCard "重新填写节点参数" "备份旧配置后，重新选择协议、入口端口、SNI 和认证信息。" 214 $false
    $Cancel = New-Object Windows.Forms.Button
    $Cancel.Text = "取消"
    $Cancel.FlatStyle = [Windows.Forms.FlatStyle]::Flat
    $Cancel.FlatAppearance.BorderSize = 0
    $Cancel.BackColor = $Form.BackColor
    $Cancel.ForeColor = [Drawing.Color]::FromArgb(100, 116, 139)
    $Cancel.Cursor = [Windows.Forms.Cursors]::Hand
    $Cancel.SetBounds(550, 334, 100, 36)
    $Cancel.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $KeepCard.Button.TabIndex = 0
    $ReplaceCard.Button.TabIndex = 1
    $Cancel.TabIndex = 2
    [void]$Form.Controls.Add($Cancel)

    $ChoiceState = @{ Value = "cancel" }
    $SelectKeep = {
        $ChoiceState.Value = "keep"
        $Form.Close()
    }
    $SelectReplace = {
        $ChoiceState.Value = "replace"
        $Form.Close()
    }
    $KeepCard.Button.Add_Click($SelectKeep)
    $KeepCard.Title.Add_Click($SelectKeep)
    $KeepCard.Description.Add_Click($SelectKeep)
    $ReplaceCard.Button.Add_Click($SelectReplace)
    $ReplaceCard.Title.Add_Click($SelectReplace)
    $ReplaceCard.Description.Add_Click($SelectReplace)
    $Cancel.Add_Click({ $Form.Close() })
    $Form.AcceptButton = $KeepCard.Button
    $Form.CancelButton = $Cancel
    $Form.ActiveControl = $KeepCard.Button
    $Form.Add_FormClosing({
        if ([string]::IsNullOrWhiteSpace($ChoiceState.Value)) {
            $ChoiceState.Value = "cancel"
        }
    })
    try {
        [void]$Form.ShowDialog()
    } finally {
        $Form.Dispose()
    }
    return $ChoiceState.Value
}

function Show-Message([string]$Text, [bool]$Error = $false) {
    if ($NonInteractive) {
        if ($Error) { Write-Error $Text } else { Write-Host $Text }
        return
    }
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()

    $Accent = if ($Error) {
        [Drawing.Color]::FromArgb(220, 38, 38)
    } else {
        [Drawing.Color]::FromArgb(37, 99, 235)
    }
    $Form = New-Object Windows.Forms.Form
    $Form.Text = "Clash Cloudflare Dynamic"
    $Form.StartPosition = [Windows.Forms.FormStartPosition]::CenterScreen
    $Form.ClientSize = New-Object Drawing.Size(570, 310)
    $Form.FormBorderStyle = [Windows.Forms.FormBorderStyle]::FixedDialog
    $Form.MaximizeBox = $false
    $Form.MinimizeBox = $false
    $Form.AutoScaleMode = [Windows.Forms.AutoScaleMode]::Dpi
    $Form.AutoScaleDimensions = New-Object Drawing.SizeF(96.0, 96.0)
    $Form.BackColor = [Drawing.Color]::White
    $Form.Font = New-Object Drawing.Font("Microsoft YaHei UI", 9)

    $Bar = New-Object Windows.Forms.Panel
    $Bar.Dock = [Windows.Forms.DockStyle]::Left
    $Bar.Width = 6
    $Bar.BackColor = $Accent
    [void]$Form.Controls.Add($Bar)
    $Icon = New-Object Windows.Forms.Label
    $Icon.Text = if ($Error) { "!" } else { "✓" }
    $Icon.TextAlign = [Drawing.ContentAlignment]::MiddleCenter
    $Icon.Font = New-Object Drawing.Font("Microsoft YaHei UI", 16, [Drawing.FontStyle]::Bold)
    $Icon.ForeColor = [Drawing.Color]::White
    $Icon.BackColor = $Accent
    $Icon.SetBounds(30, 28, 46, 46)
    [void]$Form.Controls.Add($Icon)
    $Title = New-Object Windows.Forms.Label
    $Title.Text = if ($Error) { "安装未完成" } else { "安装完成" }
    $Title.Font = New-Object Drawing.Font("Microsoft YaHei UI", 16, [Drawing.FontStyle]::Bold)
    $Title.ForeColor = [Drawing.Color]::FromArgb(15, 23, 42)
    $Title.SetBounds(94, 28, 430, 38)
    [void]$Form.Controls.Add($Title)
    $Subtitle = New-Object Windows.Forms.Label
    $Subtitle.Text = if ($Error) { "请检查以下信息后重试" } else { "程序和计划任务已准备就绪" }
    $Subtitle.ForeColor = [Drawing.Color]::FromArgb(100, 116, 139)
    $Subtitle.SetBounds(96, 64, 430, 24)
    [void]$Form.Controls.Add($Subtitle)
    $Body = New-Object Windows.Forms.TextBox
    $Body.ForeColor = [Drawing.Color]::FromArgb(51, 65, 85)
    $Body.BackColor = [Drawing.Color]::White
    $Body.BorderStyle = [Windows.Forms.BorderStyle]::None
    $Body.Multiline = $true
    $Body.ReadOnly = $true
    $Body.ScrollBars = [Windows.Forms.ScrollBars]::Vertical
    $Body.Text = $Text.Replace("`r`n", "`n").Replace("`n", "`r`n")
    $Body.TabIndex = 0
    $Body.AccessibleName = "安装结果详情"
    $Body.SetBounds(32, 108, 506, 126)
    [void]$Form.Controls.Add($Body)
    $Copy = New-Object Windows.Forms.Button
    $Copy.Text = "复制详情"
    $Copy.Font = New-Object Drawing.Font("Microsoft YaHei UI", 9.5)
    $Copy.FlatStyle = [Windows.Forms.FlatStyle]::Flat
    $Copy.FlatAppearance.BorderSize = 1
    $Copy.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(203, 213, 225)
    $Copy.BackColor = [Drawing.Color]::White
    $Copy.ForeColor = [Drawing.Color]::FromArgb(71, 85, 105)
    $Copy.Cursor = [Windows.Forms.Cursors]::Hand
    $Copy.TabIndex = 1
    $Copy.SetBounds(266, 252, 130, 40)
    $Copy.Add_Click({
        if (-not [string]::IsNullOrWhiteSpace($Text)) {
            try { [Windows.Forms.Clipboard]::SetText($Text) } catch { }
        }
    })
    [void]$Form.Controls.Add($Copy)
    $Ok = New-Object Windows.Forms.Button
    $Ok.Text = "知道了"
    $Ok.Font = New-Object Drawing.Font("Microsoft YaHei UI", 9.5, [Drawing.FontStyle]::Bold)
    $Ok.FlatStyle = [Windows.Forms.FlatStyle]::Flat
    $Ok.FlatAppearance.BorderSize = 0
    $Ok.BackColor = $Accent
    $Ok.ForeColor = [Drawing.Color]::White
    $Ok.Cursor = [Windows.Forms.Cursors]::Hand
    $Ok.DialogResult = [Windows.Forms.DialogResult]::OK
    $Ok.TabIndex = 2
    $Ok.SetBounds(408, 252, 130, 40)
    [void]$Form.Controls.Add($Ok)
    $Form.AcceptButton = $Ok
    $Form.CancelButton = $Ok
    $Form.ActiveControl = $Ok
    try {
        [void]$Form.ShowDialog()
    } finally {
        $Form.Dispose()
    }
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
