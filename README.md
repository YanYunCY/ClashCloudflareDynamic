# Clash Cloudflare Dynamic

Windows 上的 Cloudflare Anycast 地址动态发现与 Mihomo/Clash Verge Rev 自动优选工具。

它从 Cloudflare 官方 IPv4 网段抽样候选，先按用户选择的节点端口做 TCP 初筛，再通过用户自己的 Mihomo 节点模板验证真实协议、TLS 和传输链路，执行多轮延迟与下载测速，并在防抖条件满足后更新 provider 和切换节点。

> 本项目不提供代理服务、节点账号或认证信息。请仅使用你拥有或获授权使用的节点、域名和凭据。

## 源码与部署包

这个 Git 仓库保存的是开发源码，不是 `%LOCALAPPDATA%` 中的运行目录。源码、测试、Windows 脚本和公开配置分别维护：

```text
src/clash_cloudflare_dynamic/  Python 核心源码
scripts/windows/               安装、通知、任务和卸载脚本
tests/python/                  Python 单元与回归测试
tests/windows/                 Windows PowerShell 隔离测试
config/                        无凭据的运行资源
examples/                      无凭据的配置示例
tools/build_release.py         部署包构建器
tools/privacy_check.py         发布前隐私检查
```

`python tools/build_release.py` 会根据显式白名单生成 `dist/ClashCloudflareDynamic.zip`。压缩包采用便于 Windows 计划任务运行的平铺结构；`dist/` 不进入 Git。安装后的文件结构与源码仓库结构因此是两套明确分离的布局。

## 主要功能

- 每 30 分钟轻量扫描，默认最多发现 200 个新地址；
- 每 6 小时深度扫描约 5000 个新地址；
- SQLite 避免短期重复抽样，并自动维护历史；
- 真实代理链路验证，不以裸 IP 的 HTTP 测速代替节点验证；
- VMess、VLESS、Trojan 示例和自定义 Mihomo 节点模板；
- TCP 初筛自动跟随节点模板端口，不再写死为 443；
- 每个最终候选连续测试 3 次，记录原始值、平均值、标准差和 CV；
- 在最高平均速度 95% 的高速组中选择平均延迟最低节点；
- provider 原子更新、`.last-good` 回滚和 Mihomo 状态确认；
- `pythonw.exe` 后台任务，不创建可见命令行窗口；
- 静音高优先级 Windows 通知，点击查看独立 HTML 报告；
- 日志轮转、备份清理、数据库损坏备份与恢复；
- 深扫前台繁忙延后和独立任务健康监控。

## 运行要求

