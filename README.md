# Clash Cloudflare Dynamic

[![CI](https://github.com/YanYunCY/ClashCloudflareDynamic/actions/workflows/ci.yml/badge.svg)](https://github.com/YanYunCY/ClashCloudflareDynamic/actions/workflows/ci.yml) [![Release](https://img.shields.io/github/v/release/YanYunCY/ClashCloudflareDynamic)](https://github.com/YanYunCY/ClashCloudflareDynamic/releases/latest) [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://github.com/YanYunCY/ClashCloudflareDynamic/blob/main/LICENSE)

> **TL;DR (English):** A Windows tool that discovers fast Cloudflare Anycast IPs and automatically updates either Mihomo / Clash Verge Rev or v2rayN / Xray. It validates candidates over the user's real proxy protocol with three rounds of response and download tests, runs through Windows Scheduled Tasks, and ships with a backend-selectable installer. Documentation below is written in Chinese.

Windows 上的 Cloudflare Anycast 地址动态发现与 Mihomo/Clash Verge Rev、v2rayN/Xray 自动优选工具。

它从 Cloudflare 官方 IPv4 网段抽样候选，先按用户节点端口做 TCP 初筛，再通过用户自己的节点模板验证真实协议、TLS 和传输链路，执行多轮响应与下载测速，并在防抖条件满足后更新 Mihomo provider 或 v2rayN 原生活动槽。

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

`v1.3.0` 已把 Windows 安装器迁移为 WPF 单页界面：主配置位于左侧，脱敏实时摘要位于右侧，本地 Mihomo 连接设置默认折叠。界面支持“跟随系统 / 浅色 / 深色”，使用系统强调色、轻量设置卡片和响应式布局；窄窗口会收起摘要，表单可独立滚动且底部操作栏保持固定。安装器也针对 Per-Monitor V2 DPI、ClearType 和布局像素对齐做了专门处理。

`v1.5.2` 统一修正 Clash/Mihomo 与 v2rayN/Xray 的测速口径：VMess、VLESS 和 HY2 全部按完整请求墙钟耗时计算排名速度，扣除 TTFB 的短传输峰值只保留为诊断。双击 `Install.cmd` 可选择两种后端；v2rayN 模式只使用安装用户自己填写的节点模板，通过通用 `AUTO-CF` SQLite 活动槽和自身 Reload 热切换，不结束桌面主进程。Release 不包含任何节点凭据、维护者本机路径或私有拓扑。

## 版本与下载

具体版本的 Release 页面只展示该版本；全部历史版本请打开 [Releases 列表](https://github.com/YanYunCY/ClashCloudflareDynamic/releases)。

| 版本 | 状态 | 主要变化 | 下载 |
| --- | --- | --- | --- |
| `v1.5.2` | 最新稳定版 | 修复短样本测速虚高；全协议统一按完整墙钟吞吐排名 | [Release](https://github.com/YanYunCY/ClashCloudflareDynamic/releases/tag/v1.5.2) |
| `v1.5.1` | 历史版本 | 通用 v2rayN/Xray 后端，用户自有模板驱动 | [Release](https://github.com/YanYunCY/ClashCloudflareDynamic/releases/tag/v1.5.1) |
| `v1.5.0` | 历史版本 | 首次加入 v2rayN/Xray 后端；不建议新安装使用 | [Release](https://github.com/YanYunCY/ClashCloudflareDynamic/releases/tag/v1.5.0) |
| `v1.4.0` | 历史稳定版 | 测速口径统一、深扫 20 MB、测速出口恢复、Release 完整门禁 | [Release](https://github.com/YanYunCY/ClashCloudflareDynamic/releases/tag/v1.4.0) |
| `v1.3.7` | 历史稳定版 | 修复 ranges cache 和 JSON 临时文件原子写入 | [Release](https://github.com/YanYunCY/ClashCloudflareDynamic/releases/tag/v1.3.7) |
| `v1.3.6` | 历史稳定版 | 修复切换间隔边界条件（90秒宽限期） | [Release](https://github.com/YanYunCY/ClashCloudflareDynamic/releases/tag/v1.3.6) |
| `v1.3.5` | 历史稳定版 | 深扫连续跳过8h后强制执行 | [Release](https://github.com/YanYunCY/ClashCloudflareDynamic/releases/tag/v1.3.5) |
| `v1.3.4` | 历史稳定版 | 三方同步对账、保留期30天+VACUUM、UTF-8输出、隐私检查反转 | [Release](https://github.com/YanYunCY/ClashCloudflareDynamic/releases/tag/v1.3.4) |
| `v1.3.3` | 历史稳定版 | 粗测容错、API无代理、构建复现、备份清理、自动发布 | [Release](https://github.com/YanYunCY/ClashCloudflareDynamic/releases/tag/v1.3.3) |
| `v1.3.2` | 历史稳定版 | 交错三轮测速、历史稳定性、正式池准入、扫描心跳 | [Release](https://github.com/YanYunCY/ClashCloudflareDynamic/releases/tag/v1.3.2) |
| `v1.3.1` | 历史稳定版 | 通知报告数量上限、通知与健康监控日志轮转 | [Release](https://github.com/YanYunCY/ClashCloudflareDynamic/releases/tag/v1.3.1) |
| `v1.3.0` | 历史稳定版 | WPF 单页安装器、三种外观、实时脱敏摘要与响应式布局 | [Release](https://github.com/YanYunCY/ClashCloudflareDynamic/releases/tag/v1.3.0) |
| `v1.2.0` | 历史稳定版 | 三步现代安装向导、脱敏确认页、小屏与无障碍改进 | [Release](https://github.com/YanYunCY/ClashCloudflareDynamic/releases/tag/v1.2.0) |
| `v1.1.0` | 历史稳定版 | Release 图形安装向导、升级保留与事务重配置 | [Release](https://github.com/YanYunCY/ClashCloudflareDynamic/releases/tag/v1.1.0) |
| `v1.0.2` | 历史稳定版 | 阶段漏斗、失败与名额未入选分离、失败报告 | [Release](https://github.com/YanYunCY/ClashCloudflareDynamic/releases/tag/v1.0.2) |
| `v1.0.1` | 历史稳定版 | 协议与端口写入 CSV、决策 JSON 和报告 | [Release](https://github.com/YanYunCY/ClashCloudflareDynamic/releases/tag/v1.0.1) |
| `v1.0.0` | 已被取代 | 首个公开版本，仅建议用于历史查阅 | [Release](https://github.com/YanYunCY/ClashCloudflareDynamic/releases/tag/v1.0.0) |

逐版本变更记录见 [CHANGELOG.md](https://github.com/YanYunCY/ClashCloudflareDynamic/blob/main/CHANGELOG.md)。

## 主要功能

- 每 2 小时轻量扫描，默认最多发现 200 个新地址；
- 每 12 小时深度扫描约 5000 个新地址，深扫运行期间轻扫自动跳过；
- SQLite 避免短期重复抽样，并自动维护历史；
- 真实代理链路验证，不以裸 IP 的 HTTP 测速代替节点验证；
- VMess、VLESS、Trojan 示例和自定义 Mihomo 节点模板；
- Release 安装入口可选择 Clash/Mihomo 图形向导或 v2rayN/Xray 安装器；
- v2rayN 模式使用临时 Xray 进程并行验证候选，不让候选测速占用活动代理端口；
- v2rayN TUN 开启时，TCP 初筛绑定 Windows 物理默认接口，避免扫描流量回灌当前代理；
- TCP 初筛自动跟随节点模板端口，不再写死为 443；
- 发现、粗测、正式测速 CSV、决策 JSON 和通知报告记录协议与端口；
- 每个最终候选连续测试 3 次，记录原始值、平均值、标准差和 CV；
- 在最高平均速度 95% 的高速组中选择平均延迟最低节点；
- provider 原子更新、`.last-good` 回滚和 Mihomo 状态确认；
- `pythonw.exe` 后台任务，不创建可见命令行窗口；
- 静音高优先级 Windows 通知，点击查看独立 HTML 报告；
- 日志轮转、通知报告数量上限、备份清理、数据库损坏备份与恢复；
- 深扫前台繁忙延后和独立任务健康监控。

## 运行要求

- Windows 10/11；
- Python 3.10 或更高版本，并包含同目录的 `pythonw.exe`；
- `curl.exe`；
- 任选一个客户端后端：Clash Verge Rev + 可从本机访问的 Mihomo REST API，或已安装并至少启动过一次的 v2rayN；
- 一个你有权使用的代理节点模板。程序只替换候选节点的显示名和 Cloudflare 入口 IP，其余认证、端口、SNI 和传输参数保持不变。

Clash/Mihomo 模式支持 VMess、VLESS、Trojan 和自定义 Mihomo 节点模板，具体字段以 [Mihomo 官方文档](https://wiki.metacubex.one/en/config/proxies/) 为准。

v2rayN/Xray 模式要求 v2rayN 根目录包含 `v2rayN.exe`、`guiConfigs/guiNDB.db`、`guiConfigs/guiNConfig.json` 和 `bin/xray/xray.exe`。当前实现按 v2rayN 7.24.x 的 SQLite 结构开发和测试；安装器不会下载或替换 v2rayN。安装器只生成一套由用户填写认证、端口、SNI、Host 和路径的 VMess + WebSocket + TLS 模板；不会读取、复制或假设维护者的节点、地区、出口或数据库槽位。

默认地址：

- Mihomo API：`http://127.0.0.1:9090`
- mixed proxy：`http://127.0.0.1:7890`
- v2rayN 本地 HTTP 代理：默认 `http://127.0.0.1:10808`，安装时可修改；
- 安装目录：`%LOCALAPPDATA%\ClashCloudflareDynamic`
- provider：`%APPDATA%\io.github.clash-verge-rev.clash-verge-rev\providers\ClashCloudflareDynamic`

provider 目录位于 Clash Verge Rev 的 SAFE_PATHS 内，不应改回 `%LOCALAPPDATA%`。

## 默认测速规模

- 深度扫描：基础最多 20 个正式候选，每个候选交错测试 3 次，每次 20 MB、单次超时 60 秒；当前节点未入选时会额外追加，正式测速理论上限约 1.26 GB/轮；
- 轻量扫描：基础最多 8 个正式候选，每次 3 MB、单次超时 20 秒；当前节点未入选时会额外追加，正式测速理论上限约 81 MB/轮；
- `quick_speed_test_bytes` 与 `quick_speed_timeout_seconds` 独立于深扫参数，调整深扫不会再意外放大半小时轻扫流量；
- 排名速度按完整请求墙钟耗时计算，包含连接和 TTFB；扣除 TTFB 的短传输峰值只在日志、CSV 和 HTML 报告中用于诊断，不参与粗测排序、95% 高速组、自动切换或历史信誉。
- 扫描成功、失败或节点选择确认超时后，测速域名使用的发现组会优先恢复到当前自动节点；若配置的独立测速出口包含自动组，则直接恢复为跟随自动组；首选恢复失败时回退到扫描前状态。

正式测速前仍会发起 128 KB 预热请求，预热值不参与排名。以上均为候选满额时的理论上限，实际流量通常更低。

## Release 一键安装

普通用户使用统一入口：

1. 从 [最新稳定版 Release](https://github.com/YanYunCY/ClashCloudflareDynamic/releases/latest) 下载 `ClashCloudflareDynamic.zip`；
2. 完整解压 ZIP，不要直接在压缩包预览窗口中运行；
3. 双击根目录的 `Install.cmd`；
4. 选择 `Clash Verge Rev / Mihomo` 或 `v2rayN / Xray`；
5. Clash 模式在图形向导中选择协议并填写 API 与节点参数；v2rayN 模式填写基础 VMess/WS/TLS 参数和本地 HTTP 代理地址；
6. 按对应后端章节完成客户端内的一次性选择。

向导不会下载或执行网络上的安装脚本。UUID、密码和 API secret 使用掩码输入，只写入受控临时目录和本机安装目录；临时配置在安装成功或失败后都会清理，不会留在 Release 解压目录。

检测到已有安装时：

- 选择“保留配置并升级（推荐）”：升级或修复程序，保留现有协议、端口和凭据；
- 选择“重新填写节点参数”：安装器先事务备份，再替换设置、重建 Clash YAML，并用原 IP 列表重建 provider；
- 选择“取消”：不修改安装。

这是引导式一键安装，仍要求本机已安装 Python 3.10+、`pythonw.exe` 和所选客户端。项目尚未使用代码签名证书，因此 Windows 可能显示未知发布者提示；请只从本仓库 Release 下载，并核对 Release 中公布的 SHA-256。

## Clash Verge Rev 中的必要设置

安装脚本不能代替用户修改 Clash Verge Rev 的应用设置。首次使用时必须启用 Mihomo 外部控制，否则程序无法通过 REST API 读取 provider、测试节点或切换“自动选择”：

1. 打开 Clash Verge Rev，进入 `设置 → Clash 设置`（不同版本可能显示为 Mihomo 内核设置）；
2. 找到并打开 `外部控制`；
3. 外部控制地址建议保持为 `127.0.0.1:9090`，不要绑定到 `0.0.0.0` 或公网地址；
4. 如果 Clash Verge Rev 设置了外部控制密钥，请在安装向导的“Mihomo API 密钥”中填写完全相同的值；没有设置密钥时两边都留空；
5. 如果使用其他端口，请同时把安装向导中的 Mihomo API 改为对应地址，例如 `http://127.0.0.1:9191`；
6. 保存设置，并按 Clash Verge Rev 提示重载配置或重启 Mihomo 内核；
7. 进入配置页面，导入并启用：

   ```text
   %LOCALAPPDATA%\ClashCloudflareDynamic\clash_cloudflare_dynamic_verge_safe.yaml
   ```

8. 进入代理页面，在 `节点选择` 中选择 `自动选择`；
9. 双击安装目录中的 `diagnose.bat`。只有显示“Mihomo API：正常”“provider SAFE_PATHS：正常”和“节点选择当前策略：自动选择”后，自动扫描与切换才算配置完成。

外部控制只需要允许本机访问。不要为了排查连接问题关闭密钥、监听所有网卡或把控制端口暴露到局域网/公网；如果诊断显示连接被拒绝，优先检查“外部控制”开关、端口以及 Mihomo 内核是否已经重新加载。

## v2rayN/Xray 模式

v2rayN 安装器只生成本机工具配置和计划任务，不安装客户端，也不把公开示例直接写进 v2rayN 数据库。首次安装后：

1. 保持 v2rayN 正常运行，确认系统代理或 TUN 至少启用一个；
2. 运行 `python "%LOCALAPPDATA%\ClashCloudflareDynamic\dynamic_selector.py" --setup-v2rayn-auto`，创建通用的 `AUTO-CF` 原生活动槽；
3. 在 v2rayN 中把 `AUTO-CF` 设为活动节点。优选器只更新用户安装时填写的模板，不会跨协议、跨地区或跨设备读取其他节点；
4. 如需另一套协议或线路，请单独运行另一份安装目录并填写另一份用户自有模板，不要把私人数据库或运行目录复制进 Release；
5. 运行 `python "%LOCALAPPDATA%\ClashCloudflareDynamic\dynamic_selector.py" --diagnose`，确认 v2rayN、Xray、活动槽、系统代理/TUN 和路由状态。

自动切换会事务备份 `guiNDB.db`，把胜出配置复制到当前 AUTO 槽，再调用 v2rayN 自身的 Reload 控件热重载子核心；不会退出或强制结束 v2rayN 桌面进程。若当前节点不是 AUTO 槽，程序只更新节点库并拒绝旧式重启切换。

扫描期间每个候选由独立临时 Xray 监听验证，不经过 Mihomo，也不复用 v2rayN 的活动代理端口。TUN 开启时，TCP 初筛仅把扫描 socket 绑定到 Windows 物理默认接口，普通应用路由不变。报告中的“冷启动代理响应”是每次新建完整代理链路并访问测试 URL 的响应时间，包含协议握手、目标 TLS 和首个响应，不等同于 v2rayN GUI 显示的入口 RTT。

v2rayN 模式会写入 `CCD Full Split | CN DIRECT | Overseas PROXY | Store DIRECT | DNS/WebRTC Safe` 路由。它覆盖广告拦截、私网和中国域名/IP 直连、Microsoft Store/CDN/Windows Update 直连、Microsoft 登录与常见国外服务显式代理、常见 WebRTC/STUN UDP 强制代理，以及最终国外兜底代理；DNS 专用规则位于最终兜底之前，避免被全代理规则遮蔽。当前节点为 HY2/sing-box 时在 `binConfigs/config.json` 的 `dns`、`route` 查看实际结果；当前节点为 Xray 时在 `config.json` 的 `dns`、`routing` 和 `configPre.json` 的 TUN `dns`、`route` 查看。

路由层的常见 STUN 端口保护不能代替浏览器自身的隐私策略。对 DNS/WebRTC 有严格要求时，仍应在浏览器或企业策略层禁用非代理 UDP，并验证实际出口。

只生成配置、不安装任务时，可使用隔离模式：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows\install_v2rayn.ps1 `
  -NonInteractive -PrepareOnly `
  -V2rayNRoot "C:\path\to\v2rayN" `
  -Uuid "your-vmess-uuid" `
  -ServerName "your-domain" -HostName "your-domain" `
  -PreparedConfigurationDirectory "$env:TEMP\ccd-v2rayn-config"
```

`--v2rayn-dry-run` 会执行候选发现、真实 Xray 响应和三轮下载测速，但不写 v2rayN 数据库、不更新 AUTO 槽，也不切换系统代理：

```powershell
python "$env:LOCALAPPDATA\ClashCloudflareDynamic\dynamic_selector.py" --quick --v2rayn-dry-run
```

## Clash/Mihomo 手动安装（高级用户与开发者）

开发者从源码安装时，以下命令均在仓库根目录运行；部署包用户则去掉路径中的 `scripts\windows\`。

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

3. 编辑 `node_template.json`，把 `replace-with-your-domain.example` 同时替换为你自己的 SNI/Host 域名，并替换示例 UUID/密码和传输路径，再次核对 `type` 与 `port`。公开源码和 Release 只包含保留的占位域名，不包含维护者或其他用户的真实域名；安装器也会拒绝使用 `.example`、`example.com`、`example.net` 或 `example.org` 生成实际配置。

   Cloudflare 普通代理当前支持的 HTTPS 入口端口为 `443`、`2053`、`2083`、`2087`、`2096`、`8443`。端口是否真的适用于你的节点，还取决于域名、源站和服务端配置；不能因为某个 Cloudflare IP 的端口可建立 TCP 连接，就认定真实代理协议可用。项目仍会用完整节点链路淘汰假阳性。详见 [Cloudflare 官方端口说明](https://developers.cloudflare.com/fundamentals/reference/network-ports/)。

   协议也不是任意替换后都能经过普通 CDN。VMess/VLESS/Trojan 的 WS、HTTP、gRPC 等部署可以按实际服务端模板配置；纯 TCP、QUIC/UDP 或其他非 HTTP(S) 传输通常需要不同的 Cloudflare 产品或根本不适用。自定义模板必须满足“只替换 `server` 为 Cloudflare IP 后仍能凭 SNI/Host 等字段到达同一服务”的条件。

4. 安装推荐的混合任务：

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\scripts\windows\install_hybrid_5000.ps1
   ```

   安装器会在创建目录、备份或任务之前检查本地配置；仍含零 UUID、示例密码、保留的示例域名或示例 WebSocket 路径时会直接拒绝安装。

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

`settings.json`、`node_template.json`、生成的 Clash YAML、provider、日志、v2rayN SQLite 备份、运行状态和通知报告均已列入 `.gitignore`。不要使用 `git add -f` 强制提交它们。

公开的 `config.template.yaml` 不包含 SNI、Host、UUID 或节点密码。SNI/Host 只来自当前用户在安装向导中填写的域名，并写入该用户本机的 `node_template.json` 和 provider；这是 Mihomo 通过 Cloudflare IP 定向到用户自己节点域名所必需的数据，不会上传到 GitHub。公开的三个节点示例统一使用 `replace-with-your-domain.example`，不能直接安装或连接。

隐私检查器也会检查被 Git 忽略但仍留在工作目录中的本地配置，并且只报告文件名和风险类别，不打印匹配到的凭据。制作 Release 压缩包时应从已审核的 Git 提交生成归档，不要直接压缩正在运行或测试过的工作目录。

Git 已跟踪文件也会单独检查；即使使用 `git add -f`，备份、日志、provider 或本地配置进入 Git 后仍会导致隐私检查失败。

提交或发布前运行：

```powershell
python .\tools\privacy_check.py
git status --ignored --short
```

## 选优规则

1. 候选必须通过节点模板所选端口的 TCP 初筛；
2. provider 热更新后通过真实代理链路做 3 轮延迟测试；
3. 低延迟、历史高速和随机探索候选进入速度粗测；
4. 正式候选按轮交错下载测速 3 次，避免某个节点连续占用同一时间窗口；
5. 任意一次失败、下载量不足或速度 CV 超过阈值时淘汰；
6. 达到本轮最高平均速度 `fast_speed_ratio` 的节点进入高速组；
7. 高速组内按三轮平均延迟选择节点；
8. 历史速度按每个 IP 最近 `historical_speed_samples_per_ip` 次结果加权，并使用 `historical_speed_stability_penalty` 惩罚波动；
9. 正式池默认只新增通过正式下载测速的节点，旧正式池有效节点继续保留；只有显式设置 `allow_delay_only_pool_backfill: true` 才允许仅通过延迟测试的新节点补池；
10. 正常切换受冷却时间控制，失效节点可以立即替换；
11. 扫描退出前恢复测速域名出口，避免浏览器测速继续命中临时候选。

## 通知与 HTML 报告中的阶段漏斗

Windows 通知和点击后打开的 HTML 报告按“候选 → TCP 可达 → 真实代理链路 → 速度粗测 → 正式三轮测速”展示本轮漏斗。v2rayN 模式对应显示“TCP 物理直连初筛”和“真实协议冷启动响应”。相邻阶段的数量差不能一律理解为失败：发现池、速度粗测池和正式测速池都有数量上限，候选可能已经通过前一阶段，只是因当轮配额、排序或抽样策略未进入下一阶段；这种情况属于“未入选”，不是链路或测速失败。

- `各阶段失败 IP` 是本轮各验证阶段确认失败的 IP 总数，例如 TCP 不可达、真实代理链路失败、速度粗测失败或正式三轮测速失败；不包含仅因配额未入选的候选。
- `名额未入选` 使用各阶段实际选择名单计算；极少数已被选择但因无效节点名等内部原因没有执行测试的项，会单列为 `已选未执行`，不会被误算成配额未入选。
- HTML 中的 `正式三轮测速淘汰` 只列出已经进入正式三轮下载测速、但因测试轮次失败、下载量不足或速度 CV 超限而未通过的节点。没有进入正式测速配额的节点不会出现在该表中。
- `正式尝试` 是实际进入正式三轮测速的节点数，`正式通过` 是其中完整通过正式测速质量条件的节点数；二者之差才对应正式测速阶段的淘汰数量。
- `高速组` 是正式测速通过后的二次选优标签。速度低于当轮 `fast_speed_ratio` 门槛而位于高速组外，只表示没有进入最终的低延迟竞争组，不代表节点失败，也不会列入 `正式测速淘汰`。

扫描在中途失败时，通知会附带截至失败阶段已经取得的部分漏斗，并生成可点击的失败 HTML 报告；尚未运行的阶段保持为零，同时以失败阶段和错误原因说明扫描停止位置。

## 后台任务

- `Clash Cloudflare Light Scan 2h`
- `Clash Cloudflare Deep Scan 5000 12h`
- `Clash Cloudflare Health Monitor 30min`

选择 v2rayN 后端时，安装器改为创建以下互斥任务，并停用冲突的 Clash 扫描任务：

- `v2rayN Cloudflare Light Scan 2h`
- `v2rayN Cloudflare Deep Scan 5000 12h`
- `v2rayN Cloudflare Health Monitor 30min`

扫描和健康监控均使用 `pythonw.exe`。健康监控启动器通过 `CREATE_NO_WINDOW` 调用 PowerShell，因此不会弹出空命令行窗口。轻量和深度扫描分别写入 `logs/last_run_light.json` 与 `logs/last_run_deep.json`，区分 `success`、`skipped`、`failed`；健康监控只把有效成功心跳记为最近成功，并检查正式测速通过数和正式池大小。

## 通知报告与日志维护

每条 Windows 通知都绑定独立 HTML，默认最多保留最新 100 份且不超过 30 天；任一条件超限时删除最旧报告。可用 `notification_report_max_files` 和 `notification_report_retention_days` 调整。主扫描日志默认达到 5 MB 后轮转并保留 3 份备份；通知投递日志、健康监控日志和健康监控启动器错误日志也会轮转，不会无限追加。通知投递日志默认每份 1 MB、保留 2 份备份，可用 `notification_delivery_log_max_bytes` 和 `notification_delivery_log_backups` 调整。

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
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\windows\test_install_wizard.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\windows\test_install_hybrid.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\windows\test_install_v2rayn.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\windows\test_uninstall.ps1
```

GitHub Actions 会在 Windows 上执行同一组检查，并把由已审查源码生成的 `ClashCloudflareDynamic.zip` 作为工作流产物上传。

## 免责声明

Cloudflare Anycast 性能会随地区、运营商和时间变化。本软件不保证永久最快地址，也不保证第三方代理服务可用。请遵守当地法律、服务条款和网络使用政策。

## License

[MIT](LICENSE)
