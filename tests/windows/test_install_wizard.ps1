$ErrorActionPreference = "Stop"

$RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$ReleaseRoot = Join-Path $RepositoryRoot "dist\ClashCloudflareDynamic"
$WizardPath = Join-Path $ReleaseRoot "install_wizard.ps1"
$LauncherPath = Join-Path $ReleaseRoot "Install.cmd"
if (-not (Test-Path -LiteralPath $WizardPath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $LauncherPath -PathType Leaf)) {
    throw "缺少测试发布包中的安装向导；请先运行 python .\tools\build_release.py"
}

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        throw $Message
    }
}

$WizardTokens = $null
$WizardParseErrors = $null
$WizardAst = [Management.Automation.Language.Parser]::ParseFile(
    $WizardPath,
    [ref]$WizardTokens,
    [ref]$WizardParseErrors
)
Assert-True ($WizardParseErrors.Count -eq 0) (
    "安装向导 PowerShell AST 解析失败：" +
    (($WizardParseErrors | ForEach-Object Message) -join "；")
)
$InstallFormAst = $WizardAst.Find({
    param($Node)
    $Node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $Node.Name -eq "Show-InstallForm"
}, $true)
Assert-True ($null -ne $InstallFormAst) "安装向导缺少 Show-InstallForm"
$InstallFormText = $InstallFormAst.Extent.Text
foreach ($PageTitle in @("连接与协议", "节点参数", "确认安装")) {
    Assert-True ($InstallFormText.Contains($PageTitle)) "安装向导缺少步骤：$PageTitle"
}
foreach ($PageState in @(
    @{ Control = "ConnectionPage"; Index = 0 },
    @{ Control = "NodePage"; Index = 1 },
    @{ Control = "ReviewPage"; Index = 2 }
)) {
    $VisiblePattern = (
        '\${0}\.Visible\s*=\s*\$UiState\.CurrentPage\s*-eq\s*{1}' -f
        $PageState.Control,
        $PageState.Index
    )
    Assert-True ([regex]::IsMatch($InstallFormText, $VisiblePattern)) (
        "步骤页状态映射缺失：$($PageState.Control) -> $($PageState.Index)"
    )
}
Assert-True ($InstallFormText.Contains('CurrentPage = 0')) "UI 状态没有从第 1 步初始化"
Assert-True ($InstallFormText.Contains('ConfirmedCustomPort = $null')) "非标准端口确认状态缺失"
Assert-True ($InstallFormText.Contains('$UiState.CurrentPage -= 1')) "向导缺少返回状态迁移"
Assert-True ($InstallFormText.Contains('$UiState.CurrentPage = 1')) "向导缺少进入第 2 步状态迁移"
Assert-True ($InstallFormText.Contains('$UiState.CurrentPage = 2')) "向导缺少进入第 3 步状态迁移"
Assert-True ($InstallFormText.Contains('{ "开始安装" } else { "继续" }')) (
    "最终步骤按钮没有切换为开始安装"
)

foreach ($PasswordControl in @("SecretBox", "CredentialBox")) {
    $PasswordAssignments = @($InstallFormAst.FindAll({
        param($Node)
        $Node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $Node.Left.Extent.Text -eq "`$$PasswordControl.UseSystemPasswordChar"
    }, $true))
    Assert-True ($PasswordAssignments.Count -gt 0) "$PasswordControl 没有启用密码掩码"
    foreach ($Assignment in $PasswordAssignments) {
        Assert-True ($Assignment.Right.Extent.Text -eq '$true') (
            "$PasswordControl 存在关闭密码掩码的赋值"
        )
    }
}