- Windows 10/11；
- Python 3.10 或更高版本，并包含同目录的 `pythonw.exe`；
- Clash Verge Rev；
- Mihomo REST API 可从本机访问；
- `curl.exe`；
- 一个你有权使用的代理节点模板。模板必须包含 Mihomo 节点所需认证、`port` 和传输参数，程序只替换 `name` 与 `server`，其余字段原样保留。Mihomo 的 `type`、`server` 和 `port` 是代理节点通用字段，具体协议字段以 [Mihomo 官方文档](https://wiki.metacubex.one/en/config/proxies/) 为准。

默认地址：

- Mihomo API：`http://127.0.0.1:9090`
- mixed proxy：`http://127.0.0.1:7890`
- 安装目录：`%LOCALAPPDATA%\ClashCloudflareDynamic`
- provider：`%APPDATA%\io.github.clash-verge-rev.clash-verge-rev\providers\ClashCloudflareDynamic`

provider 目录位于 Clash Verge Rev 的 SAFE_PATHS 内，不应改回 `%LOCALAPPDATA%`。

## 快速开始

普通用户建议从 GitHub Release 下载 Windows 部署包。开发者从源码安装时，以下命令均在仓库根目录运行；部署包用户则去掉路径中的 `scripts\windows\`。

1. 选择协议和端口并创建本地配置。例如：

   ```powershell
   # VMess + WebSocket + TLS，端口 443
   powershell -ExecutionPolicy Bypass -File .\scripts\windows\setup.ps1 -Protocol vmess -Port 443

   # VLESS + WebSocket + TLS，端口 8443
   powershell -ExecutionPolicy Bypass -File .\scripts\windows\setup.ps1 -Protocol vless -Port 8443

   # Trojan + WebSocket，端口 2053
   powershell -ExecutionPolicy Bypass -File .\scripts\windows\setup.ps1 -Protocol trojan -Port 2053

   # 其他 Mihomo 节点类型：复制自定义模板，可选覆盖其端口
   powershell -ExecutionPolicy Bypass -File .\scripts\windows\setup.ps1 -NodeTemplatePath .\node_template.local.json -Port 2096
   ```

   省略 `-Port` 时使用模板中的端口。一次安装选择一个入口端口；TCP 初筛和最终节点都会使用同一个端口。已有配置只想换端口时，可直接运行 `setup.ps1 -Port 8443`：它会先备份节点模板，只修改端口，不覆盖协议、认证或 `settings.json`。要替换整个协议模板但保留 Mihomo API 设置，使用 `-ReplaceNodeTemplate -Protocol vless`；旧节点模板同样会先备份。`*.local.json` 已被 Git 忽略，但自定义模板仍可能包含真实凭据，发布前必须运行隐私检查。

2. 编辑 `settings.json`：

   - `controller`：Mihomo REST API；
   - `secret`：REST API 密钥，没有则留空；
   - `mixed_proxy`：本地 mixed HTTP 代理地址。

3. 编辑 `node_template.json`，替换示例 UUID/密码、SNI、Host 和传输路径，并再次核对 `type` 与 `port`。

   Cloudflare 普通代理当前支持的 HTTPS 入口端口为 `443`、`2053`、`2083`、`2087`、`2096`、`8443`。端口是否真的适用于你的节点，还取决于域名、源站和服务端配置；不能因为某个 Cloudflare IP 的端口可建立 TCP 连接，就认定真实代理协议可用。项目仍会用完整节点链路淘汰假阳性。详见 [Cloudflare 官方端口说明](https://developers.cloudflare.com/fundamentals/reference/network-ports/)。

   协议也不是任意替换后都能经过普通 CDN。VMess/VLESS/Trojan 的 WS、HTTP、gRPC 等部署可以按实际服务端模板配置；纯 TCP、QUIC/UDP 或其他非 HTTP(S) 传输通常需要不同的 Cloudflare 产品或根本不适用。自定义模板必须满足“只替换 `server` 为 Cloudflare IP 后仍能凭 SNI/Host 等字段到达同一服务”的条件。

4. 安装推荐的混合任务：

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\scripts\windows\install_hybrid_5000.ps1
   ```

   安装器会在创建目录、备份或任务之前检查本地配置；仍含零 UUID、示例密码、`example.com` 或示例 WebSocket 路径时会直接拒绝安装。

5. 在 Clash Verge Rev 导入：

   ```text
   %LOCALAPPDATA%\ClashCloudflareDynamic\clash_cloudflare_dynamic_verge_safe.yaml
   ```

   然后选择 `节点选择 → 自动选择`。

6. 诊断与手动轻扫：

   ```powershell
   python "$env:LOCALAPPDATA\ClashCloudflareDynamic\dynamic_selector.py" --diagnose
   python "$env:LOCALAPPDATA\ClashCloudflareDynamic\dynamic_selector.py" --quick
   ```

## 配置安全

`settings.json`、`node_template.json`、生成的 Clash YAML、provider、日志、数据库和通知报告均已列入 `.gitignore`。不要使用 `git add -f` 强制提交它们。

隐私检查器也会检查被 Git 忽略但仍留在工作目录中的本地配置，并且只报告文件名和风险类别，不打印匹配到的凭据。制作 Release 压缩包时应从已审核的 Git 提交生成归档，不要直接压缩正在运行或测试过的工作目录。

提交或发布前运行：

```powershell
python .\tools\privacy_check.py
git status --ignored --short
```

## 选优规则

1. 候选必须通过节点模板所选端口的 TCP 初筛；
2. provider 热更新后通过真实代理链路做 3 轮延迟测试；
3. 低延迟、历史高速和随机探索候选进入速度粗测；
4. 正式候选连续下载测速 3 次；
5. 任意一次失败、下载量不足或速度 CV 超过阈值时淘汰；
6. 达到本轮最高平均速度 `fast_speed_ratio` 的节点进入高速组；
7. 高速组内按三轮平均延迟选择节点；
8. 正常切换受冷却时间控制，失效节点可以立即替换。

## 后台任务

- `Clash Cloudflare Light Scan 30min`
- `Clash Cloudflare Deep Scan 5000 6h`
- `Clash Cloudflare Health Monitor 30min`

扫描和健康监控均使用 `pythonw.exe`。健康监控启动器通过 `CREATE_NO_WINDOW` 调用 PowerShell，因此不会弹出空命令行窗口。

## 可选的激进模式

如确实需要每 30 分钟执行一次 5000 地址深扫，可在完成普通安装后运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows\install_aggressive_5000_30min.ps1
```

这会显著增加 TCP 连接数和测速流量，通常不建议长期启用。重新运行 `install_hybrid_5000.ps1` 可恢复推荐的混合模式。

## 卸载

源码仓库中运行时，默认只移除计划任务和通知快捷方式，保留程序、日志及 provider：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows\uninstall.ps1
```

先在 Clash Verge Rev 中切换到其他配置后，才应使用 `-RemoveData` 删除安装目录和 provider：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows\uninstall.ps1 -RemoveData
```

## 隐私

程序没有遥测或远程日志上报。网络请求仅用于：

- 获取 Cloudflare 官方 IPv4 网段；
- Mihomo API 与本地代理；
- 配置的延迟测试和下载测速 URL；
- 用户授权节点的真实代理链路。

详细安全说明见 [SECURITY.md](SECURITY.md)。

## 开发与测试

```powershell
python .\tools\privacy_check.py
python .\tools\build_release.py
Get-ChildItem .\src\clash_cloudflare_dynamic\*.py, .\tools\*.py | ForEach-Object { python -m py_compile $_.FullName }
$env:PYTHONPATH = Join-Path $PWD "src"
python -W error::ResourceWarning -m unittest discover -s .\tests\python -p "test_*.py" -v
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\windows\test_setup.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\windows\test_install_hybrid.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\windows\test_uninstall.ps1
```

GitHub Actions 会在 Windows 上执行同一组检查，并把由已审查源码生成的 `ClashCloudflareDynamic.zip` 作为工作流产物上传。

## 免责声明

Cloudflare Anycast 性能会随地区、运营商和时间变化。本软件不保证永久最快地址，也不保证第三方代理服务可用。请遵守当地法律、服务条款和网络使用政策。

## License

[MIT](LICENSE)
