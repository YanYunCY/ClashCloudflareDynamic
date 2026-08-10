#requires -Version 5.1
param(
    [switch]$RemoveData
)

$ErrorActionPreference = "Stop"
$InstallDir = Join-Path $env:LOCALAPPDATA "ClashCloudflareDynamic"
$ProviderDir = Join-Path $env:APPDATA "io.github.clash-verge-rev.clash-verge-rev\providers\ClashCloudflareDynamic"
$ShortcutPath = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Clash Cloudflare Dynamic.lnk"
$Tasks = @(
    "Clash Cloudflare Dynamic Discovery 30min",
    "Clash Cloudflare Light Scan 2h",
    "Clash Cloudflare Deep Scan 5000 12h",
    "Clash Cloudflare Serial Light Scan 30min",
    "Clash Cloudflare Serial Deep Scan 5000 6h",
    "Clash Cloudflare Light Scan 30min",
    "Clash Cloudflare Deep Scan 5000 6h",
    "Clash Cloudflare Health Monitor 30min",
    "Clash Cloudflare Deep Scan 5000 30min"
    ,"Clash Cloudflare SG Light Scan 30min"
    ,"Clash Cloudflare SG Deep Scan 5000 6h"
    ,"v2rayN Cloudflare Light Scan 2h"
    ,"v2rayN Cloudflare Deep Scan 5000 12h"
    ,"v2rayN Cloudflare Health Monitor 30min"
    ,"v2rayN Cloudflare Light Scan 30min"
    ,"v2rayN Cloudflare Deep Scan 5000 6h"
)
$ScheduledTasks = @(Get-ScheduledTask -ErrorAction Stop)
$ScheduledTaskNames = @(
    $ScheduledTasks | ForEach-Object { [string]$_.TaskName }
)

foreach ($TaskName in $Tasks) {
    if ($ScheduledTaskNames -notcontains $TaskName) {
        Write-Host "计划任务不存在：$TaskName"
        continue
    }
    $Task = @(
        $ScheduledTasks | Where-Object { $_.TaskName -eq $TaskName }
    )[0]
    if ([string]$Task.State -eq "Running") {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
    $ScheduledTasks = @(Get-ScheduledTask -ErrorAction Stop)
    $ScheduledTaskNames = @(
        $ScheduledTasks | ForEach-Object { [string]$_.TaskName }
    )
    if ($ScheduledTaskNames -contains $TaskName) {
        throw "计划任务删除后仍然存在：$TaskName"
    }
    Write-Host "已删除计划任务：$TaskName"
}

if (Test-Path -LiteralPath $ShortcutPath) {
    Remove-Item -LiteralPath $ShortcutPath -Force -ErrorAction Stop
    Write-Host "已删除通知快捷方式：$ShortcutPath"
}

Write-Host ""
if ($RemoveData) {
    foreach ($Path in @($InstallDir, $ProviderDir)) {
        if (Test-Path -LiteralPath $Path) {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            Write-Host "已删除：$Path"
        }
    }
    Write-Host "任务、程序、日志和 provider 已完整删除。" -ForegroundColor Green
} else {
    Write-Host "计划任务和通知快捷方式已删除。" -ForegroundColor Green
    Write-Host "程序、配置和日志仍保留在：$InstallDir"
    Write-Host "含节点凭据的 provider 仍保留在：$ProviderDir" -ForegroundColor Yellow
    Write-Host "请先在 Clash 中切换到其他配置，再删除以上两个目录。"
    Write-Host "确认切换配置后，也可重新运行：.\uninstall.ps1 -RemoveData"
}
