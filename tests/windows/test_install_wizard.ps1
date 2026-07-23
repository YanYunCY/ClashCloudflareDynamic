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
    $WizardText = [IO.File]::ReadAllText($WizardPath)
    Assert-True ($WizardText.Contains('$Attempt -le 3')) "临时凭据清理没有重试"
    Assert-True ($WizardText.Contains('MessageBoxIcon]::Warning')) "临时凭据清理失败没有显式警告"

    Write-Output "install wizard isolation tests: OK"
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
