# SOCKS5 一键部署

在使用 systemd 的 Linux VPS 上部署 SOCKS5 代理。默认保留原有安装流程；多 IP VPS 可另外启用按用户名或接入 IP 绑定出口。

## 🚀 一键安装

在本修改版源码目录运行：

```bash
sudo bash install.sh
```

安装过程中可自定义端口、用户名、密码，直接回车则随机生成。也可在任意 Linux VPS 上直接运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ca9oxa0/socks5-setup/main/install.sh)
```

## 📋 功能

- ✅ 自动检测 Linux 发行版与包管理器（apt/yum/apk/pacman/zypper）
- ✅ 自动检测架构（amd64/arm64/armv7/386）
- ✅ 用户名 + 密码认证
- ✅ 随机端口 & 密码（可自定义）
- ✅ 开机自启（systemd）
- ✅ 检测并放行防火墙端口（ufw/firewalld/iptables）
- ✅ 多用户管理
- ✅ 一键卸载
- ✅ 安装完成输出 `socks5://` 连接链接

## 🔧 管理命令

安装完成后，在终端运行 `sudo socks5` 或 `sudo socks5 menu`。菜单项与脚本一致：

```text
 1) 状态   2) 连接信息   3) 用户列表
 4) 启动   5) 停止       6) 重启
 7) 添加   8) 删除       9) 出口配置
10) 查看日志  11) 修改端口  12) 升级
13) 卸载   0) 退出
```

菜单和所有子命令都需要 root。菜单中的「用户列表」只显示用户名；「连接信息」以及 `socks5 info`、`socks5 list` 会输出包含密码的 `socks5://` 链接，`socks5 add` 也会输出新账号链接，请只在可信终端中查看。菜单添加用户时密码输入不回显；命令行 `socks5 add` 在终端中输入的密码会回显。重要变更会先显示预览或确认提示，直接回车表示取消；执行失败时可重试或返回。`socks5`/`socks5 menu` 需要交互式终端，管道或脚本中请使用子命令。

- 查看日志提供最近 50/200 行，完整历史仍可用 `journalctl -u socks5-proxy`。
- 修改端口会生成并校验新配置，尝试放行防火墙，运行中的服务重启并确认新端口监听，失败则恢复原端口。修改后需同步更新客户端。
- 添加或删除用户会重建认证配置并重启服务（即使服务原本停止也会被启动）；删除最后一个用户会停止服务；没有有效用户时服务拒绝启动。
- 菜单内升级通过保存的 `/etc/socks5/installer.sh` 执行，需输入 https 地址或本地绝对路径（菜单不自动解析 `latest`）；较早版本若提示找不到安装脚本，先在源码目录执行一次 `sudo bash install.sh upgrade`（在线）或指定本地包。

已经部署了本项目多出口版本的实例，可从新版源码目录单独更新菜单，不会重启服务或改动用户、端口及路由配置：

```bash
sudo bash install.sh update-cli
sudo socks5
```

若提示现有部署不支持单独更新，请使用下文的原地升级流程。原有命令的调用方式不变；非终端环境下，无参 `socks5` 只打印帮助：

```bash
socks5 menu        # 打开交互菜单
socks5 info        # 查看连接信息
socks5 status      # 查看服务状态
socks5 start       # 启动服务
socks5 stop        # 停止服务
socks5 restart     # 重启服务
socks5 add         # 添加用户
socks5 del         # 删除用户
socks5 list        # 查看用户列表（输出含密码链接）
socks5 uninstall   # 一键卸载
socks5 help        # 查看命令帮助
```

## 📦 技术栈

