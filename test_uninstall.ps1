#requires -Version 5.1
$ErrorActionPreference = "Stop"

function Get-ScheduledTask {
    [CmdletBinding()]
    param()
    if ($global:ClashCloudflareUninstallQueryFailure) {
        throw "simulated scheduler query failure"
    }
    return @($global:ClashCloudflareUninstallTasks)
}

function Stop-ScheduledTask {
    [CmdletBinding()]
    param([string]$TaskName)
    foreach ($Task in $global:ClashCloudflareUninstallTasks) {
        if ($Task.TaskName -eq $TaskName) {
            $Task.State = "Ready"
        }
    }
}

function Unregister-ScheduledTask {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$TaskName)
    $global:ClashCloudflareUninstallTasks = @(
        $global:ClashCloudflareUninstallTasks |
            Where-Object { $_.TaskName -ne $TaskName }
    )
}

function Assert-Uninstall($Condition, [string]$Message) {
    if (-not $Condition) {
        throw $Message
    }
}

$OriginalLocalAppData = $env:LOCALAPPDATA
$OriginalAppData = $env:APPDATA
$TestRoot = Join-Path ([IO.Path]::GetTempPath()) (
    "cfdyn-uninstall-test-" + [Guid]::NewGuid().ToString("N")
)
$UninstallScript = Join-Path $PSScriptRoot "uninstall.ps1"
$global:ClashCloudflareUninstallQueryFailure = $false
$global:ClashCloudflareUninstallTasks = @()

try {
    $env:LOCALAPPDATA = Join-Path $TestRoot "Local"
    $env:APPDATA = Join-Path $TestRoot "Roaming"
    $InstallDir = Join-Path $env:LOCALAPPDATA "ClashCloudflareDynamic"
    $ProviderDir = Join-Path $env:APPDATA "io.github.clash-verge-rev.clash-verge-rev\providers\ClashCloudflareDynamic"
    $ShortcutPath = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Clash Cloudflare Dynamic.lnk"
    New-Item -ItemType Directory -Path $InstallDir, $ProviderDir, (Split-Path -Parent $ShortcutPath) -Force | Out-Null
    Set-Content -LiteralPath $ShortcutPath -Value "test"
    $global:ClashCloudflareUninstallTasks = @(
        [PSCustomObject]@{ TaskName = "Clash Cloudflare Light Scan 30min"; State = "Running" },
        [PSCustomObject]@{ TaskName = "Clash Cloudflare Health Monitor 30min"; State = "Ready" }
    )

    & $UninstallScript

    Assert-Uninstall (@($global:ClashCloudflareUninstallTasks).Count -eq 0) "默认卸载未删除全部任务"
    Assert-Uninstall (-not (Test-Path -LiteralPath $ShortcutPath)) "默认卸载未删除通知快捷方式"
    Assert-Uninstall (Test-Path -LiteralPath $InstallDir) "默认卸载误删程序目录"
    Assert-Uninstall (Test-Path -LiteralPath $ProviderDir) "默认卸载误删 provider"

    New-Item -ItemType Directory -Path (Split-Path -Parent $ShortcutPath) -Force | Out-Null
    Set-Content -LiteralPath $ShortcutPath -Value "test"
    $global:ClashCloudflareUninstallTasks = @(
        [PSCustomObject]@{ TaskName = "Clash Cloudflare Light Scan 30min"; State = "Ready" }
    )
    $global:ClashCloudflareUninstallQueryFailure = $true
    $QueryFailureRaised = $false
    try {
        & $UninstallScript -RemoveData
    } catch {
        $QueryFailureRaised = $_.Exception.Message -like "*simulated scheduler query failure*"
    } finally {
        $global:ClashCloudflareUninstallQueryFailure = $false
    }
    Assert-Uninstall $QueryFailureRaised "任务查询失败未中止卸载"
    Assert-Uninstall (Test-Path -LiteralPath $ShortcutPath) "任务查询失败后仍删除快捷方式"
    Assert-Uninstall (Test-Path -LiteralPath $InstallDir) "任务查询失败后仍删除程序目录"
    Assert-Uninstall (Test-Path -LiteralPath $ProviderDir) "任务查询失败后仍删除 provider"

    & $UninstallScript -RemoveData
    Assert-Uninstall (@($global:ClashCloudflareUninstallTasks).Count -eq 0) "完整卸载未删除任务"
    Assert-Uninstall (-not (Test-Path -LiteralPath $InstallDir)) "完整卸载未删除程序目录"
    Assert-Uninstall (-not (Test-Path -LiteralPath $ProviderDir)) "完整卸载未删除 provider"
    Assert-Uninstall (-not (Test-Path -LiteralPath $ShortcutPath)) "完整卸载未删除快捷方式"

    Write-Output "uninstall.ps1 isolation tests: OK"
} finally {
    $env:LOCALAPPDATA = $OriginalLocalAppData
    $env:APPDATA = $OriginalAppData
    Remove-Variable -Name ClashCloudflareUninstallQueryFailure -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable -Name ClashCloudflareUninstallTasks -Scope Global -ErrorAction SilentlyContinue
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
