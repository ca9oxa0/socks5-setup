# 全新部署指引（基础代理 + gost-routed 多出口组件）

适用于全新 Linux VPS 的从零部署，也适用于需要彻底重装的实例。原地升级只需执行第 6.3 节，不要重跑交互安装。

## 1. 组件边界与部署顺序

| 组件 | 内容 | 说明 |
|---|---|---|
| 基础组件 | `install.sh`、`gost`、`socks5` 管理命令、systemd 服务 | 提供 SOCKS5 用户名/密码认证、端口和用户管理 |
| 多出口组件 | `/usr/local/bin/gost-routed` | `gost` 的替换二进制，按用户名或接入 IP 绑定源地址 |
| 策略文件 | `/etc/socks5/routes.conf` | 存在时才启用 `gost-routed`；默认不存在 |

关键结论：

- `gost-routed` 不是独立守护进程，不能脱离基础安装单独运行。
- 只有 `routes.conf` 存在时，`socks5 _serve` 才启动 `gost-routed`；否则仍使用原版 `gost`。因此“安装组件”不等于“启用多出口”。
- 正确顺序：基础安装 → 验证代理可用 → 安装/构建 `gost-routed` → 创建策略 → 重启并验收。

## 2. 前置条件

### 2.1 系统与权限

- 以 systemd 作为 PID 1 的 Linux；用 `ps -p 1 -o comm=` 确认输出为 `systemd`。
- root 权限（安装、升级、改端口、写策略、重启服务都需要）；普通用户还需可用的 `sudo`。
- `curl` 已安装：一键安装和在线升级都要先用它下载脚本或资产；基础安装会再补齐 `wget tar gzip` 等依赖。
- 支持架构：基础安装支持 `amd64`、`arm64`、`armv7`、`386`；在线发布的 `gost-routed` 资产目前只有 `linux-amd64`，其他架构需在目标架构机器上构建。
- 基础安装会尝试用 apt/yum/apk/pacman/zypper 安装 `curl wget tar gzip`，需要可用的包管理器和软件源。
- 建议至少 512 MB 可用内存；源码构建建议 1 GB 以上可用内存和 2 GB 以上磁盘空间。

### 2.2 网络与端口

- 出站 HTTPS 和 DNS 可用：安装/在线升级访问 `github.com`、`raw.githubusercontent.com`、`api.github.com`、`objects.githubusercontent.com`。
- 源码构建还需访问 `github.com` 与 Go 模块代理（默认 `proxy.golang.org`）；受限网络可设置 `GOPROXY` 或 `HTTPS_PROXY`。
- 入站只放行代理端口/TCP；云安全组和主机防火墙都要放行，且只对受信客户端开放。
- 使用 IPv6 接入模式时，必须同时放行 IPv6 的代理端口（云安全组的 IPv6 规则、`ip6tables` 或 firewalld），并确认 VPS 有可用的 IPv6 地址和默认路由。

### 2.3 多 IP 与云厂商

- 待绑定的地址必须已经配置在本机网卡上，并有正常的源地址路由：
  - `ip -br addr`
  - `ip route get 1.1.1.1 from <出口地址>`（应返回该地址作为 `src`）
- 绑定的必须是**本机地址**。云厂商若做 SNAT，机器地址与公网出口可能不同；若多个公网入口经 DNAT 到同一个本机地址，接入 IP 模式无法区分。
- 部分云厂商会丢弃源地址不属于实例的报文（反欺骗）；新增辅助 IP 后先在控制台确认已绑定/路由到该实例，否则会出现“绑定成功但无流量”。
- 修改端口后，记得同步更新云安全组、客户端配置和任何上游 ACL。

### 2.4 构建依赖（仅源码方案）

- Linux、`git`、Go 1.21 或更新版本（已在 Go 1.22.12 验证）。
- 构建脚本按宿主架构生成二进制；在哪种架构上运行就得到哪种架构的产物。
- 构建不需要 root；`sudo` 只在执行 `install.sh upgrade` 时使用。
- 输出路径必须是文件（不能是目录）；相对路径会按当前目录展开。

