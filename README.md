# SOCKS5 一键部署

在使用 systemd 的 Linux VPS 上部署 SOCKS5 代理。默认保留原有安装流程；多 IP VPS 可另外启用按用户名或接入 IP 绑定出口。

## 🚀 一键安装

在本修改版源码目录运行：

```bash
sudo bash install.sh
```

安装过程中可自定义端口、用户名、密码，直接回车则随机生成。也可沿用 `bash <(curl -fsSL URL)` 的一键方式，但 `URL` 必须指向你发布的修改版脚本；原上游链接不包含多出口功能。

## 📋 功能

- ✅ 自动检测系统（Ubuntu/Debian/CentOS/Rocky/Alpine/Arch 等）
- ✅ 自动检测架构（amd64/arm64/armv7）
- ✅ 用户名 + 密码认证
- ✅ 随机端口 & 密码（可自定义）
- ✅ 开机自启（systemd）
- ✅ 自动放行防火墙（ufw/firewalld/iptables）
- ✅ 多用户管理
- ✅ 一键卸载
- ✅ 安装完成输出 `socks5://` 连接链接

## 🔧 管理命令

安装完成后，在终端运行 `sudo socks5` 或 `sudo socks5 menu`。输入编号即可查看服务状态和连接信息、启停服务、管理用户、配置出口、查看日志、修改端口、升级或卸载。查看用户列表只显示用户名；连接信息包含密码，请只在可信终端中查看。重要变更会先显示预览或确认提示，直接回车表示取消；执行失败时可重试或返回。

- 查看日志提供最近 50/200 行，完整历史仍可用 `journalctl -u socks5-proxy`。
- 修改端口会生成并校验新配置，尝试放行防火墙，运行中的服务重启并确认新端口监听，失败则恢复原端口。修改后需同步更新客户端。
- 菜单内升级从本机复制保存的 `/etc/socks5/installer.sh` 执行，需输入升级二进制的绝对路径；较早版本若提示找不到安装脚本，先在源码目录执行一次 `sudo bash install.sh upgrade /路径/gost-routed`。

已经部署了本项目多出口版本的实例，可从新版源码目录单独更新菜单，不会重启服务或改动用户、端口及路由配置：

```bash
sudo bash install.sh update-cli
sudo socks5
```

若提示现有部署不支持单独更新，请使用下文的原地升级流程。原有命令的调用方式不变；非终端环境下，无参 `socks5` 只打印帮助：

```bash
socks5 info        # 查看连接信息
socks5 status      # 查看服务状态
socks5 start       # 启动服务
socks5 stop        # 停止服务
socks5 restart     # 重启服务
socks5 add         # 添加用户
socks5 del         # 删除用户
socks5 list        # 查看用户列表
socks5 uninstall   # 一键卸载
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

支持架构: `amd64` `arm64` `armv7`

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
  管理命令: socks5 help
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
- 标准安装默认仅启用 TCP CONNECT，与上游相同。扩展 GOST 支持在单独管理的 GOST 配置中设置 `handler.metadata.udp: true` 启用 UDP ASSOCIATE；请勿直接修改安装脚本生成的 YAML。启用 UDP 后，转发套接字也绑定到选定出口，客户端需能访问返回的 UDP 中继地址和端口。多出口模式不支持 BIND、MUX BIND 和 GOST 私有 UDP Tunnel。

在修改版源码目录中执行。新机器先执行安装；已有安装直接构建和升级，不要重新运行交互安装覆盖用户：

```bash
sudo bash install.sh                       # 仅在尚未安装时执行
bash build-routed-gost.sh "$PWD/gost-routed" # 用 Git 和本机 Go（1.21 或更新版本）构建
sudo bash install.sh upgrade "$PWD/gost-routed"
```

### 通过菜单配置出口

运行 `sudo socks5`，选择「出口配置」，再选系统默认、按接入 IP 或按用户名。按用户名模式会引导你为账号填写本机出口 IP；未映射的账号不能转发。核对预览后确认应用。原本停止的服务只保存策略，不会被自动启动；运行中的服务会重启并检查监听，应用失败会尝试恢复旧策略和服务。两种绑定模式均需先按上节部署扩展二进制。

也可按以下说明手动维护策略文件。

### 规则一：按用户名指定出口

用 `sudoedit /etc/socks5/routes.conf` 编辑。首个非空、非注释行为 `username`，其余每行一个 `已存在的用户名=本机IP`。支持以 `#` 开头的整行注释，不要在 IP 后写行尾注释。每个用户名只能出现一次。映射用户名不要包含 `=`，也不要以 `#` 或空白开头；IPv6 地址直接填写，不加方括号或作用域后缀：

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

1. **用户名模式**：运行前两条，预期分别为出口 A、B。再从入口 B 用 `alice`，预期仍为出口 A。
2. **接入 IP 模式**：同一用户对入口 A、B 分别请求，预期分别为出口 A、B。
3. 每组重复及并发执行，记录接入地址、账号、预期公网 IP 和回显值。补测错误密码、无映射用户、重启、增删用户与回滚。在有带外管理的测试 VPS 中让一个出口不可用时，应看到该规则转发失败，另一个出口仍按原规则工作，不能串到另一出口。
4. 如启用 UDP ASSOCIATE，用支持该命令的客户端及受控的外部 UDP 接收端按同一矩阵核对源 IP；仅运行 `curl` 不代表验证了 UDP。

### 管理菜单测试

在源码目录运行 `python3 test-menu.py`。测试使用临时配置和模拟服务，不会启停真实代理或写入系统目录。Linux 使用伪终端验证交互；Windows 可使用 Git Bash 运行模拟交互测试。

## ⚠️ 注意事项

- 需要 root 权限运行
- 确保 VPS 安全组/面板防火墙已放行对应端口
- 建议使用强密码

## 📄 License

MIT