- 底层代理: [gost v3](https://github.com/go-gost/gost) — 轻量单二进制文件
- 服务管理: systemd
- 配置格式: YAML

## 🖥️ 支持系统

以 systemd 作为 PID 1 为前提；使用默认 OpenRC 的 Alpine 不适用本安装脚本。

| 系统 | 版本 | 状态 |
|------|------|------|
| Ubuntu | 18.04+ | ✅ |
| Debian | 10+ | ✅ |
| CentOS | 7+ | ✅ |
| Rocky Linux | 8+ | ✅ |
| AlmaLinux | 8+ | ✅ |
| Fedora | 36+ | ✅ |
| Alpine | 3.15+ | ❌ 默认 OpenRC，需自行改用 systemd |
| Arch Linux | latest | ✅ |

支持架构: `amd64` `arm64` `armv7` `386`

## 📖 使用示例

### 安装

```
$ sudo bash install.sh

╔═══════════════════════════════════════╗
║     SOCKS5 一键部署脚本               ║
╚═══════════════════════════════════════╝

[i] 检测到系统: ubuntu 22.04 (包管理器: apt)
[i] 检测到架构: amd64
[✓] 依赖安装完成
[?] 端口 (回车随机 34521):
[?] 用户名 (回车随机 user_a3Kx):
[?] 密码 (回车随机):
[i] 开始安装...
[✓] gost 下载完成
[✓] ufw 已放行端口 34521
[✓] 服务已启动并设置开机自启

═══════════════════════════════════════════
  ✓ 安装完成!
═══════════════════════════════════════════

  服务器:  1.2.3.4
  端口:    34521
  用户名:  user_a3Kx
  密码:    xK9mP2vL8nQw5rT1

  连接链接:
  socks5://user_a3Kx:xK9mP2vL8nQw5rT1@1.2.3.4:34521

═══════════════════════════════════════════
  管理菜单: socks5（命令帮助：socks5 help）
═══════════════════════════════════════════
```

### 测试连接

```bash
curl -x socks5://user:pass@ip:port https://httpbin.org/ip
```

## 多出口 IP 配置

### 前提和部署

- VPS 使用 systemd，且待绑定地址已配置在本机，并有正常的源地址路由。可用 `ip -br addr` 查看本地地址，再用 `ip route get <目标地址> from <出口地址>` 检查路由。示例中的文档保留地址不能直接使用。
- 配置的是**本机 IP**，不是虚拟机未持有的公网 IP。如果云厂商做了 SNAT，还要核对每个本机地址对应的公网出口。如果多个公网入口经 DNAT 后到达同一个本机地址，接入 IP 模式无法区分它们。
- 监听端口和用户仍沿用现有配置。请在云安全组和主机防火墙只放行受信客户端。
- 出口策略只决定转发使用的源地址，不按域名或端口限制目标（仍受下述地址族约束）；需要额外访问控制时，请在 GOST 配置或上游防火墙实现。
- 标准安装默认仅启用 TCP CONNECT，与上游相同。扩展 GOST 支持在单独管理的 GOST 配置中设置 `handler.metadata.udp: true` 启用 UDP ASSOCIATE；请勿直接修改安装脚本生成的 YAML。启用 UDP 后，转发套接字也绑定到选定出口，客户端需能访问返回的 UDP 中继地址和端口。多出口模式不支持 BIND、MUX BIND 和 GOST 私有 UDP Tunnel。

在修改版源码目录中执行。新机器先执行安装；已有安装直接构建和升级，不要重新运行交互安装覆盖用户：

```bash
sudo bash install.sh                       # 仅在尚未安装时执行
bash build-routed-gost.sh "$PWD/gost-routed" # 用 Git 和本机 Go（1.21 或更新版本）构建
sudo bash install.sh upgrade "$PWD/gost-routed"
```

没有构建环境时可直接在线升级。不带参数时按当前架构从最新发布自动解析资产；已发布的架构以 [Releases](https://github.com/ca9oxa0/socks5-setup/releases) 为准，缺少对应架构时请本地构建：

```bash
sudo bash install.sh upgrade          # 自动选择与 uname -m 匹配的最新资产
sudo bash install.sh upgrade latest   # 同上，显式写法
sudo bash install.sh upgrade https://github.com/ca9oxa0/socks5-setup/releases/download/v3.0.0-rc10-routed.1/gost-routed-linux-amd64
```

`upgrade` 和菜单「升级」都接受 `https://` 地址或本地绝对路径，只允许 HTTPS。在线模式读取最近 30 个发布（含预发布），按当前架构匹配完整的二进制文件名；没有匹配资产或 GitHub API 限流时会提示改用显式地址。下载内容会先通过路由契约校验，再替换程序并保留端口和用户，失败时恢复原安装。脚本还会把自身保存到 `/etc/socks5/installer.sh` 供菜单复用；通过管道运行 `bash <(curl ...)` 时自动下载最新安装脚本。

### 通过菜单配置出口

运行 `sudo socks5`，选择「出口配置」，可选系统默认、按接入 IP、按用户名或查看当前策略。按用户名模式会逐个询问账号的本机出口 IP，回车跳过该账号；至少要填写一个映射，未映射的账号不能转发。核对策略预览后确认应用。原本停止的服务只保存策略，不会被自动启动（下次启动服务时生效）；运行中的服务会重启并检查监听，应用失败会尝试恢复旧策略和服务。两种绑定模式均需先按上节部署扩展二进制。

也可按以下说明手动维护策略文件。

### 规则一：按用户名指定出口

用 `sudoedit /etc/socks5/routes.conf` 编辑。首个非空、非注释行为 `username`，其余每行一个 `已存在的用户名=本机IP`。支持以 `#` 开头的整行注释，不要在 IP 后写行尾注释。每个用户名只能出现一次。映射用户名不要包含 `=`；行首尾空白和等号两侧空白会被忽略；IPv6 地址直接填写，不加方括号或作用域后缀：

```text
username
# 地址仅用于说明，替换为 VPS 本机地址
alice=192.0.2.10
bob=192.0.2.11
```

例如两人都连接 `192.0.2.10:1080`，`alice` 的流量仍从 `192.0.2.10` 发出，`bob` 的流量从 `192.0.2.11` 发出。先用 `sudo socks5 add` 添加凭据，再为该用户配置映射。没有映射的用户即使认证成功，也不能建立转发。出口绑定失败不会改用另一地址。删除用户后，管理命令不会代改策略文件；如果不想让未来同名账号继承该出口，请同时移除旧映射。

### 规则二：出口与接入 IP 相同

`/etc/socks5/routes.conf` 只写 `ingress`，不填用户名或 IP 列表：

```text
ingress
```

同一个用户连 `192.0.2.10:1080` 或 `192.0.2.11:1080`，本机出口分别绑定 `192.0.2.10` 或 `192.0.2.11`。接入 IP 是 VPS 套接字实际收到的本地目的地址，不是客户端的源地址。两种模式互斥；单条会话仅绑定一个源地址，不能跨地址族转发。绑定的是代理转发套接字；VPS 的系统 DNS 查询、管理请求及其他进程的流量不受这些规则控制。

目标必须与接入地址同族：IPv4 接入只能访问 IPv4 字面地址或有 A 记录的域名，IPv6 接入只能访问 IPv6 字面地址或有 AAAA 记录的域名。缺少同族地址时，请求以 SOCKS 状态码 `8`（地址类型不支持）拒绝，日志提示 `has no IPv4 address` / `has no IPv6 address`，不会改用其他出口。经 `127.0.0.1` 等回环地址接入时，绑定回环源地址无法访问外部网络，请从 VPS 的公网或业务内网地址连接。映射行允许缩进及等号两侧空白。

### 生效和回滚

```bash
sudo chmod 600 /etc/socks5/routes.conf
sudo socks5 restart
sudo socks5 status
sudo journalctl -u socks5-proxy -n 50 --no-pager
```

要恢复系统默认选路，备份并移走策略文件，然后重启；用户和端口保持不变：

```bash
sudo mv /etc/socks5/routes.conf /etc/socks5/routes.conf.disabled
sudo socks5 restart
```

### 本地验证与真实 VPS 验收

测试脚本不修改系统配置，也不需要外部服务。它会启动临时代理及 TCP/UDP 接收端，检查接收端所见的源 IP、并发连接、认证，以及未映射用户是否被拒绝。传入两个已经配置在测试机上的同族地址。下例只适用于可修改的 Linux 测试机；如果 `127.0.0.2/32` 原本就存在，不要重复添加或在测试后删除。

```bash
sudo ip addr add 127.0.0.2/32 dev lo
python3 test-routes.py ./gost-routed --stock /usr/local/bin/gost
sudo ip addr del 127.0.0.2/32 dev lo
```

如果测试机禁止跨接口访问，可传入两个已配置的 IP，并加 `--separate-observers` 让每个接收端监听对应地址。该选项依然核对实际源 IP，但不能代替两条路径访问同一公网目的地的验收。

在真实 VPS 上，从外部测试机向自己的公网 IP 回显端点发送请求。例如，出口回显端点在 `observer.example.net`，返回它实际看到的 TCP 源 IP：

```bash
curl --fail --max-time 15 --proxy 'socks5h://入口A:端口' --proxy-user alice https://observer.example.net/ip
curl --fail --max-time 15 --proxy 'socks5h://入口A:端口' --proxy-user bob   https://observer.example.net/ip
curl --fail --max-time 15 --proxy 'socks5h://入口B:端口' --proxy-user alice https://observer.example.net/ip
```

未在命令行提供密码时，`curl` 会提示输入 `--proxy-user` 对应的密码。

1. **用户名模式**：运行前两条，预期分别为出口 A、B。再从入口 B 用 `alice`，预期仍为出口 A。
2. **接入 IP 模式**：同一用户对入口 A、B 分别请求，预期分别为出口 A、B。
3. 每组重复及并发执行，记录接入地址、账号、预期公网 IP 和回显值。补测错误密码、无映射用户、重启、增删用户与回滚。在有带外管理的测试 VPS 中让一个出口不可用时，应看到该规则转发失败，另一个出口仍按原规则工作，不能串到另一出口。
4. 如启用 UDP ASSOCIATE，用支持该命令的客户端及受控的外部 UDP 接收端按同一矩阵核对源 IP；仅运行 `curl` 不代表验证了 UDP。

### 管理菜单测试

在源码目录运行 `python3 test-menu.py`。测试使用临时配置和模拟服务，不会启停真实代理或写入系统目录。Linux 使用伪终端验证交互；Windows 可使用 Git Bash 运行模拟交互测试，会跳过需要伪终端的用例。

## ⚠️ 注意事项

- 需要 root 权限运行
- 确保 VPS 安全组/面板防火墙已放行对应端口
- 建议使用强密码

## 📄 License

MIT