$ExpectedSummaryValues = @{
    NodeCredential = @("已设置（已隐藏）", "由自定义模板提供（已隐藏）")
    ApiCredential = @("已设置（已隐藏）", "未设置")
}
foreach ($SummaryKey in $ExpectedSummaryValues.Keys) {
    $SummaryAssignment = $InstallFormAst.Find({
        param($Node)
        $Node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $Node.Left.Extent.Text -eq "`$SummaryValueLabels[`"$SummaryKey`"].Text"
    }, $true)
    Assert-True ($null -ne $SummaryAssignment) "确认页缺少脱敏摘要：$SummaryKey"
    $OutputValues = @(
        $SummaryAssignment.Right.FindAll({
            param($Node)
            $Node -is [Management.Automation.Language.StringConstantExpressionAst] -and
            $Node.Parent -is [Management.Automation.Language.CommandExpressionAst]
        }, $true) | ForEach-Object Value | Sort-Object -Unique
    )
    $ExpectedValues = @($ExpectedSummaryValues[$SummaryKey] | Sort-Object -Unique)
    Assert-True (($OutputValues -join "|") -eq ($ExpectedValues -join "|")) (
        "确认页 $SummaryKey 脱敏输出异常：$($OutputValues -join '、')"
    )
}

Assert-True ($InstallFormText.Contains('$SummaryValueLabels["Transport"].Text')) (
    "确认页没有显示 WS 路径或自定义模板文件名"
)
Assert-True ($InstallFormText.Contains('$FormatSummaryUri')) "确认页 URI 没有脱敏处理"
Assert-True ($InstallFormText.Contains('"***@"')) "确认页 URI 用户信息脱敏标记缺失"
Assert-True (-not $InstallFormText.Contains('$Parsed.PathAndQuery')) (
    "确认页 URI 不应显示可能含令牌的路径或查询参数"
)
Assert-True (-not $InstallFormText.Contains('$Parsed.Fragment')) (
    "确认页 URI 不应显示可能含令牌的 Fragment"
)
Assert-True ($InstallFormText.Contains('$Form.AutoScroll = $true')) "小屏幕缺少滚动兜底"
Assert-True ($InstallFormText.Contains('$Form.MaximizeBox = $true')) "主向导无法最大化"

$CleanupTry = $WizardAst.Find({
    param($Node)
    $Node -is [Management.Automation.Language.TryStatementAst] -and
    $null -ne $Node.Finally -and
    $Node.Finally.Extent.Text.Contains('$OwnedStagePath')
}, $true)
Assert-True ($null -ne $CleanupTry) "没有找到临时凭据清理 finally"
$CleanupText = $CleanupTry.Finally.Extent.Text
Assert-True ($CleanupText.Contains('$Attempt -le 3')) "临时凭据清理没有重试"
Assert-True ($CleanupText.Contains('需要清理临时配置')) "临时凭据清理失败没有明确标题"
Assert-True ($CleanupText.Contains('MessageBoxIcon]::Warning')) (
    "临时凭据清理失败没有显式警告"
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

$DialogCall = '        $DialogResult = $Form.ShowDialog()'
$UiRuntimeHarness = @'
    $Form.ShowInTaskbar = $false
    $Form.Opacity = 0
    $Form.Add_Shown({
        try {
            $ProtocolBox.SelectedIndex = 0
            $PortBox.Text = "443"
            $ControllerBox.Text = "http://127.0.0.1:9090"
            $MixedBox.Text = "http://127.0.0.1:7890"
            $NextButton.PerformClick()
            if ($UiState.CurrentPage -ne 1) {
                throw "继续按钮没有进入第 2 步"
            }
            [void]$script:WizardUiTestTrace.Add(1)

            $CredentialBox.Text = "11111111-2222-3333-4444-555555555555"
            $ServerBox.Text = "node.test.invalid"
            $HostBox.Text = "node.test.invalid"
            $PathBox.Text = "/fixture-ws"
            $NextButton.PerformClick()
            if ($UiState.CurrentPage -ne 2) {
                throw "继续按钮没有进入第 3 步：$($ErrorLabel.Text)"
            }
            [void]$script:WizardUiTestTrace.Add(2)

            $BackButton.PerformClick()
            if ($UiState.CurrentPage -ne 1) {
                throw "返回按钮没有回到第 2 步"
            }
            [void]$script:WizardUiTestTrace.Add(1)

            $NextButton.PerformClick()
            if ($UiState.CurrentPage -ne 2) {
                throw "返回后无法再次进入第 3 步：$($ErrorLabel.Text)"
            }
            [void]$script:WizardUiTestTrace.Add(2)
            $NextButton.PerformClick()
        } catch {
            $script:WizardUiTestError = $_.Exception.Message
            $Form.DialogResult = [Windows.Forms.DialogResult]::Abort
            $Form.Close()
        }
    })
'@
$InstrumentedInstallForm = $InstallFormText.Replace(
    $DialogCall,
    $UiRuntimeHarness + "`r`n" + $DialogCall
)
Assert-True ($InstrumentedInstallForm -ne $InstallFormText) (
    "无法注入安装向导 UI 运行时测试"
)
Invoke-Expression $InstrumentedInstallForm
$CloudflareHttpsPorts = @(443, 2053, 2083, 2087, 2096, 8443)
$ExamplesRoot = Join-Path $ReleaseRoot "examples"
$script:WizardUiTestTrace = New-Object Collections.ArrayList
$script:WizardUiTestError = $null
$UiRuntimeResult = Show-InstallForm
Assert-True ([string]::IsNullOrWhiteSpace($script:WizardUiTestError)) (
    "安装向导 UI 运行时测试失败：$script:WizardUiTestError"
)
Assert-True (($script:WizardUiTestTrace -join ",") -eq "1,2,1,2") (
    "安装向导翻页轨迹异常：$($script:WizardUiTestTrace -join ',')"
)
Assert-True ($null -ne $UiRuntimeResult) "开始安装按钮没有返回配置"
Assert-True ($UiRuntimeResult.Protocol -eq "vmess") "UI 运行时返回协议错误"
Assert-True ($UiRuntimeResult.Port -eq 443) "UI 运行时返回端口错误"
Assert-True ($UiRuntimeResult.ServerName -eq "node.test.invalid") (
    "UI 运行时返回 SNI 错误"
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
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $InvalidRoot "settings.json"))) "失败输入写入了 settings.json"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $InvalidRoot "node_template.json"))) "失败输入写入了 node_template.json"

    $TransientBefore = @(
        Get-ChildItem -LiteralPath $env:TEMP -Directory -Filter "ClashCloudflareDynamicInstaller-*" |
            ForEach-Object { $_.FullName }
    )
    $TransientFailure = Invoke-Wizard @(
        "-NonInteractive",
        "-Protocol", "vmess",
        "-Port", "443",
        "-Credential", "not-a-uuid",
        "-ServerName", "node.test.invalid",
        "-HostName", "node.test.invalid",
        "-WebSocketPath", "/fixture"
    )
    Assert-True ($TransientFailure.ExitCode -ne 0) "无效临时配置应失败"
    $TransientAfter = @(
        Get-ChildItem -LiteralPath $env:TEMP -Directory -Filter "ClashCloudflareDynamicInstaller-*" |
            ForEach-Object { $_.FullName }
    )
    Assert-True (
        (($TransientBefore | Sort-Object) -join "|") -eq
        (($TransientAfter | Sort-Object) -join "|")
    ) "失败后残留含凭据的临时配置目录"

    Assert-True (-not (Test-Path -LiteralPath (Join-Path $ReleaseRoot "settings.json"))) "向导在 Release 目录残留 settings.json"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $ReleaseRoot "node_template.json"))) "向导在 Release 目录残留 node_template.json"
    $LauncherText = [IO.File]::ReadAllText($LauncherPath)
    Assert-True ($LauncherText.Contains("-STA")) "Install.cmd 未以 STA 启动向导"
    Assert-True ($LauncherText.Contains("%~dp0install_wizard.ps1")) "Install.cmd 未使用自身目录定位向导"
    Write-Output "install wizard isolation tests: OK"
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