## 3. 方案 A：在线全新部署（推荐，无需源码）

### 3.1 步骤 1：基础安装

按登录身份选择一种方式（`sudo bash <(curl ...)` 不可用：sudo 会关闭进程替换的文件描述符，报 `/dev/fd/63: No such file or directory`）：

```bash
# root 用户
bash <(curl -fsSL https://raw.githubusercontent.com/ca9oxa0/socks5-setup/main/install.sh)

# 普通用户
curl -fsSL https://raw.githubusercontent.com/ca9oxa0/socks5-setup/main/install.sh | sudo bash
```

安装过程依次询问端口、用户名、密码，直接回车则随机生成。**记录安装结束输出的端口和 `socks5://` 链接**，后续验收和客户端配置都要用到。

验证标准：

```bash
systemctl is-active socks5-proxy        # active
systemctl is-enabled socks5-proxy       # enabled
sudo ss -ltnp | grep ':<端口>'            # 有 LISTEN
curl -sS --max-time 15 --socks5-hostname '<用户名>:<密码>@127.0.0.1:<端口>' https://api.ipify.org
sudo socks5 info                        # 输出连接链接，密码可见，注意终端环境
```

预期：服务 active 且 enabled、端口在监听、回显的 IP 是 VPS 公网出口。任一项不符先按第 7 节排查，不要继续安装组件。

### 3.2 步骤 2：安装多出口组件

```bash
sudo bash /etc/socks5/installer.sh upgrade
/usr/local/bin/gost-routed -V
```

预期输出包含“GOST 已升级”，`-V` 显示 `gost 3.0.0-rc10 ...`。升级会短暂停止并启动服务，端口、用户和原有认证不变。

若提示 `/etc/socks5/installer.sh` 不存在（较早安装），改用源码目录的 `sudo bash install.sh upgrade`，或：

```bash
curl -fsSL https://raw.githubusercontent.com/ca9oxa0/socks5-setup/main/install.sh | sudo bash -s -- upgrade
```

注意：此时还没有 `routes.conf`，服务仍使用原版 `gost`，这是正常状态。

### 3.3 步骤 3：创建出口策略

推荐用菜单（自动校验、应用并重启）：

```bash
sudo socks5
# 9) 出口配置
# 1) 系统默认   2) 按接入 IP   3) 按用户名   4) 查看当前   0) 返回
```

按用户名模式先确保账号存在（`sudo socks5 add` 或菜单 7），再为账号填写本机出口 IP；回车跳过账号，至少填写一个映射。核对预览后确认应用。

手动方式：

```bash
sudoedit /etc/socks5/routes.conf     # 文件默认不存在，新建即可
sudo chmod 600 /etc/socks5/routes.conf
sudo env SOCKS5_ROUTE_CHECK=1 SOCKS5_ROUTE_FILE=/etc/socks5/routes.conf \
    /usr/local/bin/gost-routed -V
sudo socks5 restart
```

契约校验的成功标准：**无任何输出且退出码为 0**。若打印了版本号，说明用的是原版 `gost`；若打印 `路由文件校验失败`，检查策略文件语法和权限。

### 3.4 步骤 4：功能验收

按模式选择对应测试。下文的 `<用户名>:<密码>` 是基础安装创建的账号。

```bash
# 按用户名模式：从本机回环连接即可，出口应为映射地址
curl -sS --max-time 15 --socks5-hostname '<用户名>:<密码>@127.0.0.1:<端口>' https://api.ipify.org

# 按接入 IP 模式：必须通过具体入口地址连接，不能走 127.0.0.1
curl -sS --max-time 15 --socks5-hostname '<用户名>:<密码>@<入口IP>:<端口>' https://api.ipify.org

# 跨地址族：IPv4 出口访问 IPv6 字面地址，预期 SOCKS 状态码 8
curl -sS --max-time 15 --socks5-hostname '<用户名>:<密码>@127.0.0.1:<端口>' \
    'http://[2606:4700:4700::1111]/'
```

