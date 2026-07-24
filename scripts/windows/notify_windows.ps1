#requires -Version 5.1
param(
    [Parameter(Mandatory = $true)]
    [string]$Title,

    [Parameter(Mandatory = $true)]
    [string]$Message,

    [Parameter(Mandatory = $false)]
    [string]$DetailsPath,

    [Parameter(Mandatory = $false)]
    [double]$RetentionDays = 30,

    [Parameter(Mandatory = $false)]
    [int]$MaxReportFiles = 100,

    [Parameter(Mandatory = $false)]
    [long]$DeliveryLogMaxBytes = 1000000,

    [Parameter(Mandatory = $false)]
    [int]$DeliveryLogBackups = 2
)

$ErrorActionPreference = "Stop"
$AppUserModelId = "ClashCloudflareDynamic"
$LogDirectory = Join-Path $PSScriptRoot "logs"
$ReportDirectory = Join-Path $LogDirectory "notification_reports"
$DeliveryLogPath = Join-Path $LogDirectory "notification_delivery.log"
$NotificationScenario = "urgent"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Remove-OldNotificationReports {
    param(
        [string]$Directory,
        [DateTime]$Cutoff,
        [int]$MaximumCount,
        [string]$ProtectedPath
    )

    Get-ChildItem -LiteralPath $Directory -Filter "notification_*.html" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTimeUtc -lt $Cutoff } |
        ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
        }

    $Reports = @(
        Get-ChildItem -LiteralPath $Directory -Filter "notification_*.html" -File -ErrorAction SilentlyContinue |
            Sort-Object -Property `
                @{ Expression = "LastWriteTimeUtc"; Descending = $true }, `
                @{ Expression = "Name"; Descending = $true }
    )
    if ($Reports.Count -gt $MaximumCount) {
        $DeleteCount = $Reports.Count - $MaximumCount
        $Reports |
            Where-Object { $_.FullName -ine $ProtectedPath } |
            Select-Object -First $DeleteCount |
            ForEach-Object {
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
            }
    }

    $TempCutoff = [DateTime]::UtcNow.AddDays(-1)
    Get-ChildItem -LiteralPath $Directory -Filter "notification_*.html.tmp" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTimeUtc -lt $TempCutoff } |
        ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
        }
}

function Rotate-TextLog {
    param(
        [string]$Path,
        [long]$MaximumBytes,
        [int]$BackupCount
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return
    }
    $File = Get-Item -LiteralPath $Path
    if ($File.Length -lt $MaximumBytes) {
        return
    }

    $Oldest = "$Path.$BackupCount"
    if (Test-Path -LiteralPath $Oldest -PathType Leaf) {
        Remove-Item -LiteralPath $Oldest -Force
    }
    for ($Index = $BackupCount - 1; $Index -ge 1; $Index--) {
        $Source = "$Path.$Index"
        if (Test-Path -LiteralPath $Source -PathType Leaf) {
            Move-Item -LiteralPath $Source -Destination "$Path.$($Index + 1)" -Force
        }
    }
    Move-Item -LiteralPath $Path -Destination "$Path.1" -Force
}

New-Item -ItemType Directory -Path $ReportDirectory -Force | Out-Null
$InitialProtectedPath = $null
if (-not [string]::IsNullOrWhiteSpace($DetailsPath)) {
    $InitialProtectedPath = [IO.Path]::GetFullPath($DetailsPath)
}
$NormalizedRetentionDays = [Math]::Min(3650, [Math]::Max(1, $RetentionDays))
$NormalizedMaxReportFiles = [Math]::Min(10000, [Math]::Max(1, $MaxReportFiles))
$NormalizedDeliveryLogMaxBytes = [Math]::Max(64000, $DeliveryLogMaxBytes)
$NormalizedDeliveryLogBackups = [Math]::Min(20, [Math]::Max(1, $DeliveryLogBackups))
$RetentionCutoff = [DateTime]::UtcNow.AddDays(-$NormalizedRetentionDays)
Remove-OldNotificationReports `
    -Directory $ReportDirectory `
    -Cutoff $RetentionCutoff `
    -MaximumCount $NormalizedMaxReportFiles `
    -ProtectedPath $InitialProtectedPath

$ReportRoot = [IO.Path]::GetFullPath($ReportDirectory) + [IO.Path]::DirectorySeparatorChar
$ValidatedDetailsPath = $null
if (-not [string]::IsNullOrWhiteSpace($DetailsPath)) {
    $CandidatePath = [IO.Path]::GetFullPath($DetailsPath)
    $InsideReportDirectory = $CandidatePath.StartsWith(
        $ReportRoot,
        [StringComparison]::OrdinalIgnoreCase
    )
    if (
        -not $InsideReportDirectory -or
        [IO.Path]::GetExtension($CandidatePath) -ine ".html" -or
        -not (Test-Path -LiteralPath $CandidatePath -PathType Leaf)
    ) {
        throw "DetailsPath 必须是 notification_reports 目录内现有的 HTML 文件"
    }
    $ValidatedDetailsPath = $CandidatePath
}

