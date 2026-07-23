$ErrorActionPreference = "Stop"

$RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$ReleaseRoot = Join-Path $RepositoryRoot "dist\ClashCloudflareDynamic"
$WizardPath = Join-Path $ReleaseRoot "install_wizard.ps1"
$UiPath = Join-Path $ReleaseRoot "install_wizard_ui.ps1"
$LauncherPath = Join-Path $ReleaseRoot "Install.cmd"
foreach ($RequiredPath in @($WizardPath, $UiPath, $LauncherPath)) {
    if (-not (Test-Path -LiteralPath $RequiredPath -PathType Leaf)) {
        throw "缺少测试发布包文件：$RequiredPath；请先运行 python .\tools\build_release.py"
    }
}

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        throw $Message
    }
}

function Read-PowerShellAst([string]$Path) {
    $Tokens = $null
    $ParseErrors = $null
    $Ast = [Management.Automation.Language.Parser]::ParseFile(
        $Path,
        [ref]$Tokens,
        [ref]$ParseErrors
    )
    Assert-True ($ParseErrors.Count -eq 0) (
        "PowerShell AST 解析失败 $Path：" +
        (($ParseErrors | ForEach-Object Message) -join "；")
    )
    return $Ast
}

$WizardAst = Read-PowerShellAst $WizardPath
$UiAst = Read-PowerShellAst $UiPath
$WizardText = $WizardAst.Extent.Text
$UiText = $UiAst.Extent.Text
Assert-True ($WizardText.Contains('install_wizard_ui.ps1')) "主向导没有加载 WPF 界面层"
Assert-True (-not $WizardText.Contains('System.Windows.Forms')) "主向导仍依赖 WinForms"
Assert-True (-not $UiText.Contains('System.Windows.Forms')) "WPF 界面层仍依赖 WinForms"

foreach ($FunctionName in @(
    "Initialize-WpfRuntime",
    "ConvertFrom-WpfXaml",
    "Get-WindowsAppTheme",
    "ConvertTo-WpfColor",
    "New-WpfBrush",
    "Blend-WpfColor",
    "Get-WpfRelativeLuminance",
    "Get-ContrastingWpfColor",
    "Get-WindowsAccentColor",
    "Set-WpfThemeResources",
    "Add-WpfScrollBarResources",
    "Show-InstallForm",
    "Show-ExistingConfigurationChoice",
    "Show-Message"
)) {
    $FunctionAst = $UiAst.Find({
        param($Node)
        $Node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $Node.Name -eq $FunctionName
    }, $true)
    Assert-True ($null -ne $FunctionAst) "WPF 界面层缺少函数：$FunctionName"
}

foreach ($DpiMarker in @(
    "SetProcessDpiAwarenessContext",
    "[IntPtr](-4)",
    "SetProcessDpiAwareness(2)",
    'UseLayoutRounding="True"',
    'SnapsToDevicePixels="True"',
    'TextOptions.TextRenderingMode="ClearType"',
    "Segoe UI Variable Text"
)) {
    Assert-True ($UiText.Contains($DpiMarker)) "WPF DPI/清晰度配置缺失：$DpiMarker"
}

foreach ($ThemeMarker in @(
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize',
    'AppsUseLightTheme',
    '[ValidateSet("system", "light", "dark")]',
    'Get-WindowsAccentColor',
    'AccentForegroundBrush',
    'AccentHoverForegroundBrush',
    'Set-WpfThemeResources $Window $script:PreferredWpfThemeMode',
    'AppBackgroundBrush',
    'SurfaceBrush',
    'ControlBackgroundBrush',
    'ErrorBorderBrush'
    'ScrollThumbBrush',
    'ScrollThumbHoverBrush',
    'x:Key="VerticalScrollThumbStyle"',
    'x:Key="HorizontalScrollThumbStyle"',
    'x:Key="VerticalScrollBarTemplate"',
    'x:Key="HorizontalScrollBarTemplate"',
    'Opacity="0"'
)) {
    Assert-True ($UiText.Contains($ThemeMarker)) "WPF 主题支持缺失：$ThemeMarker"
}