回环地址只适合“按用户名”模式；接入 IP 模式绑定回环源地址无法访问外网，会失败。

再完成以下检查：

- 未映射账号：临时添加一个用户，不写入策略，连接应被拒绝；测试后删除该用户。
- IPv6 接入：`curl --socks5-hostname '<用户名>:<密码>@[<IPv6>]:<端口>' https://api64.ipify.org`，回显应为 IPv6 地址；失败先查 IPv6 防火墙。
- 服务日志：`sudo journalctl -u socks5-proxy -n 50 --no-pager`，应看到监听和连接记录，无持续报错。
- 回滚测试：将 `routes.conf` 改名并重启，出口应恢复系统默认；验证后可改回。

## 4. 方案 B：源码构建部署

### 4.1 准备

```bash
sudo apt-get update && sudo apt-get install -y git   # 以 Debian/Ubuntu 为例
go version                                           # 需 1.21+
```

### 4.2 构建

```bash
git clone https://github.com/ca9oxa0/socks5-setup.git
cd socks5-setup
bash build-routed-gost.sh "$PWD/gost-routed"
./gost-routed -V
```

脚本会按固定提交拉取 `go-gost/gost` 和 `go-gost/x`，应用随仓库提供的补丁，关闭 CGO 并静态构建；临时目录会自动清理。

验证标准：输出文件存在、可执行，`-V` 显示 `3.0.0-rc10`。若提示缺少 `go`/`git`，先安装；若拉取失败，检查 DNS、HTTPS 代理或 `GOPROXY`。

### 4.3 安装

```bash
sudo bash install.sh upgrade "$PWD/gost-routed"
```

`upgrade` 会先校验二进制是否支持路由策略，再替换 `/usr/local/bin/gost-routed` 并保留端口和用户；校验或重启失败会恢复原程序。

### 4.4 验证

```bash
/usr/local/bin/gost-routed -V
systemctl is-active socks5-proxy
sudo socks5 info
```

之后按 3.3、3.4 创建策略并验收。

## 5. 策略文件参考

### 5.1 按用户名指定出口

```text
username
# 地址仅用于说明，替换为 VPS 本机地址
alice=192.0.2.10
bob=192.0.2.11
```

- 首个非空、非注释行必须是 `username`。
- 每行 `已存在的用户名=本机IP`；用户名重复会导致校验失败。
- 用户名不要包含 `=`；行首尾和等号两侧空白会被忽略。
- IP 后不要写行尾注释；IPv6 直接填写，不加方括号或作用域后缀。
- 未映射账号即使认证成功也不能转发（失败关闭）。
- 删除用户不会自动删除映射；避免未来同名账号继承旧出口。

### 5.2 出口与接入 IP 相同

```text
ingress
```

只写 `ingress`，不填用户名或 IP。客户端连接哪个本机入口地址，出口就绑定该地址。接入 IP 是 VPS 套接字实际收到的本地目的地址，不是客户端源地址。

### 5.3 规则与边界

- 两种模式互斥；单条会话只绑定一个源地址。
- 目标必须与源地址同族：IPv4 源只能访问 IPv4 字面地址或有 A 记录的域名，反之亦然；否则以 SOCKS 状态码 8 拒绝，日志提示 `has no IPv4 address` / `is not IPv4`。
- 绑定失败不会改用其他出口。
- 只影响代理转发套接字；系统 DNS、管理请求和其他进程流量不受控制。
- 策略只决定源地址，不按域名或端口限制目标；需要目标 ACL 时在 GOST 配置或上游防火墙实现。

### 5.4 生效、备份与回滚

```bash
sudo cp -a /etc/socks5/routes.conf /root/routes.conf.bak
sudo chmod 600 /etc/socks5/routes.conf
sudo socks5 restart
sudo socks5 status
```

恢复默认选路：

```bash
sudo mv /etc/socks5/routes.conf /etc/socks5/routes.conf.disabled
sudo socks5 restart
```

