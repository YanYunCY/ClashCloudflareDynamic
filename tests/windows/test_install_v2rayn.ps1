#requires -Version 5.1
$ErrorActionPreference = "Stop"

function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -ne $Actual) {
        throw "$Message；期望=$Expected，实际=$Actual"
    }
}

function Invoke-PrepareOnly(
    [string]$Installer,
    [string]$FakeRoot,
    [string]$Target,
    [string]$Uuid,
    [string]$ServerName = "edge.test.invalid",
    [string]$MixedProxy = "http://127.0.0.1:18080"
) {
    $PreviousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $Output = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
            -File $Installer `
            -NonInteractive `
            -PrepareOnly `
            -V2rayNRoot $FakeRoot `
            -Uuid $Uuid `
            -Port 443 `
            -ServerName $ServerName `
            -HostName $ServerName `
            -WebSocketPath "/ws-test" `
            -MixedProxy $MixedProxy `
            -PreparedConfigurationDirectory $Target 2>&1
        $ExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $PreviousErrorActionPreference
    }
    return [PSCustomObject]@{
        ExitCode = $ExitCode
        Output = ($Output | Out-String)
    }
}

$RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$Installer = Join-Path $RepositoryRoot "scripts\windows\install_v2rayn.ps1"
$TempRoot = Join-Path ([IO.Path]::GetTempPath()) ("ccd-v2rayn-test-" + [Guid]::NewGuid().ToString("N"))