foreach ($WindowFunctionName in @(
    "Show-InstallForm",
    "Show-ExistingConfigurationChoice",
    "Show-Message"
)) {
    $WindowFunctionAst = $UiAst.Find({
        param($Node)
        $Node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $Node.Name -eq $WindowFunctionName
    }, $true)
    Assert-True (
        $WindowFunctionAst.Extent.Text.Contains('Add-WpfScrollBarResources $Window')
    ) "$WindowFunctionName 没有应用共享滚动条主题"
}

$InstallFormAst = $UiAst.Find({
    param($Node)
    $Node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $Node.Name -eq "Show-InstallForm"
}, $true)
$InstallFormText = $InstallFormAst.Extent.Text
foreach ($SinglePageMarker in @(
    "节点配置",
    "实时摘要",
    "Mihomo 本地连接",
    "外观",
    "跟随系统",
    "浅色",
    "深色",
    'x:Name="SystemThemeButton"',
    'x:Name="LightThemeButton"',
    'x:Name="DarkThemeButton"',
    'x:Key="ThemeChoiceStyle"',
    'x:Key="SettingsExpanderStyle"',
    'x:Key="SettingsCardStyle"',
    'x:Key="SectionTitleStyle"',
    'x:Name="SummaryPanel"',
    'x:Name="ConnectionCard"',
    'x:Name="NodeCard"',
    'x:Name="AdvancedCard"',
    'SummarySurfaceBrush',
    'x:Name="HeaderSubtitle"',
    'x:Name="PrivacyText"',
    'x:Name="ContentGrid"',
    '$ApplyResponsiveLayout = {',
    '$CurrentWidth -lt 1040',
    '$SummaryPanel.Visibility = [Windows.Visibility]::Collapsed',
    '$script:PreferredWpfThemeMode = $Mode',
    'Background="{DynamicResource AppBackgroundBrush}"',
    '$SystemThemeButton.Add_Checked({ & $ApplyThemeMode "system" })',
    '$LightThemeButton.Add_Checked({ & $ApplyThemeMode "light" })',
    '$DarkThemeButton.Add_Checked({ & $ApplyThemeMode "dark" })',
    '$Window.Add_Activated({',
    'x:Name="AdvancedExpander" IsExpanded="False"',
    "验证并安装",
    "FooterErrorText",
    "GetValidationState",
    "FocusValidationField"
)) {
    Assert-True ($InstallFormText.Contains($SinglePageMarker)) (
        "单页 WPF 向导缺少：$SinglePageMarker"
    )
}
Assert-True (-not $InstallFormText.Contains("CurrentPage")) "WPF 主界面不应继续使用多页向导状态"
Assert-True (-not $InstallFormText.Contains("Sidebar")) "WPF 主界面不应继续使用深色侧栏"
Assert-True (-not $InstallFormText.Contains("VMESS")) "协议名称大小写没有统一为 VMess"
Assert-True (
    $InstallFormText.Contains(
        '<Setter TargetName="ChoiceBorder" Property="Background" Value="{DynamicResource AccentBrush}"/>'
    )
) "主题选中态没有使用明确的系统强调色"
Assert-True (
    $InstallFormText.Contains('Data="M 0 0 L 4 4 L 0 8"') -and
    $InstallFormText.Contains('Grid.Column="1" RenderTransformOrigin="0.5,0.5"')
) "Mihomo 展开控件没有使用右侧标准 chevron"

foreach ($SensitiveSummary in @(
    '$SummaryCredential.Text = if',
    '$SummarySecret.Text = if',
    '"已设置"',
    '"未设置"'
)) {
    Assert-True ($InstallFormText.Contains($SensitiveSummary)) (
        "实时摘要缺少脱敏状态：$SensitiveSummary"
    )
}
Assert-True (-not $InstallFormText.Contains('$SummaryCredential.Text = $Candidate.Credential')) (
    "实时摘要直接回显了 UUID/密码"
)
Assert-True (-not $InstallFormText.Contains('$SummarySecret.Text = $Candidate.ControllerSecret')) (
    "实时摘要直接回显了 API 密钥"
)
Assert-True ($InstallFormText.Contains('[Windows.MessageBox]::Show')) "非标准端口确认没有迁移到 WPF"
Assert-True ($InstallFormText.Contains('Microsoft.Win32.OpenFileDialog')) "模板选择没有使用 WPF 文件对话框"