恢复策略：把备份移回 `routes.conf`，再 `sudo socks5 restart`。升级前可备份 `/usr/local/bin/gost-routed`；升级失败时脚本会自动回滚，手动恢复后需重启服务。

### 5.5 UDP 边界

管理命令会按 `users.txt` 重新生成 `/etc/socks5/config.yaml` 并逐字比对；直接加 `handler.metadata.udp: true` 会被判为“认证配置与 users.txt 不一致”，服务以退出码 78 拒绝启动。

需要 UDP ASSOCIATE 时，只能另行维护独立的 GOST 配置和服务（不通过 `socks5` 菜单管理），并放行 UDP 中继端口；`gost-routed` 已支持把 UDP 转发套接字绑定到选定出口。多出口模式不支持 BIND、MUX BIND 和 GOST 私有 UDP Tunnel。

## 6. 日常运维

### 6.1 状态与日志

```bash
sudo socks5 status
sudo socks5 info
sudo socks5 list
sudo journalctl -u socks5-proxy -n 200 --no-pager
```

### 6.2 用户与端口

- 菜单 7/8 或 `sudo socks5 add` / `sudo socks5 del`：增删用户会重建认证配置并重启服务（服务未运行也会被启动）；删除最后一个用户会停止服务。
- 菜单 11：修改端口会校验新配置、尝试放行防火墙、重启并确认新端口监听；失败恢复原端口。修改后同步客户端和云安全组。
- `sudo socks5 help`：查看命令帮助；无参数且非终端时也只打印帮助。

### 6.3 升级

```bash
sudo bash /etc/socks5/installer.sh upgrade              # 最新发布
sudo bash /etc/socks5/installer.sh upgrade latest       # 显式写法
sudo bash /etc/socks5/installer.sh upgrade '<https 地址|绝对路径>'
```

菜单 12 支持 https 地址或本地绝对路径（不自动解析 `latest`）。在线模式只接受 HTTPS，按当前架构匹配完整资产名；无资产或 API 限流时会提示改用显式地址。

### 6.4 卸载

```bash
sudo socks5 uninstall
```

会停止并删除服务、`gost`、`gost-routed`、`socks5` 命令和 `/etc/socks5`。卸载不会删除你手动备份的 `routes.conf.bak` 等文件；需要彻底清理时自行删除。

## 7. 故障排查

| 现象 | 可能原因 | 检查与处理 |
|---|---|---|
| `sudo bash <(curl ...)` 报 `/dev/fd/63: No such file or directory` | sudo 关闭了进程替换的 fd | 改用 `curl -fsSL https://.../install.sh \| sudo bash` |
| `bash: install.sh: No such file or directory` | 当前目录不是仓库根目录 | `cd` 到源码目录或使用绝对路径 |
| `请使用 root 权限运行` | 缺少 sudo | 安装、升级、改端口、改策略都需 root |
| `未找到已有安装，请先运行 bash install.sh` | 先执行了 upgrade | 先完成基础安装 |
| `未找到多出口组件 /usr/local/bin/gost-routed` | 未安装组件或路径错误 | 执行第 3.2 节 |
| `此 GOST 不支持路由文件校验` | 用原版 `gost` 冒充 | 重新安装构建的 `gost-routed` |
| `路由文件校验失败` | 策略语法错误、权限不足、重复用户名 | 查看命令输出并按第 5.1 节修正 |
| `expected username or ingress` | 首个非注释行不是 `username`/`ingress`，或拼写错误 | 修正首行 |
| 服务启动后立即退出，退出码 78 | 认证配置不一致、无有效用户、路由校验失败 | `sudo journalctl -u socks5-proxy -n 50`；`sudo socks5 restart` 查看前台错误 |
| `服务未监听预期端口` | 端口被占用或防火墙/监听失败 | `sudo ss -ltnp`；换端口或释放占用 |
| 认证失败（curl 返回 000/407） | 账号密码错误、用户被删、配置未同步 | `sudo socks5 list`；重新 `sudo socks5 add` |
| 出口不是预期 IP | IP 未配置在本机、云厂商 SNAT/NAT、反欺骗、DNAT | `ip -br addr`；`ip route get <目标> from <IP>`；核对云控制台 |
| SOCKS 状态码 8 / `has no IPv4 address` | 目标与源地址族不一致 | 使用同族目标或改用对应族的入口 |
| `bind: invalid argument` | 通过回环地址使用接入 IP 模式 | 改用 VPS 公网/业务内网地址连接 |
| 在线升级下载失败/限流/无资产 | 网络、GitHub API 限流、架构无发布资产 | 用显式 https 地址或本地构建包 |
| 菜单升级提示找不到安装脚本 | 旧安装缺少 `/etc/socks5/installer.sh` | 先执行一次命令行 `upgrade` 刷新脚本 |
| IPv6 入口连接失败 | 云安全组/`ip6tables` 未放行，或 VPS 无 IPv6 路由 | 放行 IPv6 端口；检查 `ip -6 addr` / `ip -6 route` |