if ($null -eq $ValidatedDetailsPath) {
    $Now = Get-Date
    $UniqueName = "notification_{0}_{1}_{2}.html" -f `
        $Now.ToString("yyyyMMdd_HHmmss_ffffff"), $PID, [Guid]::NewGuid().ToString("N")
    $ValidatedDetailsPath = Join-Path $ReportDirectory $UniqueName
    $TempPath = "$ValidatedDetailsPath.tmp"
    try {
        $EncodedTitle = [Net.WebUtility]::HtmlEncode($Title)
        $EncodedMessage = [Net.WebUtility]::HtmlEncode($Message)
        $EncodedTime = [Net.WebUtility]::HtmlEncode($Now.ToString("yyyy-MM-dd HH:mm:ss"))
        $Report = @"
<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="referrer" content="no-referrer">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
<title>$EncodedTitle</title>
<style>body{font:15px "Segoe UI","Microsoft YaHei",sans-serif;max-width:900px;margin:32px auto;padding:0 20px;line-height:1.65;color:#17202a;background:#f4f6f8}main{background:#fff;border:1px solid #d5dce3;padding:22px}h1{font-size:22px;margin:0 0 4px}.meta{color:#5d6d7e}.message{white-space:pre-wrap;margin-top:20px}@media(prefers-color-scheme:dark){body{background:#15191d;color:#edf2f7}main{background:#20262c;border-color:#3b4650}.meta{color:#aebac5}}</style>
</head><body><main><h1>$EncodedTitle</h1><div class="meta">$EncodedTime</div><div class="message">$EncodedMessage</div></main></body></html>
"@
        [IO.File]::WriteAllText($TempPath, $Report, $Utf8NoBom)
        [IO.File]::Move($TempPath, $ValidatedDetailsPath)
    } finally {
        if (Test-Path -LiteralPath $TempPath) {
            Remove-Item -LiteralPath $TempPath -Force -ErrorAction SilentlyContinue
        }
    }
}
$CurrentReportPath = $ValidatedDetailsPath
Remove-OldNotificationReports `
    -Directory $ReportDirectory `
    -Cutoff $RetentionCutoff `
    -MaximumCount $NormalizedMaxReportFiles `
    -ProtectedPath $CurrentReportPath
if (-not (Test-Path -LiteralPath $CurrentReportPath -PathType Leaf)) {
    throw "当前通知报告在保留数量清理后不存在"
}
$DetailsUri = ([Uri]::new($ValidatedDetailsPath)).AbsoluteUri

[void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
[void][Windows.UI.Notifications.ToastNotification, Windows.UI.Notifications, ContentType = WindowsRuntime]
[void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]

$Xml = [Windows.Data.Xml.Dom.XmlDocument]::new()
$Xml.LoadXml(@'
<toast duration="short" scenario="urgent" activationType="protocol">
  <visual>
    <binding template="ToastGeneric">
      <text />
      <text hint-wrap="true" />
    </binding>
  </visual>
  <actions>
    <action content="查看完整结果" activationType="protocol" />
  </actions>
  <audio silent="true" />
</toast>
'@)
$TextNodes = $Xml.GetElementsByTagName("text")
[void]$TextNodes.Item(0).AppendChild($Xml.CreateTextNode($Title))
[void]$TextNodes.Item(1).AppendChild($Xml.CreateTextNode($Message))

$ToastNode = $Xml.SelectSingleNode("/toast")
$ToastNode.SetAttribute("launch", $DetailsUri)
$ActionNode = $Xml.SelectSingleNode("/toast/actions/action")
$ActionNode.SetAttribute("arguments", $DetailsUri)

$Toast = [Windows.UI.Notifications.ToastNotification]::new($Xml)
$Toast.SuppressPopup = $false
$Notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier(
    $AppUserModelId
)
$Notifier.Show($Toast)
try {
    Rotate-TextLog `
        -Path $DeliveryLogPath `
        -MaximumBytes $NormalizedDeliveryLogMaxBytes `
        -BackupCount $NormalizedDeliveryLogBackups
    $SafeTitle = ($Title -replace '[\r\n]+', ' ').Trim()
    $DeliveryLine = "[{0}] submitted app={1} scenario={2} title={3}{4}" -f `
        ([DateTimeOffset]::Now.ToString("o")), `
        $AppUserModelId, `
        $NotificationScenario, `
        $SafeTitle, `
        [Environment]::NewLine
    [IO.File]::AppendAllText($DeliveryLogPath, $DeliveryLine, $Utf8NoBom)
} catch {
    # Toast submission already succeeded; an audit-log failure must not turn
    # a delivered notification into a scan failure.
}