try {
    $FakeRoot = Join-Path $TempRoot "portable-v2rayn"
    foreach ($Directory in @(
        $FakeRoot,
        (Join-Path $FakeRoot "guiConfigs"),
        (Join-Path $FakeRoot "bin\xray")
    )) {
        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    }
    foreach ($File in @(
        (Join-Path $FakeRoot "v2rayN.exe"),
        (Join-Path $FakeRoot "guiConfigs\guiNDB.db"),
        (Join-Path $FakeRoot "guiConfigs\guiNConfig.json"),
        (Join-Path $FakeRoot "bin\xray\xray.exe")
    )) {
        [IO.File]::WriteAllBytes($File, [byte[]](0))
    }

    $Prepared = Join-Path $TempRoot "prepared"
    $Valid = Invoke-PrepareOnly `
        -Installer $Installer `
        -FakeRoot $FakeRoot `
        -Target $Prepared `
        -Uuid "11111111-1111-4111-8111-111111111111"
    Assert-Equal 0 $Valid.ExitCode "PrepareOnly 有效配置生成失败：$($Valid.Output)"

    $SettingsPath = Join-Path $Prepared "settings.json"
    $TemplatePath = Join-Path $Prepared "node_template.json"
    if (-not (Test-Path -LiteralPath $SettingsPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $TemplatePath -PathType Leaf)) {
        throw "PrepareOnly 未生成 settings.json 和 node_template.json"
    }
    $Settings = [IO.File]::ReadAllText($SettingsPath) | ConvertFrom-Json
    $Template = [IO.File]::ReadAllText($TemplatePath) | ConvertFrom-Json
    Assert-Equal "v2rayn" $Settings.client_mode "client_mode 错误"
    Assert-Equal $false $Settings.v2rayn_enable_sg "公开安装不应默认启用 SG"
    Assert-Equal $false $Settings.v2rayn_enable_la_vless "公开安装不应默认启用 VLESS"
    Assert-Equal $false $Settings.v2rayn_compare_hy2 "公开安装不应默认启用 HY2"
    Assert-Equal "http://127.0.0.1:18080" $Settings.mixed_proxy "本地代理端口未保留"
    Assert-Equal "vmess" $Template.type "模板协议错误"
    Assert-Equal "edge.test.invalid" $Template.servername "SNI 未写入模板"
    Assert-Equal "/ws-test" $Template.'ws-opts'.path "WebSocket 路径错误"
    foreach ($JsonPath in @($SettingsPath, $TemplatePath)) {
        $Bytes = [IO.File]::ReadAllBytes($JsonPath)
        if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and
            $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
            throw "生成的 JSON 不应包含 UTF-8 BOM：$JsonPath"
        }
    }

    $DefaultsTarget = Join-Path $TempRoot "defaults"
    $DefaultsOutput = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
        -File $Installer `
        -NonInteractive `
        -PrepareOnly `
        -V2rayNRoot $FakeRoot `
        -Uuid "11111111-1111-4111-8111-111111111111" `
        -ServerName "edge.test.invalid" `
        -HostName "edge.test.invalid" `
        -PreparedConfigurationDirectory $DefaultsTarget 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "非交互默认配置生成失败：$($DefaultsOutput | Out-String)"
    }
    $DefaultSettings = [IO.File]::ReadAllText(
        (Join-Path $DefaultsTarget "settings.json")
    ) | ConvertFrom-Json
    $DefaultTemplate = [IO.File]::ReadAllText(
        (Join-Path $DefaultsTarget "node_template.json")
    ) | ConvertFrom-Json
    Assert-Equal "http://127.0.0.1:10808" $DefaultSettings.mixed_proxy "默认本地代理错误"
    Assert-Equal 443 $DefaultTemplate.port "默认 VMess 端口错误"
    Assert-Equal "/ws" $DefaultTemplate.'ws-opts'.path "默认 WebSocket 路径错误"

    $InvalidUuidTarget = Join-Path $TempRoot "invalid-uuid"
    $InvalidUuid = Invoke-PrepareOnly `
        -Installer $Installer `
        -FakeRoot $FakeRoot `
        -Target $InvalidUuidTarget `
        -Uuid "not-a-uuid"
    if ($InvalidUuid.ExitCode -eq 0) { throw "安装器接受了无效 UUID" }
    if (Test-Path -LiteralPath $InvalidUuidTarget) {
        throw "无效 UUID 失败前不应创建配置目录"
    }

    $InvalidDomainTarget = Join-Path $TempRoot "invalid-domain"
    $InvalidDomain = Invoke-PrepareOnly `
        -Installer $Installer `
        -FakeRoot $FakeRoot `
        -Target $InvalidDomainTarget `
        -Uuid "11111111-1111-4111-8111-111111111111" `
        -ServerName "example.com"
    if ($InvalidDomain.ExitCode -eq 0) { throw "安装器接受了公开示例域名" }
    if (Test-Path -LiteralPath $InvalidDomainTarget) {
        throw "示例域名失败前不应创建配置目录"
    }

    $InvalidProxyTarget = Join-Path $TempRoot "invalid-proxy"
    $InvalidProxy = Invoke-PrepareOnly `
        -Installer $Installer `
        -FakeRoot $FakeRoot `
        -Target $InvalidProxyTarget `
        -Uuid "11111111-1111-4111-8111-111111111111" `
        -MixedProxy "http://192.0.2.1:10808"
    if ($InvalidProxy.ExitCode -eq 0) { throw "安装器接受了非回环代理" }
    if (Test-Path -LiteralPath $InvalidProxyTarget) {
        throw "非回环代理失败前不应创建配置目录"
    }

    $InstallerText = [IO.File]::ReadAllText($Installer)
    $PrepareOnlyIndex = $InstallerText.IndexOf('if ($PrepareOnly)')
    $TaskMutationIndex = $InstallerText.IndexOf('Register-ScheduledTask')
    if ($PrepareOnlyIndex -lt 0 -or $TaskMutationIndex -le $PrepareOnlyIndex) {
        throw "PrepareOnly 分支必须在计划任务写入之前退出"
    }
    foreach ($ConflictingTask in @(
        "Clash Cloudflare Dynamic Discovery 30min",
        "Clash Cloudflare Deep Scan 5000 30min",
        "Clash Cloudflare SG Light Scan 30min",
        "v2rayN Cloudflare Light Scan 30min"
    )) {
        if ($InstallerText -notlike "*$ConflictingTask*") {
            throw "v2rayN 安装器缺少历史冲突任务迁移：$ConflictingTask"
        }
    }
    foreach ($PrivateName in @("settings.json", "node_template.json")) {
        if (Test-Path -LiteralPath (Join-Path $RepositoryRoot $PrivateName)) {
            throw "安装测试把私有配置写入了仓库根目录：$PrivateName"
        }
    }

    Write-Host "v2rayN installer isolation tests passed"
} finally {
    if (Test-Path -LiteralPath $TempRoot) {
        Remove-Item -LiteralPath $TempRoot -Recurse -Force
    }
}