$CleanupTry = $WizardAst.Find({
    param($Node)
    $Node -is [Management.Automation.Language.TryStatementAst] -and
    $null -ne $Node.Finally -and
    $Node.Finally.Extent.Text.Contains('$OwnedStagePath')
}, $true)
Assert-True ($null -ne $CleanupTry) "没有找到临时凭据清理 finally"
$CleanupText = $CleanupTry.Finally.Extent.Text
Assert-True ($CleanupText.Contains('$Attempt -le 3')) "临时凭据清理没有重试"
Assert-True ($CleanupText.Contains('Show-Message $CleanupFailureMessage $true')) (
    "临时凭据清理失败没有使用 WPF 错误提示"
)

foreach ($HelperName in @(
    "Test-LoopbackHttpUri",
    "Assert-CommonInput",
    "Read-JsonObject",
    "New-NodeTemplate"
)) {
    $HelperAst = $WizardAst.Find({
        param($Node)
        $Node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $Node.Name -eq $HelperName
    }, $true)
    Assert-True ($null -ne $HelperAst) "安装向导缺少 UI 运行时依赖：$HelperName"
    Invoke-Expression $HelperAst.Extent.Text
}

. $UiPath
Initialize-WpfRuntime
$OriginalWindowsAppTheme = (Get-Command Get-WindowsAppTheme).ScriptBlock
$OriginalWindowsAccentColor = (Get-Command Get-WindowsAccentColor).ScriptBlock
try {
    Set-Item Function:Get-WindowsAppTheme -Value { return "dark" }
    Set-Item Function:Get-WindowsAccentColor -Value {
        return ConvertTo-WpfColor "#107C10"
    }
    $ThemeWindow = New-Object Windows.Window

    $LightResolved = Set-WpfThemeResources $ThemeWindow "light"
    Assert-True ($LightResolved -eq "light") "显式浅色主题没有解析为 light"
    Assert-True (
        $ThemeWindow.Resources["AppBackgroundBrush"].Color.ToString() -eq "#FFF3F3F3"
    ) "浅色主题背景色错误"
    Assert-True (
        $ThemeWindow.Resources["TextBrush"].Color.ToString() -eq "#FF1A1A1A"
    ) "浅色主题文字颜色错误"
    Assert-True (
        $ThemeWindow.Resources["AccentBrush"].Color.ToString() -eq "#FF107C10"
    ) "浅色主题没有使用系统强调色"

    $DarkResolved = Set-WpfThemeResources $ThemeWindow "dark"
    Assert-True ($DarkResolved -eq "dark") "显式深色主题没有解析为 dark"
    Assert-True (
        $ThemeWindow.Resources["AppBackgroundBrush"].Color.ToString() -eq "#FF202020"
    ) "深色主题背景色错误"
    Assert-True (
        $ThemeWindow.Resources["TextBrush"].Color.ToString() -eq "#FFF5F5F5"
    ) "深色主题文字颜色错误"
    Assert-True (
        $ThemeWindow.Resources["AccentBrush"].Color.ToString() -eq "#FF107C10"
    ) "深色主题没有使用系统强调色"
    Assert-True (
        $ThemeWindow.Resources["ScrollThumbBrush"].Color.ToString() -eq "#FF4A4A4A"
    ) "深色主题没有应用深色滚动滑块"
    foreach ($ContrastPair in @(
        @{ Background = "AccentBrush"; Foreground = "AccentForegroundBrush" },
        @{ Background = "AccentHoverBrush"; Foreground = "AccentHoverForegroundBrush" }
    )) {
        $BackgroundLuminance = Get-WpfRelativeLuminance (
            $ThemeWindow.Resources[$ContrastPair.Background].Color
        )
        $ForegroundLuminance = Get-WpfRelativeLuminance (
            $ThemeWindow.Resources[$ContrastPair.Foreground].Color
        )
        $Contrast = (
            [Math]::Max($BackgroundLuminance, $ForegroundLuminance) + 0.05
        ) / (
            [Math]::Min($BackgroundLuminance, $ForegroundLuminance) + 0.05
        )
        Assert-True ($Contrast -ge 4.5) (
            "$($ContrastPair.Background) 的文字对比度不足：$Contrast"
        )
    }

    $SystemResolved = Set-WpfThemeResources $ThemeWindow "system"
    Assert-True ($SystemResolved -eq "dark") "跟随系统没有采用模拟的深色应用主题"
    Assert-True (
        $ThemeWindow.Resources["SurfaceBrush"].Color.ToString() -eq "#FF2B2B2B"
    ) "跟随系统没有应用深色面板颜色"

    $InvalidThemeRejected = $false
    try {
        $null = Set-WpfThemeResources $ThemeWindow "high-contrast"
    } catch {
        $InvalidThemeRejected = $true
    }
    Assert-True $InvalidThemeRejected "主题函数没有拒绝未知模式"
} finally {
    Set-Item Function:Get-WindowsAppTheme -Value $OriginalWindowsAppTheme
    Set-Item Function:Get-WindowsAccentColor -Value $OriginalWindowsAccentColor
    if ($null -ne $ThemeWindow) {
        $ThemeWindow.Close()
    }
}
$RuntimeInstallFormText = (Get-Command Show-InstallForm).ScriptBlock.Ast.Extent.Text
$DialogCall = '    $DialogResult = $Window.ShowDialog()'
$UiRuntimeHarness = @'
    $Window.ShowInTaskbar = $false
    $Window.Opacity = 0
    $Window.Add_ContentRendered({
        try {
            if (-not $SystemThemeButton.IsChecked) {
                throw "安装向导默认没有选择跟随系统"
            }
            if ($Window.Resources["AppBackgroundBrush"].Color.ToString() -ne "#FF202020") {
                throw "跟随系统没有使用模拟的深色主题"
            }
            $ScrollProbe = New-Object Windows.Controls.Primitives.ScrollBar
            $ScrollProbe.Orientation = [Windows.Controls.Orientation]::Vertical
            $ScrollProbe.Minimum = 0
            $ScrollProbe.Maximum = 100
            $ScrollProbe.Value = 40
            $ScrollProbe.ViewportSize = 20
            $ScrollProbe.Width = 10
            $ScrollProbe.Height = 120
            [void]$Window.Content.Children.Add($ScrollProbe)
            $Window.UpdateLayout()
            [void]$ScrollProbe.ApplyTemplate()
            $ScrollTrack = $ScrollProbe.Template.FindName("PART_Track", $ScrollProbe)
            if ($null -eq $ScrollTrack -or $null -eq $ScrollTrack.Thumb) {
                throw "滚动条模板没有实例化 Track/Thumb"
            }
            $ScrollThumb = $ScrollTrack.Thumb
            [void]$ScrollThumb.ApplyTemplate()
            $ScrollThumbBody = $ScrollThumb.Template.FindName("ThumbBody", $ScrollThumb)
            if ($null -eq $ScrollThumbBody) {
                throw "滚动滑块没有应用自定义 Thumb 模板"
            }
            if ($ScrollThumbBody.Background.Color.ToString() -ne "#FF4A4A4A") {
                throw "深色滚动滑块模板没有使用深色画刷"
            }
            $ProtocolBox.IsDropDownOpen = $true
            if (-not $ProtocolBox.IsDropDownOpen) {
                throw "协议下拉框模板无法打开"
            }
            $ProtocolBox.IsDropDownOpen = $false
            $PortBox.Text = "8443"
            if ($SummaryPort.Text -ne "8443") {
                throw "可编辑端口下拉框没有实时更新摘要"
            }
            $PortBox.Text = "443"
            $LightThemeButton.IsChecked = $true
            if ($Window.Resources["AppBackgroundBrush"].Color.ToString() -ne "#FFF3F3F3") {
                throw "安装向导浅色切换没有更新背景资源"
            }
            if ($Window.Resources["AccentBrush"].Color.ToString() -ne "#FF107C10") {
                throw "安装向导浅色切换没有保留系统强调色"
            }
            if ($ScrollThumbBody.Background.Color.ToString() -ne "#FF8A8A8A") {
                throw "滚动滑块模板没有响应浅色主题切换"
            }
            [void]$LightThemeButton.ApplyTemplate()
            $LightChoiceBorder = $LightThemeButton.Template.FindName(
                "ChoiceBorder", $LightThemeButton
            )
            if ($null -eq $LightChoiceBorder -or
                $LightChoiceBorder.Background.Color.ToString() -ne
                    $Window.Resources["AccentBrush"].Color.ToString()) {
                throw "浅色主题选中态不够明确"
            }
            $DarkThemeButton.IsChecked = $true
            if ($Window.Resources["AppBackgroundBrush"].Color.ToString() -ne "#FF202020") {
                throw "安装向导深色切换没有更新背景资源"
            }
            if ($script:PreferredWpfThemeMode -ne "dark") {
                throw "显式深色选择没有保存到后续 WPF 窗口"
            }
            if ($Window.Resources["TextBrush"].Color.ToString() -ne "#FFF5F5F5") {
                throw "安装向导深色切换没有更新文字资源"
            }
            if ($ScrollThumbBody.Background.Color.ToString() -ne "#FF4A4A4A") {
                throw "滚动滑块模板没有响应深色主题切换"
            }
            $SystemThemeButton.IsChecked = $true
            if ($Window.Resources["SurfaceBrush"].Color.ToString() -ne "#FF2B2B2B") {
                throw "安装向导切回跟随系统后没有恢复深色面板"
            }
            if ($script:PreferredWpfThemeMode -ne "system") {
                throw "跟随系统选择没有保存到后续 WPF 窗口"
            }
            $Window.Width = 700
            $Window.Height = 360
            $Window.UpdateLayout()
            & $ApplyResponsiveLayout
            if ($ContentGrid.ColumnDefinitions[0].MinWidth -ne 0 -or
                $ContentGrid.ColumnDefinitions[1].Width.Value -ne 0 -or
                $ContentGrid.ColumnDefinitions[2].Width.Value -ne 0 -or
                $SummaryPanel.Visibility -ne [Windows.Visibility]::Collapsed) {
                throw "窄窗口没有收起摘要并把宽度还给表单"
            }
            if ($SummaryDetailsScroll.Visibility -ne [Windows.Visibility]::Collapsed) {
                throw "矮窗口没有收起摘要明细"
            }
            if ($HeaderSubtitle.Visibility -ne [Windows.Visibility]::Collapsed -or
                $PrivacyText.Visibility -ne [Windows.Visibility]::Collapsed -or
                $HeaderTitle.FontSize -ne 22) {
                throw "窄窗口页眉没有进入紧凑模式"
            }
            $Window.Width = 1120
            $Window.Height = 780
            $Window.UpdateLayout()
            & $ApplyResponsiveLayout
            if ($ContentGrid.ColumnDefinitions[0].MinWidth -ne 500 -or
                $ContentGrid.ColumnDefinitions[1].Width.Value -ne 24 -or
                $ContentGrid.ColumnDefinitions[2].Width.Value -ne 320 -or
                $SummaryPanel.Visibility -ne [Windows.Visibility]::Visible -or
                $SummaryDetailsScroll.Visibility -ne [Windows.Visibility]::Visible) {
                throw "宽窗口没有恢复完整双栏摘要布局"
            }
            foreach ($Card in @($ConnectionCard, $NodeCard, $AdvancedCard, $SummaryPanel)) {
                if (-not $Card.SnapsToDevicePixels -or
                    $Card.BorderThickness.Left -ne 1) {
                    throw "设置卡片没有保持高 DPI 像素对齐边框"
                }
            }
            [void]$Window.Content.Children.Remove($ScrollProbe)
            [void]$script:WizardUiTestTrace.Add("themes")

            & $UpdateUi
            if ($Window.Tag.IsValid) {
                throw "空节点配置不应通过校验"
            }
            if ($SummaryCredential.Text -ne "未设置") {
                throw "空节点认证摘要错误：$($SummaryCredential.Text)"
            }
            [void]$script:WizardUiTestTrace.Add("invalid")

            $CredentialBox.Password = "11111111-2222-3333-4444-555555555555"
            $SecretBox.Password = "fixture-api-secret"
            $ServerBox.Text = "node.test.invalid"
            $HostBox.Text = "node.test.invalid"
            $PathBox.Text = "/fixture-ws"
            & $UpdateUi
            if (-not $Window.Tag.IsValid) {
                throw "完整节点配置未通过校验：$($Window.Tag.Message)"
            }
            if ($SummaryCredential.Text -ne "已设置") {
                throw "节点认证摘要没有脱敏"
            }
            if ($SummarySecret.Text -ne "已设置") {
                throw "API 密钥摘要没有脱敏"
            }
            if ($SummaryCredential.Text.Contains($CredentialBox.Password) -or
                $SummarySecret.Text.Contains($SecretBox.Password)) {
                throw "实时摘要泄露敏感值"
            }
            [void]$script:WizardUiTestTrace.Add("valid")
            $InstallButton.RaiseEvent(
                (New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent))
            )
        } catch {
            $script:WizardUiTestError = $_.Exception.Message
            $Window.DialogResult = $false
            $Window.Close()
        }
    })
