#requires -Version 5.1
param(
    [switch]$Force,
    [switch]$ReplaceNodeTemplate,
    [ValidateSet("vmess", "vless", "trojan")]
    [string]$Protocol = "vmess",
    [int]$Port = 0,
    [string]$NodeTemplatePath
)

$ErrorActionPreference = "Stop"
$Root = $PSScriptRoot
$LocalNodeTemplatePath = Join-Path $Root "node_template.json"
$NodeTemplateExistedAtStart = Test-Path `
    -LiteralPath $LocalNodeTemplatePath `
    -PathType Leaf

if ($Port -ne 0 -and ($Port -lt 1 -or $Port -gt 65535)) {
    throw "Port 必须为 1 到 65535；省略或设为 0 时使用模板默认端口。"
}
$SettingsExamplePath = Join-Path $Root "examples\settings.example.json"
if ([string]::IsNullOrWhiteSpace($NodeTemplatePath)) {
    $ProtocolExamples = @{
        vmess = "examples\node_template.example.json"
        vless = "examples\node_template.vless.example.json"
        trojan = "examples\node_template.trojan.example.json"
    }
    $SelectedTemplatePath = Join-Path $Root $ProtocolExamples[$Protocol]
} else {
    if (-not (Test-Path -LiteralPath $NodeTemplatePath -PathType Leaf)) {
        throw "自定义节点模板不存在：$NodeTemplatePath"
    }
    $SelectedTemplatePath = (Resolve-Path -LiteralPath $NodeTemplatePath).Path
}

$TemplateValidationPath = $SelectedTemplatePath
if ((Test-Path -LiteralPath $LocalNodeTemplatePath -PathType Leaf) -and
    -not $Force -and
    -not $ReplaceNodeTemplate) {
    $TemplateValidationPath = $LocalNodeTemplatePath
}
try {
    $null = [IO.File]::ReadAllText($SettingsExamplePath) | ConvertFrom-Json
    $TemplatePreflight = [IO.File]::ReadAllText($TemplateValidationPath) |
        ConvertFrom-Json
} catch {
    throw "无法解析初始化 JSON：$($_.Exception.Message)"
}
$TemplatePreflightType = [string]$TemplatePreflight.type
$TemplatePreflightPort = 0
if ([string]::IsNullOrWhiteSpace($TemplatePreflightType) -or
    -not [int]::TryParse(
        [string]$TemplatePreflight.port,
        [ref]$TemplatePreflightPort
    ) -or
    $TemplatePreflightPort -lt 1 -or
    $TemplatePreflightPort -gt 65535) {
    throw "节点模板必须包含有效的 type 和 1 到 65535 端口。"
}

$Mappings = @(
    @{
        Example = $SettingsExamplePath
        Local = (Join-Path $Root "settings.json")
        Overwrite = [bool]$Force
    },
    @{
        Example = $SelectedTemplatePath
        Local = $LocalNodeTemplatePath
        Overwrite = [bool]($Force -or $ReplaceNodeTemplate)
    }
)

foreach ($Mapping in $Mappings) {
    if (-not (Test-Path -LiteralPath $Mapping.Example -PathType Leaf)) {
        throw "缺少示例文件：$($Mapping.Example)"
    }
}

foreach ($Mapping in $Mappings) {
    $ExamplePath = $Mapping.Example
    $LocalPath = $Mapping.Local
    if ((Test-Path -LiteralPath $LocalPath) -and -not $Mapping.Overwrite) {
        Write-Host "保留现有本地文件：$LocalPath"
        continue
    }
    if ((Test-Path -LiteralPath $LocalPath) -and $Mapping.Overwrite) {
        $Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $BackupPath = "$LocalPath.backup-$Stamp"
        $Suffix = 1
        while (Test-Path -LiteralPath $BackupPath) {
            $BackupPath = "$LocalPath.backup-$Stamp-$Suffix"
            $Suffix += 1
        }
        Copy-Item -LiteralPath $LocalPath -Destination $BackupPath
        Write-Host "已备份现有本地文件：$BackupPath" -ForegroundColor Yellow
    }
    if (-not [IO.Path]::GetFullPath($ExamplePath).Equals(
        [IO.Path]::GetFullPath($LocalPath),
        [StringComparison]::OrdinalIgnoreCase
    )) {
        Copy-Item -LiteralPath $ExamplePath -Destination $LocalPath -Force
    }
    Write-Host "已创建本地文件：$LocalPath"
}

if ($Port -ne 0) {
    if ($NodeTemplateExistedAtStart -and
        -not $Force -and
        -not $ReplaceNodeTemplate) {
        $Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $BackupPath = "$LocalNodeTemplatePath.backup-$Stamp"
        $Suffix = 1
        while (Test-Path -LiteralPath $BackupPath) {
            $BackupPath = "$LocalNodeTemplatePath.backup-$Stamp-$Suffix"
            $Suffix += 1
        }
        Copy-Item -LiteralPath $LocalNodeTemplatePath -Destination $BackupPath
        Write-Host "已备份现有节点模板：$BackupPath" -ForegroundColor Yellow
    }
    try {
        $NodeTemplate = [IO.File]::ReadAllText($LocalNodeTemplatePath) |
            ConvertFrom-Json
    } catch {
        throw "无法解析 node_template.json：$($_.Exception.Message)"
    }
    if ($NodeTemplate.PSObject.Properties.Name -contains "port") {
        $NodeTemplate.port = $Port
    } else {
        $NodeTemplate | Add-Member -NotePropertyName "port" -NotePropertyValue $Port
    }
    $Utf8NoBom = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText(
        $LocalNodeTemplatePath,
        ($NodeTemplate | ConvertTo-Json -Depth 30),
        $Utf8NoBom
    )
}

$PreparedTemplate = [IO.File]::ReadAllText($LocalNodeTemplatePath) |
    ConvertFrom-Json
$PreparedProtocol = [string]$PreparedTemplate.type
$PreparedPort = [int]$PreparedTemplate.port
Write-Host "节点模板：协议 $PreparedProtocol，端口 $PreparedPort" -ForegroundColor Cyan
$CloudflareHttpsPorts = @(443, 2053, 2083, 2087, 2096, 8443)
if ($PreparedPort -notin $CloudflareHttpsPorts) {
    Write-Warning (
        "端口 $PreparedPort 不在 Cloudflare 普通代理的标准 HTTPS 端口列表中。" +
        "如未使用 Spectrum 或其他专用产品，真实链路可能无法建立。"
    )
}

Write-Host ""
Write-Host "下一步：" -ForegroundColor Cyan
Write-Host "1. 编辑 settings.json，确认 Mihomo controller、secret 和 mixed_proxy。"
Write-Host "2. 编辑 node_template.json，核对协议、端口、认证与 TLS/传输参数。"
Write-Host "3. 运行：powershell -ExecutionPolicy Bypass -File .\install_hybrid_5000.ps1"
Write-Host ""
Write-Host "settings.json 和 node_template.json 已被 .gitignore 排除，请勿强制提交。" -ForegroundColor Yellow
