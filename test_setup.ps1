#requires -Version 5.1
$ErrorActionPreference = "Stop"

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        throw $Message
    }
}

$TestRoot = Join-Path (
    [IO.Path]::GetTempPath()
) ("cfdyn-setup-test-" + [Guid]::NewGuid().ToString("N"))

try {
    $ExampleDir = Join-Path $TestRoot "examples"
    New-Item -ItemType Directory -Path $ExampleDir -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "setup.ps1") -Destination $TestRoot
    Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot "examples") -File -Filter "*.json" |
        ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $ExampleDir
        }

    $SetupScript = Join-Path $TestRoot "setup.ps1"
    $InvalidTemplatePath = Join-Path $TestRoot "invalid.local.json"
    [IO.File]::WriteAllText(
        $InvalidTemplatePath,
        '{"type":"custom","port":0}',
        (New-Object Text.UTF8Encoding($false))
    )
    $InvalidTemplateRejected = $false
    try {
        & $SetupScript -NodeTemplatePath $InvalidTemplatePath
    } catch {
        $InvalidTemplateRejected = $_.Exception.Message -like "*有效的 type*"
    }
    Assert-True $InvalidTemplateRejected "setup 未拒绝无效自定义模板"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $TestRoot "settings.json"))) "自定义模板预检失败前已写入 settings.json"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $TestRoot "node_template.json"))) "自定义模板预检失败前已写入 node_template.json"

    & $SetupScript -Protocol vmess -Port 443

    $SettingsPath = Join-Path $TestRoot "settings.json"
    $NodeTemplatePath = Join-Path $TestRoot "node_template.json"
    Assert-True (Test-Path -LiteralPath $SettingsPath -PathType Leaf) "setup 未创建 settings.json"
    Assert-True (Test-Path -LiteralPath $NodeTemplatePath -PathType Leaf) "setup 未创建 node_template.json"
    Assert-True (
        @(Get-ChildItem -LiteralPath $TestRoot -File -Filter "*.backup-*").Count -eq 0
    ) "首次指定端口时错误创建了备份"

    $SettingsBeforePortChange = [IO.File]::ReadAllText($SettingsPath)
    & $SetupScript -Port 2096
    $PortOnlyTemplate = [IO.File]::ReadAllText($NodeTemplatePath) |
        ConvertFrom-Json
    Assert-True ($PortOnlyTemplate.type -eq "vmess") "仅修改端口时错误更换了协议"
    Assert-True ($PortOnlyTemplate.port -eq 2096) "未在保留配置时修改节点端口"
    Assert-True (
        [IO.File]::ReadAllText($SettingsPath) -eq $SettingsBeforePortChange
    ) "仅修改端口时覆盖了 settings.json"
    Assert-True (
        @(Get-ChildItem -LiteralPath $TestRoot -File -Filter "node_template.json.backup-*").Count -eq 1
    ) "仅修改端口前未备份节点模板"

    $Marker = '{"local":"preserve-me"}'
    [IO.File]::WriteAllText(
        $SettingsPath,
        $Marker,
        (New-Object Text.UTF8Encoding($false))
    )
    & $SetupScript -Force

    $Backups = @(Get-ChildItem -LiteralPath $TestRoot -File -Filter "settings.json.backup-*")
    Assert-True ($Backups.Count -eq 1) "setup -Force 未创建唯一配置备份"
    Assert-True ([IO.File]::ReadAllText($Backups[0].FullName) -eq $Marker) "setup -Force 备份内容不正确"
    Assert-True ([IO.File]::ReadAllText($SettingsPath) -ne $Marker) "setup -Force 未恢复公开示例"

    $SettingsBeforeProtocolChange = [IO.File]::ReadAllText($SettingsPath)
    & $SetupScript -ReplaceNodeTemplate -Protocol vless -Port 8443
    $VlessTemplate = [IO.File]::ReadAllText($NodeTemplatePath) |
        ConvertFrom-Json
    Assert-True ($VlessTemplate.type -eq "vless") "setup 未选择 VLESS 模板"
    Assert-True ($VlessTemplate.port -eq 8443) "setup 未应用用户选择的 8443 端口"
    Assert-True (
        [IO.File]::ReadAllText($SettingsPath) -eq $SettingsBeforeProtocolChange
    ) "仅替换节点协议模板时覆盖了 settings.json"

    & $SetupScript -Force -Protocol trojan -Port 2053
    $TrojanTemplate = [IO.File]::ReadAllText($NodeTemplatePath) |
        ConvertFrom-Json
    Assert-True ($TrojanTemplate.type -eq "trojan") "setup 未选择 Trojan 模板"
    Assert-True ($TrojanTemplate.port -eq 2053) "setup 未应用用户选择的 2053 端口"
    Assert-True (
        $TrojanTemplate.password -eq "replace-with-your-password"
    ) "Trojan 示例密码不是安全占位值"
    $TemplateBytes = [IO.File]::ReadAllBytes($NodeTemplatePath)
    Assert-True (-not (
        $TemplateBytes.Length -ge 3 -and
        $TemplateBytes[0] -eq 0xEF -and
        $TemplateBytes[1] -eq 0xBB -and
        $TemplateBytes[2] -eq 0xBF
    )) "setup 写出的 node_template.json 含 UTF-8 BOM"

    Write-Output "setup.ps1 isolation tests: OK"
} finally {
    if (Test-Path -LiteralPath $TestRoot) {
        $ResolvedTestRoot = [IO.Path]::GetFullPath($TestRoot)
        $ResolvedTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (-not $ResolvedTestRoot.StartsWith(
            $ResolvedTempRoot,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            throw "拒绝清理非临时测试目录：$ResolvedTestRoot"
        }
        Remove-Item -LiteralPath $ResolvedTestRoot -Recurse -Force
    }
}
