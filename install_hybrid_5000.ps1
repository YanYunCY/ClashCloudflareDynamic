#requires -Version 5.1
param(
    [switch]$NoOpenExplorer
)

$ErrorActionPreference = "Stop"

function New-CompatibleTaskSettings {
    param(
        [Parameter(Mandatory = $true)]
        [TimeSpan]$ExecutionTimeLimit
    )

    $SettingsArgs = @{
        StartWhenAvailable = $true
        MultipleInstances = "IgnoreNew"
        ExecutionTimeLimit = $ExecutionTimeLimit
    }

    # 不同 Windows / ScheduledTasks 模块版本支持的电池参数可能不同。
    $Supported = (Get-Command New-ScheduledTaskSettingsSet).Parameters
    if ($Supported.ContainsKey("AllowStartIfOnBatteries")) {
        $SettingsArgs["AllowStartIfOnBatteries"] = $true
    }
    if ($Supported.ContainsKey("DontStopIfGoingOnBatteries")) {
        $SettingsArgs["DontStopIfGoingOnBatteries"] = $true
    }
    if ($Supported.ContainsKey("Hidden")) {
        $SettingsArgs["Hidden"] = $true
    }
    if ($Supported.ContainsKey("Priority")) {
        $SettingsArgs["Priority"] = 7
    }

    return New-ScheduledTaskSettingsSet @SettingsArgs
}

function Read-JsonObject([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "JSON 文件不存在：$Path"
    }
    try {
        $Text = [IO.File]::ReadAllText($Path)
        if ([string]::IsNullOrWhiteSpace($Text)) {
            throw "文件为空"
        }
        return $Text | ConvertFrom-Json
    } catch {
        throw "无法解析 JSON 文件 $Path：$($_.Exception.Message)"
    }
}

function Assert-PublicConfigurationReady(
    [string]$SettingsPath,
    [string]$TemplatePath
) {
    $Settings = Read-JsonObject $SettingsPath
    $Template = Read-JsonObject $TemplatePath

    foreach ($RequiredName in @(
        "controller",
        "secret",
        "mixed_proxy",
        "active_provider_name",
        "discovery_provider_name",
        "auto_group",
        "discovery_group",
        "parent_group"
    )) {
        if ($Settings.PSObject.Properties.Name -notcontains $RequiredName) {
            throw "settings.json 缺少必要字段：$RequiredName。请先运行 setup.ps1，再完成本地配置。"
        }
    }

    foreach ($UriField in @("controller", "mixed_proxy")) {
        $ParsedUri = $null
        try {
            $ParsedUri = [Uri][string]$Settings.$UriField
        } catch {
            throw "settings.json 中的 $UriField 不是有效的本地 HTTP(S) URL。"
        }
        if (-not $ParsedUri.IsAbsoluteUri -or
            $ParsedUri.Scheme -notin @("http", "https") -or
            -not $ParsedUri.IsLoopback) {
            throw "settings.json 中的 $UriField 必须使用本机回环地址和 HTTP(S) 协议。"
        }
    }

    $TemplateType = ([string]$Template.type).ToLowerInvariant()
    $TemplatePort = 0
    if ([string]::IsNullOrWhiteSpace($TemplateType) -or
        -not [int]::TryParse([string]$Template.port, [ref]$TemplatePort) -or
        $TemplatePort -lt 1 -or $TemplatePort -gt 65535) {
        throw "node_template.json 必须包含有效的节点 type 和 port。"
    }
    if ($TemplateType -in @("vmess", "vless") -and
        ($Template.PSObject.Properties.Name -notcontains "uuid" -or
        [string]::IsNullOrWhiteSpace([string]$Template.uuid))) {
        throw "node_template.json 中的 $TemplateType 节点缺少 UUID。"
    }
    if ($TemplateType -eq "trojan" -and
        ($Template.PSObject.Properties.Name -notcontains "password" -or
        [string]::IsNullOrWhiteSpace([string]$Template.password))) {
        throw "node_template.json 中的 trojan 节点缺少 password。"
    }
    if ($TemplateType -in @("hysteria", "hysteria2", "tuic", "wireguard")) {
        throw (
            "当前发现器使用 TCP 初筛，不支持 UDP/QUIC 专用协议 $TemplateType。" +
            "请选择可通过 TCP 建立真实链路的 Mihomo 节点模板。"
        )
    }
    if ($TemplatePort -notin @(443, 2053, 2083, 2087, 2096, 8443)) {
        Write-Warning (
            "节点端口 $TemplatePort 不在 Cloudflare 普通代理的标准 HTTPS 端口列表中；" +
            "请确认你使用了适配该端口的 Cloudflare 产品和服务端配置。"
        )
    }

    if ($env:CCFD_ALLOW_EXAMPLE_CONFIG_FOR_TESTS -eq "1") {
        return [PSCustomObject]@{
            Settings = $Settings
            Template = $Template
        }
    }

    $PlaceholderCategories = @()
    if ($Template.PSObject.Properties.Name -contains "uuid" -and
        [string]$Template.uuid -eq "00000000-0000-0000-0000-000000000000") {
        $PlaceholderCategories += "示例 UUID"
    }
    if ($Template.PSObject.Properties.Name -contains "password" -and
        [string]$Template.password -match '(?i)^(replace-with-your-password|change-me|your-password|<.+>)$') {
        $PlaceholderCategories += "示例密码"
    }
    if ($Template.PSObject.Properties.Name -contains "servername" -and
        [string]$Template.servername -match '(?i)(^|\.)example\.(com|net|org)$') {
        $PlaceholderCategories += "示例 SNI"
    }
    if ($Template.PSObject.Properties.Name -contains "sni" -and
        [string]$Template.sni -match '(?i)(^|\.)example\.(com|net|org)$') {
        $PlaceholderCategories += "示例 SNI"
    }
    if ($Template.PSObject.Properties.Name -contains "ws-opts") {
        $WsOptions = $Template.'ws-opts'
        if ($WsOptions.PSObject.Properties.Name -contains "path" -and
            [string]$WsOptions.path -eq "/your-websocket-path") {
            $PlaceholderCategories += "示例 WebSocket 路径"
        }
        if ($WsOptions.PSObject.Properties.Name -contains "headers") {
            $Headers = $WsOptions.headers
            if ($Headers.PSObject.Properties.Name -contains "Host" -and
                [string]$Headers.Host -match '(?i)(^|\.)example\.(com|net|org)$') {
                $PlaceholderCategories += "示例 Host"
            }
        }
    }

    if ($PlaceholderCategories.Count -gt 0) {
        $Categories = @($PlaceholderCategories | Select-Object -Unique) -join "、"
        throw (
            "检测到未替换的公开示例配置（$Categories）。" +
            "请先运行 setup.ps1，再编辑 node_template.json；安装尚未写入任何文件。"
        )
    }

    return [PSCustomObject]@{
        Settings = $Settings
        Template = $Template
    }
}