'@
$InstrumentedInstallForm = $RuntimeInstallFormText.Replace(
    $DialogCall,
    $UiRuntimeHarness + "`r`n" + $DialogCall
)
Assert-True ($InstrumentedInstallForm -ne $RuntimeInstallFormText) (
    "无法注入 WPF 安装向导运行时测试"
)
Invoke-Expression $InstrumentedInstallForm
$CloudflareHttpsPorts = @(443, 2053, 2083, 2087, 2096, 8443)
$ExamplesRoot = Join-Path $ReleaseRoot "examples"
$script:WizardUiTestTrace = New-Object Collections.ArrayList
$script:WizardUiTestError = $null
$OriginalRuntimeWindowsAppTheme = (Get-Command Get-WindowsAppTheme).ScriptBlock
$OriginalRuntimeWindowsAccentColor = (Get-Command Get-WindowsAccentColor).ScriptBlock
try {
    Set-Item Function:Get-WindowsAppTheme -Value { return "dark" }
    Set-Item Function:Get-WindowsAccentColor -Value {
        return ConvertTo-WpfColor "#107C10"
    }
    $UiRuntimeResult = Show-InstallForm
} finally {
    Set-Item Function:Get-WindowsAppTheme -Value $OriginalRuntimeWindowsAppTheme
    Set-Item Function:Get-WindowsAccentColor -Value $OriginalRuntimeWindowsAccentColor
}
Assert-True ([string]::IsNullOrWhiteSpace($script:WizardUiTestError)) (
    "WPF 安装向导运行时测试失败：$script:WizardUiTestError"
)
Assert-True (($script:WizardUiTestTrace -join ",") -eq "themes,invalid,valid") (
    "WPF 实时校验轨迹异常：$($script:WizardUiTestTrace -join ',')"
)
Assert-True ($null -ne $UiRuntimeResult) "验证并安装按钮没有返回配置"
Assert-True ($UiRuntimeResult.Protocol -eq "vmess") "WPF UI 返回协议错误"
Assert-True ($UiRuntimeResult.Port -eq 443) "WPF UI 返回端口错误"
Assert-True ($UiRuntimeResult.ServerName -eq "node.test.invalid") "WPF UI 返回 SNI 错误"
Assert-True ($UiRuntimeResult.ControllerSecret -eq "fixture-api-secret") (
    "WPF UI 没有保留 API 密钥"
)
$script:WizardUiTestTrace = $null
$script:WizardUiTestError = $null