## 8. 部署后功能校验清单

| 检查项 | 命令 | 预期 |
|---|---|---|
| 服务运行 | `systemctl is-active socks5-proxy` | `active` |
| 开机自启 | `systemctl is-enabled socks5-proxy` | `enabled` |
| 端口监听 | `sudo ss -ltnp \| grep ':<端口>'` | `LISTEN` |
| 基础认证 | 用新账号 `curl --socks5-hostname` 访问 `https://api.ipify.org` | 返回公网 IP |
| 旧凭据失效（重装场景） | 用旧账号连接 | 认证失败 |
| 组件版本 | `/usr/local/bin/gost-routed -V` | `gost 3.0.0-rc10 ...` |
| 路由契约 | `sudo env SOCKS5_ROUTE_CHECK=1 SOCKS5_ROUTE_FILE=/etc/socks5/routes.conf /usr/local/bin/gost-routed -V` | 无输出，退出码 0 |
| 策略权限 | `stat -c '%a %U' /etc/socks5/routes.conf` | `600 root` |
| 用户名出口 | 映射账号经回环连接 | 回显映射 IP |
| 未映射拒绝 | 未映射账号连接 | 失败/拒绝 |
| 接入 IP 出口 | 经入口 IP 连接 | 回显该入口 IP |
| IPv6 出口 | 经 IPv6 入口连接 `api64.ipify.org` | 回显 IPv6 |
| 跨地址族 | IPv4 出口访问 IPv6 字面地址 | SOCKS 状态码 8 |
| 默认回滚 | 移走 `routes.conf` 并重启 | 恢复系统默认出口 |
| 菜单状态/日志 | `sudo socks5` → 1 / 10 | 正常显示 |
| 端口修改 | 菜单 11 修改后改回 | 新端口监听，可恢复 |
| 独立更新 | `sudo bash /etc/socks5/installer.sh update-cli` | 成功，MainPID 不变 |
| 无旧残留 | `find /etc/socks5 /usr/local/bin -maxdepth 1 -name '*gost*'` | 只有当前安装的两个二进制 |

## 9. 文件、权限与端口速查

| 路径 | 权限 | 用途 |
|---|---|---|
| `/usr/local/bin/gost` | `755 root` | 原版 GOST |
| `/usr/local/bin/gost-routed` | `755 root` | 多出口组件 |
| `/usr/local/bin/socks5` | `755 root` | 管理命令 |
| `/etc/systemd/system/socks5-proxy.service` | `644 root` | systemd 服务 |
| `/etc/socks5` | `700 root` | 配置目录 |
| `/etc/socks5/config.yaml` | `600 root` | 由 `users.txt` 生成，勿手改 |
| `/etc/socks5/users.txt` | `600 root` | 用户名:密码 |
| `/etc/socks5/routes.conf` | `600 root` | 出口策略，可选 |
| `/etc/socks5/installer.sh` | `700 root` | 菜单升级使用的安装脚本副本 |
| `/etc/socks5/.lock` | `600 root` | 配置变更锁 |