function Write-TextUtf8NoBomAtomic([string]$Path, [string]$Value) {
    $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $TempPath = "$Path.$PID.tmp"
    $ReplaceBackupPath = "$Path.$PID.replace.bak"
    try {
        [IO.File]::WriteAllText($TempPath, $Value, $Utf8NoBom)
        if (Test-Path -LiteralPath $Path) {
            [IO.File]::Replace($TempPath, $Path, $ReplaceBackupPath)
        } else {
            [IO.File]::Move($TempPath, $Path)
        }
    } finally {
        foreach ($CleanupPath in @($TempPath, $ReplaceBackupPath)) {
            if (Test-Path -LiteralPath $CleanupPath) {
                Remove-Item -LiteralPath $CleanupPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Write-JsonUtf8NoBom([string]$Path, $Value) {
    $Json = $Value | ConvertTo-Json -Depth 30
    Write-TextUtf8NoBomAtomic $Path $Json
}

function Set-OrAddProperty($Object, [string]$Name, $Value) {
    if ($Object.PSObject.Properties.Name -contains $Name) {
        $Object.$Name = $Value
    } else {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Set-ShortcutAppUserModelId(
    [string]$ShortcutPath,
    [string]$AppUserModelId
) {
    if (-not ("ClashCloudflareDynamic.ToastShortcutRegistration" -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace ClashCloudflareDynamic
{
    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    internal struct PropertyKey
    {
        internal Guid FormatId;
        internal uint PropertyId;

        internal PropertyKey(Guid formatId, uint propertyId)
        {
            FormatId = formatId;
            PropertyId = propertyId;
        }
    }

    [StructLayout(LayoutKind.Explicit, Size = 16)]
    internal struct PropVariant
    {
        [FieldOffset(0)] internal ushort VariantType;
        [FieldOffset(8)] internal IntPtr PointerValue;
    }

    [ComImport]
    [Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IPropertyStore
    {
        [PreserveSig] int GetCount(out uint propertyCount);
        [PreserveSig] int GetAt(uint propertyIndex, out PropertyKey key);
        [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
        [PreserveSig] int SetValue(ref PropertyKey key, ref PropVariant value);
        [PreserveSig] int Commit();
    }

    internal enum GetPropertyStoreFlags : uint
    {
        ReadWrite = 0x00000002
    }

    public static class ToastShortcutRegistration
    {
        private const ushort VtLpwstr = 31;
        private static readonly PropertyKey AppUserModelIdKey = new PropertyKey(
            new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"),
            5
        );

        [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
        private static extern void SHGetPropertyStoreFromParsingName(
            [MarshalAs(UnmanagedType.LPWStr)] string path,
            IntPtr bindContext,
            GetPropertyStoreFlags flags,
            ref Guid interfaceId,
            [MarshalAs(UnmanagedType.Interface)] out IPropertyStore propertyStore
        );

        [DllImport("ole32.dll")]
        private static extern int PropVariantClear(ref PropVariant value);

        private static IPropertyStore OpenStore(string shortcutPath)
        {
            Guid interfaceId = typeof(IPropertyStore).GUID;
            IPropertyStore store;
            SHGetPropertyStoreFromParsingName(
                shortcutPath,
                IntPtr.Zero,
                GetPropertyStoreFlags.ReadWrite,
                ref interfaceId,
                out store
            );
            return store;
        }

        public static void SetAppUserModelId(string shortcutPath, string appUserModelId)
        {
            IPropertyStore store = OpenStore(shortcutPath);
            PropVariant value = new PropVariant
            {
                VariantType = VtLpwstr,
                PointerValue = Marshal.StringToCoTaskMemUni(appUserModelId)
            };
            try
            {
                PropertyKey key = AppUserModelIdKey;
                Marshal.ThrowExceptionForHR(store.SetValue(ref key, ref value));
                Marshal.ThrowExceptionForHR(store.Commit());
            }
            finally
            {
                PropVariantClear(ref value);
                Marshal.FinalReleaseComObject(store);
            }
        }

        public static string GetAppUserModelId(string shortcutPath)
        {
            IPropertyStore store = OpenStore(shortcutPath);
            PropVariant value = new PropVariant();
            try
            {
                PropertyKey key = AppUserModelIdKey;
                Marshal.ThrowExceptionForHR(store.GetValue(ref key, out value));
                if (value.VariantType != VtLpwstr || value.PointerValue == IntPtr.Zero)
                {
                    return null;
                }
                return Marshal.PtrToStringUni(value.PointerValue);
            }
            finally
            {
                PropVariantClear(ref value);
                Marshal.FinalReleaseComObject(store);
            }
        }
    }
}
'@
    }

    [ClashCloudflareDynamic.ToastShortcutRegistration]::SetAppUserModelId(
        $ShortcutPath,
        $AppUserModelId
    )
    $RegisteredId = [ClashCloudflareDynamic.ToastShortcutRegistration]::GetAppUserModelId(
        $ShortcutPath
    )
    if ($RegisteredId -ne $AppUserModelId) {
        throw "开始菜单快捷方式 AppUserModelID 注册失败：$ShortcutPath"
    }
}

function Install-ToastShortcut(
    [string]$ShortcutPath,
    [string]$AppUserModelId,
    [string]$InstallDirectory
) {
    $ShortcutDirectory = Split-Path -Parent $ShortcutPath
    New-Item -ItemType Directory -Path $ShortcutDirectory -Force | Out-Null

    $WshShell = $null
    $Shortcut = $null
    try {
        $WshShell = New-Object -ComObject WScript.Shell
        $Shortcut = $WshShell.CreateShortcut($ShortcutPath)
        $Shortcut.TargetPath = Join-Path $env:WINDIR "explorer.exe"
        $Shortcut.Arguments = "`"$InstallDirectory`""
        $Shortcut.WorkingDirectory = $InstallDirectory
        $Shortcut.Description = "Clash Cloudflare Dynamic"
        $Shortcut.IconLocation = (Join-Path $env:SystemRoot "System32\shell32.dll") + ",14"
        $Shortcut.Save()
    } finally {
        if ($null -ne $Shortcut) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($Shortcut)
        }
        if ($null -ne $WshShell) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($WshShell)
        }
    }

    Set-ShortcutAppUserModelId $ShortcutPath $AppUserModelId
}

function New-InitialProvider(
    [string]$Path,
    [string]$Prefix,
    [string]$TemplatePath,
    [string]$SeedPath
) {
    $NodeTemplate = Read-JsonObject $TemplatePath
    $Nodes = @()
    foreach ($Line in Get-Content -LiteralPath $SeedPath -Encoding UTF8) {
        $Ip = $Line.Trim()
        if (-not $Ip -or $Ip.StartsWith("#")) {
            continue
        }
        $ParsedIp = $null
        if (-not [Net.IPAddress]::TryParse($Ip, [ref]$ParsedIp) -or
            $ParsedIp.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
            continue
        }
        $Node = ($NodeTemplate | ConvertTo-Json -Depth 30) | ConvertFrom-Json
        Set-OrAddProperty $Node "name" "$Prefix | $Ip"
        Set-OrAddProperty $Node "server" $Ip
        $Nodes += $Node
    }
    if ($Nodes.Count -eq 0) {
        throw "seed_ips.txt 中没有有效 IPv4 地址。"
    }
    Write-JsonUtf8NoBom $Path ([PSCustomObject]@{ proxies = $Nodes })
}

$Source = Split-Path -Parent $MyInvocation.MyCommand.Path
$SourceSettingsPath = Join-Path $Source "settings.json"
$SourceNodeTemplatePath = Join-Path $Source "node_template.json"
$SourceConfiguration = Assert-PublicConfigurationReady `
    -SettingsPath $SourceSettingsPath `
    -TemplatePath $SourceNodeTemplatePath
$SourceSettings = $SourceConfiguration.Settings
$InstallDir = Join-Path $env:LOCALAPPDATA "ClashCloudflareDynamic"
$VergeHome = Join-Path $env:APPDATA "io.github.clash-verge-rev.clash-verge-rev"
$ProviderDir = Join-Path $VergeHome "providers\ClashCloudflareDynamic"
$ToastAppUserModelId = "ClashCloudflareDynamic"
$StartMenuProgramsDir = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs"
$ToastShortcutPath = Join-Path $StartMenuProgramsDir "Clash Cloudflare Dynamic.lnk"

$OldTask = "Clash Cloudflare Dynamic Discovery 30min"
$LightTask = "Clash Cloudflare Light Scan 30min"
$DeepTask = "Clash Cloudflare Deep Scan 5000 6h"
$HealthTask = "Clash Cloudflare Health Monitor 30min"
$AggressiveTask = "Clash Cloudflare Deep Scan 5000 30min"
$RuntimeFileNames = @(
    "config.template.yaml",
    "deep_scan_5000.bat",
    "diagnose.bat",
    "dynamic_selector.py",
    "health_monitor.ps1",
    "health_monitor_launcher.py",
    "install_aggressive_5000_30min.ps1",
    "install_hybrid_5000.ps1",
    "light_scan_200.bat",
    "notify_windows.ps1",
    "quick_test.bat",
    "run_now.bat",
    "seed_ips.txt",
    "storage_maintenance.py",
    "uninstall.ps1"
)
$RuntimeFileNames | ForEach-Object {
    $RuntimeSourcePath = Join-Path $Source $_
    if (-not (Test-Path -LiteralPath $RuntimeSourcePath -PathType Leaf)) {
        throw "安装源缺少运行时文件：$RuntimeSourcePath"
    }
}
$SourceHealthScript = Join-Path $Source "health_monitor.ps1"
if (-not (Test-Path -LiteralPath $SourceHealthScript -PathType Leaf)) {
    throw "安装源缺少健康监控脚本：$SourceHealthScript"
}
$SourceHealthLauncher = Join-Path $Source "health_monitor_launcher.py"
if (-not (Test-Path -LiteralPath $SourceHealthLauncher -PathType Leaf)) {
    throw "安装源缺少健康监控隐藏启动器：$SourceHealthLauncher"
}

# Validate the task interpreter before creating directories, backups, or
# replacing files. A failed preflight must leave an existing install intact.
$PythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue
$Python = if ($PythonCommand) { $PythonCommand.Source } else { $null }
if (-not $Python) {
    $PyLauncherCommand = Get-Command py.exe -ErrorAction SilentlyContinue
    if ($PyLauncherCommand) {
        $ResolvedPythonLines = @(
            & $PyLauncherCommand.Source -3 -c "import sys; print(sys.executable)" 2>$null
        )
        if ($LASTEXITCODE -eq 0) {
            $Python = [string]($ResolvedPythonLines |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Select-Object -Last 1)
        }
    }
}
if (-not $Python -or -not (Test-Path -LiteralPath $Python -PathType Leaf)) {
    throw "未找到可供计划任务使用的 Python 3.10+ 解释器。请安装 Python，并勾选 Add Python to PATH。"
}
$VersionProbeLines = @(
    & $Python -c "import sys; print('.'.join(map(str, sys.version_info[:3])))" 2>$null
)
$VersionProbeExitCode = $LASTEXITCODE
$VersionText = [string]($VersionProbeLines |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Select-Object -Last 1)
$PythonVersion = $null
if ($VersionProbeExitCode -ne 0 -or
    -not [Version]::TryParse($VersionText, [ref]$PythonVersion) -or
    $PythonVersion -lt [Version]"3.10") {
    throw "计划任务 Python 解释器不可用或版本低于 3.10：$Python ($VersionText)"
}
$Pythonw = Join-Path (Split-Path -Parent $Python) "pythonw.exe"
if (-not (Test-Path -LiteralPath $Pythonw -PathType Leaf)) {
    throw "未找到与 python.exe 同目录的 pythonw.exe；为保证计划任务不弹出命令框，未修改现有任务。"
}
$TaskPython = $Pythonw
$BaseArgs = "`"$(Join-Path $InstallDir 'dynamic_selector.py')`""
Write-Host "安装目录：$InstallDir"
$ExistingInstall = Test-Path -LiteralPath $InstallDir
$ExistingToastShortcut = Test-Path -LiteralPath $ToastShortcutPath
$ManagedTaskBackupNames = [ordered]@{
    $LightTask = "light-task.xml"
    $DeepTask = "deep-task.xml"
    $HealthTask = "health-task.xml"
    $OldTask = "old-task.xml"
    $AggressiveTask = "aggressive-task.xml"
}
$ExistingScheduledTasks = @(Get-ScheduledTask -ErrorAction Stop)
$ExistingTaskNames = @(
    $ExistingScheduledTasks |
        ForEach-Object { [string]$_.TaskName } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)
$ExistingManagedTaskNames = @(
    $ManagedTaskBackupNames.Keys |
        Where-Object { $ExistingTaskNames -contains $_ }
)

$SettingsPath = Join-Path $InstallDir "settings.json"
$NodeTemplatePath = Join-Path $InstallDir "node_template.json"
$ConfigPath = Join-Path $InstallDir "clash_cloudflare_dynamic_verge_safe.yaml"
$ActiveProviderPath = Join-Path $ProviderDir "cloudflare_active.yaml"
$DiscoveryProviderPath = Join-Path $ProviderDir "cloudflare_discovery.yaml"
$HealthStatePath = Join-Path $InstallDir "logs\health_monitor_state.json"
$ManagedFileEntries = @(
    $RuntimeFileNames | ForEach-Object {
        [PSCustomObject]@{
            Path = Join-Path $InstallDir $_
            BackupName = $_
            Existed = Test-Path -LiteralPath (Join-Path $InstallDir $_) -PathType Leaf
        }
    }
)
$ManagedFileEntries += @(
    [PSCustomObject]@{ Path = $SettingsPath; BackupName = "settings.json"; Existed = Test-Path -LiteralPath $SettingsPath -PathType Leaf },
    [PSCustomObject]@{ Path = $NodeTemplatePath; BackupName = "node_template.json"; Existed = Test-Path -LiteralPath $NodeTemplatePath -PathType Leaf },
    [PSCustomObject]@{ Path = $ConfigPath; BackupName = "clash_cloudflare_dynamic_verge_safe.yaml"; Existed = Test-Path -LiteralPath $ConfigPath -PathType Leaf },
    [PSCustomObject]@{ Path = $ActiveProviderPath; BackupName = "cloudflare_active.yaml"; Existed = Test-Path -LiteralPath $ActiveProviderPath -PathType Leaf },
    [PSCustomObject]@{ Path = $DiscoveryProviderPath; BackupName = "cloudflare_discovery.yaml"; Existed = Test-Path -LiteralPath $DiscoveryProviderPath -PathType Leaf },
    [PSCustomObject]@{ Path = $HealthStatePath; BackupName = "health_monitor_state.json"; Existed = Test-Path -LiteralPath $HealthStatePath -PathType Leaf },
    [PSCustomObject]@{ Path = $ToastShortcutPath; BackupName = "Clash Cloudflare Dynamic.lnk"; Existed = Test-Path -LiteralPath $ToastShortcutPath -PathType Leaf }
)
$BackupDir = $null

if ($ExistingInstall -or $ExistingToastShortcut -or $ExistingManagedTaskNames.Count -gt 0) {
    $Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $BackupRoot = Join-Path $InstallDir "backups"
    $BackupBaseName = "install-$Stamp"
    $BackupDir = Join-Path $BackupRoot $BackupBaseName
    $BackupSuffix = 1
    while (Test-Path -LiteralPath $BackupDir) {
        $BackupDir = Join-Path $BackupRoot "$BackupBaseName-$BackupSuffix"
        $BackupSuffix += 1
    }
    New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
    try {
        foreach ($Entry in $ManagedFileEntries) {
            if ($Entry.Existed) {
                Copy-Item `
                    -LiteralPath $Entry.Path `
                    -Destination (Join-Path $BackupDir $Entry.BackupName) `
                    -Force
            }
        }
        $ManagedTaskBackupNames.GetEnumerator() | ForEach-Object {
            if ($ExistingManagedTaskNames -contains $_.Key) {
                $TaskXml = Export-ScheduledTask -TaskName $_.Key -ErrorAction Stop
                if ([string]::IsNullOrWhiteSpace([string]$TaskXml)) {
                    throw "计划任务备份为空：$($_.Key)"
                }
                Set-Content -LiteralPath (Join-Path $BackupDir $_.Value) -Value $TaskXml -Encoding Unicode
            }
        }
    } catch {
        Remove-Item -LiteralPath $BackupDir -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
    Write-Host "现有关键文件已备份到：$BackupDir" -ForegroundColor Yellow
}

# 从第一次安装写入到任务迁移完成都属于同一事务。任务层先恢复原调度，
# 外层再恢复安装前的每个受管文件；从未存在的文件只删除本轮创建项。
try {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    foreach ($RuntimeFileName in $RuntimeFileNames) {
        $RuntimeSourcePath = Join-Path $Source $RuntimeFileName
        $RuntimeDestinationPath = Join-Path $InstallDir $RuntimeFileName
        if (-not [IO.Path]::GetFullPath($RuntimeSourcePath).Equals(
            [IO.Path]::GetFullPath($RuntimeDestinationPath),
            [StringComparison]::OrdinalIgnoreCase
        )) {
            Copy-Item `
                -LiteralPath $RuntimeSourcePath `
                -Destination $RuntimeDestinationPath `
                -Force
        }
    }
    New-Item -ItemType Directory -Path (Join-Path $InstallDir "logs") -Force | Out-Null
    New-Item -ItemType Directory -Path $ProviderDir -Force | Out-Null

    if (-not (Test-Path -LiteralPath $HealthStatePath)) {
        $InitialHealthState = [PSCustomObject]@{
            schema_version = 1
            installed_at = [DateTimeOffset]::Now.ToString("o")
            last_success = [PSCustomObject]@{
                light = $null
                deep = $null
            }
            active_issue_keys = @()
            active_mode = $null
            mode_changed_at = [DateTimeOffset]::Now.ToString("o")
            last_check = $null
        }
        Write-JsonUtf8NoBom $HealthStatePath $InitialHealthState
    }

    $DefaultSettings = $SourceSettings
    if (Test-Path -LiteralPath $SettingsPath) {
        $Settings = Read-JsonObject $SettingsPath
        foreach ($Property in $DefaultSettings.PSObject.Properties) {
            if ($Settings.PSObject.Properties.Name -notcontains $Property.Name) {
                $Settings | Add-Member `
                    -NotePropertyName $Property.Name `
                    -NotePropertyValue $Property.Value
            }
        }
    } else {
        $Settings = $DefaultSettings
    }
    Write-JsonUtf8NoBom $SettingsPath $Settings

    if (-not (Test-Path -LiteralPath $NodeTemplatePath)) {
        Copy-Item -LiteralPath $SourceNodeTemplatePath -Destination $NodeTemplatePath
    }
    if (-not (Test-Path -LiteralPath $ActiveProviderPath)) {
        New-InitialProvider `
            $ActiveProviderPath `
            "CF-A" `
            $NodeTemplatePath `
            (Join-Path $Source "seed_ips.txt")
    }
    if (-not (Test-Path -LiteralPath $DiscoveryProviderPath)) {
        New-InitialProvider `
            $DiscoveryProviderPath `
            "CF-D" `
            $NodeTemplatePath `
            (Join-Path $Source "seed_ips.txt")
    }

    $TemplatePath = Join-Path $InstallDir "config.template.yaml"
    $ActivePath = "./providers/ClashCloudflareDynamic/cloudflare_active.yaml"
    $DiscoveryPath = "./providers/ClashCloudflareDynamic/cloudflare_discovery.yaml"

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        $ControllerUri = [Uri][string]$Settings.controller
        $MixedProxyUri = [Uri][string]$Settings.mixed_proxy
        if (-not $ControllerUri.IsAbsoluteUri -or -not $MixedProxyUri.IsAbsoluteUri) {
            throw "settings.json 中的 controller 或 mixed_proxy 不是有效 URL。"
        }
        $ControllerEndpoint = $ControllerUri.Authority
        $MixedPort = $MixedProxyUri.Port
        $YamlSecret = "'" + ([string]$Settings.secret).Replace("'", "''") + "'"

        $Text = Get-Content $TemplatePath -Raw -Encoding UTF8
        $Text = $Text.Replace("__ACTIVE_PROVIDER_PATH__", $ActivePath)
        $Text = $Text.Replace("__DISCOVERY_PROVIDER_PATH__", $DiscoveryPath)
        $Text = [regex]::Replace(
            $Text,
            '(?m)^mixed-port:\s*.*$',
            "mixed-port: $MixedPort"
        )
        $Text = [regex]::Replace(
            $Text,
            '(?m)^external-controller:\s*.*$',
            "external-controller: $ControllerEndpoint"
        )
        $SecretEvaluator = [System.Text.RegularExpressions.MatchEvaluator]{
            param($Match)
            return "secret: $YamlSecret"
        }
        $Text = [regex]::Replace($Text, '(?m)^secret:\s*.*$', $SecretEvaluator)
        Write-TextUtf8NoBomAtomic $ConfigPath $Text
    }
    Write-Host "计划任务解释器：$TaskPython（Python $PythonVersion，隐藏窗口）"

    Install-ToastShortcut $ToastShortcutPath $ToastAppUserModelId $InstallDir
    Write-Host "Toast 应用标识：$ToastAppUserModelId"
    Write-Host "开始菜单快捷方式：$ToastShortcutPath"

    $LightAction = New-ScheduledTaskAction `
        -Execute $TaskPython `
        -Argument "$BaseArgs --quick" `
        -WorkingDirectory $InstallDir
    $LightTrigger = New-ScheduledTaskTrigger `
        -Once `
        -At ((Get-Date).AddMinutes(3)) `
        -RepetitionInterval (New-TimeSpan -Minutes 30) `
        -RepetitionDuration (New-TimeSpan -Days 3650)
    $LightSettings = New-CompatibleTaskSettings -ExecutionTimeLimit (New-TimeSpan -Minutes 20)

    $DeepAction = New-ScheduledTaskAction `
        -Execute $TaskPython `
        -Argument $BaseArgs `
        -WorkingDirectory $InstallDir
    $DeepTrigger = New-ScheduledTaskTrigger `
        -Once `
        -At ((Get-Date).AddMinutes(15)) `
        -RepetitionInterval (New-TimeSpan -Hours 6) `
        -RepetitionDuration (New-TimeSpan -Days 3650)
    $DeepSettings = New-CompatibleTaskSettings -ExecutionTimeLimit (New-TimeSpan -Minutes 150)

    $HealthScript = Join-Path $InstallDir "health_monitor.ps1"
    if (-not (Test-Path -LiteralPath $HealthScript -PathType Leaf)) {
        throw "健康监控脚本不存在：$HealthScript"
    }
    $HealthLauncher = Join-Path $InstallDir "health_monitor_launcher.py"
    if (-not (Test-Path -LiteralPath $HealthLauncher -PathType Leaf)) {
        throw "健康监控隐藏启动器不存在：$HealthLauncher"
    }
    $HealthAction = New-ScheduledTaskAction `
        -Execute $TaskPython `
        -Argument "`"$HealthLauncher`"" `
        -WorkingDirectory $InstallDir
    $HealthTrigger = New-ScheduledTaskTrigger `
        -Once `
        -At ((Get-Date).AddMinutes(10)) `
        -RepetitionInterval (New-TimeSpan -Minutes 30) `
        -RepetitionDuration (New-TimeSpan -Days 3650)
    $HealthSettings = New-CompatibleTaskSettings -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

    try {
        Register-ScheduledTask `
            -TaskName $LightTask `
            -Action $LightAction `
            -Trigger $LightTrigger `
            -Settings $LightSettings `
            -Description "每 30 分钟轻量抽样最多 200 个 Cloudflare IP，复测正式池并自动选择。" `
            -Force `
            -ErrorAction Stop | Out-Null

        Register-ScheduledTask `
            -TaskName $DeepTask `
            -Action $DeepAction `
            -Trigger $DeepTrigger `
            -Settings $DeepSettings `
            -Description "每 6 小时从 Cloudflare 官方 IPv4 网段深度随机抽样 5000 个地址并更新优选池。" `
            -Force `
            -ErrorAction Stop | Out-Null

        Register-ScheduledTask `
            -TaskName $HealthTask `
            -Action $HealthAction `
            -Trigger $HealthTrigger `
            -Settings $HealthSettings `
            -Description "每 30 分钟独立检查扫描任务、解释器、脚本路径和最近成功时间；异常和恢复时静音通知。" `
            -Force `
            -ErrorAction Stop | Out-Null

        foreach ($TaskName in @($OldTask, $AggressiveTask)) {
            if ($ExistingTaskNames -notcontains $TaskName) {
                continue
            }
            $TaskToRemove = @(
                $ExistingScheduledTasks | Where-Object { $_.TaskName -eq $TaskName }
            )[0]
            if ([string]$TaskToRemove.State -eq "Running") {
                Stop-ScheduledTask -TaskName $TaskName -ErrorAction Stop
            }
            Unregister-ScheduledTask `
                -TaskName $TaskName `
                -Confirm:$false `
                -ErrorAction Stop
        }
        $RemainingTaskNames = @(
            Get-ScheduledTask -ErrorAction Stop |
                ForEach-Object { [string]$_.TaskName }
        )
        foreach ($TaskName in @($OldTask, $AggressiveTask)) {
            if ($RemainingTaskNames -contains $TaskName) {
                throw "旧模式计划任务删除后仍然存在：$TaskName"
            }
        }
    } catch {
        $RegistrationError = $_.Exception.Message
        $RollbackErrors = New-Object System.Collections.Generic.List[string]
        foreach ($TaskName in $ManagedTaskBackupNames.Keys) {
            try {
                if ($ExistingManagedTaskNames -contains $TaskName) {
                    $TaskBackupPath = Join-Path $BackupDir $ManagedTaskBackupNames[$TaskName]
                    if (-not (Test-Path -LiteralPath $TaskBackupPath -PathType Leaf)) {
                        throw "缺少原任务备份：$TaskBackupPath"
                    }
                    $TaskXml = Get-Content -LiteralPath $TaskBackupPath -Raw -Encoding Unicode
                    Register-ScheduledTask `
                        -TaskName $TaskName `
                        -Xml $TaskXml `
                        -Force `
                        -ErrorAction Stop | Out-Null
                } else {
                    $CurrentTaskNames = @(
                        Get-ScheduledTask -ErrorAction Stop |
                            ForEach-Object { [string]$_.TaskName }
                    )
                    if ($CurrentTaskNames -contains $TaskName) {
                        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
                        Unregister-ScheduledTask `
                            -TaskName $TaskName `
                            -Confirm:$false `
                            -ErrorAction Stop
                    }
                }
            } catch {
                [void]$RollbackErrors.Add("$TaskName：$($_.Exception.Message)")
            }
        }
        try {
            $RestoredTaskNames = @(
                Get-ScheduledTask -ErrorAction Stop |
                    ForEach-Object { [string]$_.TaskName }
            )
            foreach ($TaskName in $ManagedTaskBackupNames.Keys) {
                $ShouldExist = $ExistingManagedTaskNames -contains $TaskName
                $DoesExist = $RestoredTaskNames -contains $TaskName
                if ($ShouldExist -ne $DoesExist) {
                    [void]$RollbackErrors.Add("$TaskName：回滚后存在状态不一致")
                }
            }
        } catch {
            [void]$RollbackErrors.Add("回滚核验失败：$($_.Exception.Message)")
        }
        if ($RollbackErrors.Count -gt 0) {
            throw "计划任务注册失败：$RegistrationError；回滚未完全成功：$($RollbackErrors -join '；')"
        }
        throw "计划任务注册失败，已恢复原调度：$RegistrationError"
    }
} catch {
    $InstallError = $_.Exception.Message
    $FileRollbackErrors = New-Object System.Collections.Generic.List[string]
    foreach ($Entry in $ManagedFileEntries) {
        try {
            if ($Entry.Existed) {
                if ([string]::IsNullOrWhiteSpace([string]$BackupDir)) {
                    throw "缺少备份目录"
                }
                $BackupPath = Join-Path $BackupDir $Entry.BackupName
                if (-not (Test-Path -LiteralPath $BackupPath -PathType Leaf)) {
                    throw "缺少原文件备份：$BackupPath"
                }
                $ParentPath = Split-Path -Parent $Entry.Path
                New-Item -ItemType Directory -Path $ParentPath -Force | Out-Null
                Copy-Item -LiteralPath $BackupPath -Destination $Entry.Path -Force
            } elseif (Test-Path -LiteralPath $Entry.Path) {
                Remove-Item -LiteralPath $Entry.Path -Force -ErrorAction Stop
            }
        } catch {
            [void]$FileRollbackErrors.Add("$($Entry.Path)：$($_.Exception.Message)")
        }
    }
    foreach ($DirectoryPath in @(
        (Join-Path $InstallDir "logs"),
        $ProviderDir,
        $InstallDir
    )) {
        try {
            if ((Test-Path -LiteralPath $DirectoryPath -PathType Container) -and
                @(Get-ChildItem -LiteralPath $DirectoryPath -Force).Count -eq 0) {
                Remove-Item -LiteralPath $DirectoryPath -Force -ErrorAction Stop
            }
        } catch {
            [void]$FileRollbackErrors.Add("$DirectoryPath：$($_.Exception.Message)")
        }
    }
    if ($FileRollbackErrors.Count -gt 0) {
        throw "$InstallError；文件回滚未完全成功：$($FileRollbackErrors -join '；')"
    }
    throw "$InstallError；已恢复安装前文件状态"
}

Write-Host ""
Write-Host "混合模式安装完成。" -ForegroundColor Green
Write-Host "轻量任务：每 30 分钟抽样最多 200 个新 IP"
Write-Host "深度任务：每 6 小时抽样 5000 个新 IP"
Write-Host "健康监控：每 30 分钟检查一次，异常和恢复时通知"
Write-Host ""
Write-Host "请导入并启用："
Write-Host $ConfigPath -ForegroundColor Cyan
Write-Host "然后选择：节点选择 -> 自动选择"
Write-Host ""
if (-not $NoOpenExplorer) {
    Start-Process explorer.exe -ArgumentList "/select,`"$ConfigPath`""
}