function Invoke-Wizard([string[]]$Arguments) {
    $PreviousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $Output = @(
            & powershell.exe `
                -NoLogo `
                -NoProfile `
                -ExecutionPolicy Bypass `
                -STA `
                -File $WizardPath `
                @Arguments 2>&1
        )
        $ExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $PreviousErrorActionPreference
    }
    return [PSCustomObject]@{
        ExitCode = $ExitCode
        Output = ($Output | ForEach-Object { $_.ToString() }) -join "`n"
    }
}

$TestRoot = Join-Path $env:TEMP (
    "cfdyn-wizard-test-" + [Guid]::NewGuid().ToString("N")
)
New-Item -ItemType Directory -Path $TestRoot | Out-Null
try {
    $PreparedRoot = Join-Path $TestRoot "prepared with spaces"
    $VmUuid = "11111111-2222-3333-4444-555555555555"
    $ApiSecret = "fixture-api-secret"
    $VmResult = Invoke-Wizard @(
        "-NonInteractive",
        "-PrepareOnly",
        "-PreparedConfigurationDirectory", $PreparedRoot,
        "-Protocol", "vmess",
        "-Port", "8443",
        "-Controller", "http://127.0.0.1:9090",
        "-ControllerSecret", $ApiSecret,
        "-MixedProxy", "http://127.0.0.1:7890",
        "-Credential", $VmUuid,
        "-ServerName", "node.test.invalid",
        "-HostName", "node.test.invalid",
        "-WebSocketPath", "/fixture-ws"
    )
    Assert-True ($VmResult.ExitCode -eq 0) "VMess PrepareOnly 失败：$($VmResult.Output)"
    Assert-True (-not $VmResult.Output.Contains($VmUuid)) "向导输出泄露 UUID"
    Assert-True (-not $VmResult.Output.Contains($ApiSecret)) "向导输出泄露 API secret"

    $SettingsPath = Join-Path $PreparedRoot "settings.json"
    $TemplatePath = Join-Path $PreparedRoot "node_template.json"
    $Settings = [IO.File]::ReadAllText($SettingsPath) | ConvertFrom-Json
    $Template = [IO.File]::ReadAllText($TemplatePath) | ConvertFrom-Json
    Assert-True ($Settings.secret -eq $ApiSecret) "settings.json 未保存 API secret"
    Assert-True ($Template.type -eq "vmess") "未生成 VMess 模板"
    Assert-True ($Template.port -eq 8443) "VMess 端口错误"
    Assert-True ($Template.uuid -eq $VmUuid) "VMess UUID 错误"
    Assert-True ($Template.'ws-opts'.path -eq "/fixture-ws") "VMess WS 路径错误"
    foreach ($JsonPath in @($SettingsPath, $TemplatePath)) {
        $Bytes = [IO.File]::ReadAllBytes($JsonPath)
        Assert-True (-not (
            $Bytes.Length -ge 3 -and
            $Bytes[0] -eq 0xEF -and
            $Bytes[1] -eq 0xBB -and
            $Bytes[2] -eq 0xBF
        )) "生成的 JSON 含 UTF-8 BOM：$JsonPath"
    }

    $TrojanPassword = "fixture-trojan-password"
    $TrojanResult = Invoke-Wizard @(
        "-NonInteractive",
        "-PrepareOnly",
        "-PreparedConfigurationDirectory", $PreparedRoot,
        "-Protocol", "trojan",
        "-Port", "2053",
        "-Controller", "http://127.0.0.1:9090",
        "-MixedProxy", "http://127.0.0.1:7890",
        "-Credential", $TrojanPassword,
        "-ServerName", "trojan.test.invalid",
        "-HostName", "trojan.test.invalid",
        "-WebSocketPath", "/trojan-ws"
    )
    Assert-True ($TrojanResult.ExitCode -eq 0) "Trojan PrepareOnly 失败：$($TrojanResult.Output)"
    Assert-True (-not $TrojanResult.Output.Contains($TrojanPassword)) "向导输出泄露 Trojan 密码"
    $TrojanTemplate = [IO.File]::ReadAllText($TemplatePath) | ConvertFrom-Json
    Assert-True ($TrojanTemplate.type -eq "trojan") "未生成 Trojan 模板"
    Assert-True ($TrojanTemplate.password -eq $TrojanPassword) "Trojan 密码错误"
    Assert-True (
        @(Get-ChildItem -LiteralPath $PreparedRoot -File -Filter "settings.json.backup-*").Count -eq 1
    ) "重新准备配置时未备份 settings.json"
    Assert-True (
        @(Get-ChildItem -LiteralPath $PreparedRoot -File -Filter "node_template.json.backup-*").Count -eq 1
    ) "重新准备配置时未备份 node_template.json"

    $CustomTemplatePath = Join-Path $TestRoot "custom template.json"
    $CustomTemplate = [ordered]@{
        type = "socks5"
        port = 443
        username = "fixture-user"
        password = "fixture-custom-password"
        tls = $true
    }
    [IO.File]::WriteAllText(
        $CustomTemplatePath,
        ($CustomTemplate | ConvertTo-Json -Depth 10),
        (New-Object Text.UTF8Encoding($false))
    )
    $CustomResult = Invoke-Wizard @(
        "-NonInteractive",
        "-PrepareOnly",
        "-PreparedConfigurationDirectory", (Join-Path $TestRoot "custom-output"),
        "-Protocol", "custom",
        "-Port", "2096",
        "-Controller", "http://127.0.0.1:9090",
        "-MixedProxy", "http://127.0.0.1:7890",
        "-CustomTemplatePath", $CustomTemplatePath
    )
    Assert-True ($CustomResult.ExitCode -eq 0) "自定义模板 PrepareOnly 失败：$($CustomResult.Output)"
    Assert-True (-not $CustomResult.Output.Contains("fixture-custom-password")) "向导输出泄露自定义密码"
    $PreparedCustom = [IO.File]::ReadAllText(
        (Join-Path $TestRoot "custom-output\node_template.json")
    ) | ConvertFrom-Json
    Assert-True ($PreparedCustom.type -eq "socks5") "自定义协议未保留"
    Assert-True ($PreparedCustom.port -eq 2096) "自定义端口覆盖失败"

    $InvalidRoot = Join-Path $TestRoot "invalid-output"
    $InvalidResult = Invoke-Wizard @(
        "-NonInteractive",
        "-PrepareOnly",
        "-PreparedConfigurationDirectory", $InvalidRoot,
        "-Protocol", "vless",
        "-Port", "443",
        "-Credential", "00000000-0000-0000-0000-000000000000",
        "-ServerName", "node.test.invalid",
        "-HostName", "node.test.invalid",
        "-WebSocketPath", "/fixture"
    )
    Assert-True ($InvalidResult.ExitCode -ne 0) "零 UUID 应被拒绝"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $InvalidRoot "settings.json"))) (
        "失败输入写入了 settings.json"
    )
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $InvalidRoot "node_template.json"))) (
        "失败输入写入了 node_template.json"
    )

    Assert-True (-not (Test-Path -LiteralPath (Join-Path $ReleaseRoot "settings.json"))) (
        "向导在 Release 目录残留 settings.json"
    )
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $ReleaseRoot "node_template.json"))) (
        "向导在 Release 目录残留 node_template.json"
    )
    $LauncherText = [IO.File]::ReadAllText($LauncherPath)
    Assert-True ($LauncherText.Contains("-STA")) "Install.cmd 未以 STA 启动向导"
    Assert-True ($LauncherText.Contains("%~dp0install_wizard.ps1")) (
        "Install.cmd 未使用自身目录定位向导"
    )
    Write-Output "WPF install wizard tests: OK"
    exit 0
} finally {
    if (Test-Path -LiteralPath $TestRoot -PathType Container) {
        $ResolvedRoot = (Resolve-Path -LiteralPath $TestRoot).Path
        $ResolvedTemp = (Resolve-Path -LiteralPath $env:TEMP).Path
        if (-not $ResolvedRoot.StartsWith(
            $ResolvedTemp + [IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            throw "拒绝清理非 TEMP 测试目录：$ResolvedRoot"
        }
        Remove-Item -LiteralPath $ResolvedRoot -Recurse -Force
    }
}
