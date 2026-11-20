#!/usr/bin/env bash
#
# SOCKS5 一键部署脚本
# https://github.com/ca9oxa0/socks5-setup
#
# 用法:
#   安装:   bash <(curl -fsSL https://raw.githubusercontent.com/ca9oxa0/socks5-setup/main/install.sh)
#   升级:   sudo bash install.sh upgrade                    # 在线升级到最新发布
#           sudo bash install.sh upgrade <https://地址|绝对路径>
#   卸载:   socks5 uninstall
#   状态:   socks5 status
#   添加用户: socks5 add
#   删除用户: socks5 del
#   用户列表: socks5 list
#   重启服务: socks5 restart
#   查看信息: socks5 info

set -euo pipefail

# ============ 颜色 ============
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ============ 常量 ============
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/socks5"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
USERS_FILE="${CONFIG_DIR}/users.txt"
SERVICE_NAME="socks5-proxy"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
GOST_BIN="${INSTALL_DIR}/gost"
ROUTED_BIN="${INSTALL_DIR}/gost-routed"
SOCKS5_CMD="${INSTALL_DIR}/socks5"
GOST_VERSION="3.0.0-rc10"
GOST_REPO="https://github.com/go-gost/gost/releases/download/v${GOST_VERSION}"
# 在线升级只信任本仓库的发布信息；与脚本头部的部署地址保持一致。
PROJECT_SLUG="ca9oxa0/socks5-setup"
RELEASES_API="https://api.github.com/repos/${PROJECT_SLUG}/releases?per_page=30"
INSTALLER_URL="https://raw.githubusercontent.com/${PROJECT_SLUG}/main/install.sh"

# ============ 工具函数 ============
msg()   { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[✗]${NC} $*"; exit 1; }
info()  { echo -e "${CYAN}[i]${NC} $*"; }

check_root() {
    [[ $EUID -eq 0 ]] || err "请使用 root 权限运行此脚本 (sudo bash ...)"
}

# ============ 系统检测 ============
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_ID="${ID,,}"
        OS_VERSION="${VERSION_ID:-unknown}"
    elif command -v lsb_release &>/dev/null; then
        OS_ID="$(lsb_release -si | tr '[:upper:]' '[:lower:]')"
        OS_VERSION="$(lsb_release -sr)"
    elif [[ -f /etc/redhat-release ]]; then
        OS_ID="centos"
        OS_VERSION="$(grep -oP '[0-9]+' /etc/redhat-release | head -1)"
    else
        OS_ID="unknown"
        OS_VERSION="unknown"
    fi

    case "$OS_ID" in
        ubuntu|debian|linuxmint|pop) PKG_MGR="apt" ;;
        centos|rhel|rocky|alma|fedora|ol) PKG_MGR="yum" ;;
        alpine) PKG_MGR="apk" ;;
        arch|manjaro) PKG_MGR="pacman" ;;
        opensuse*|sles) PKG_MGR="zypper" ;;
        *) PKG_MGR="unknown" ;;
    esac

    info "检测到系统: ${OS_ID} ${OS_VERSION} (包管理器: ${PKG_MGR})"
}

detect_arch() {
    local arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64)  ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        armv7*|armhf)  ARCH="armv7" ;;
        i686|i386)     ARCH="386" ;;
        *) err "不支持的架构: $arch" ;;
    esac
    info "检测到架构: ${ARCH}"
}

# ============ 依赖安装 ============
install_deps() {
    info "安装必要依赖..."
    case "$PKG_MGR" in
        apt)
            apt-get update -qq
            apt-get install -y -qq curl wget tar gzip >/dev/null 2>&1
            ;;
        yum)
            yum install -y -q curl wget tar gzip >/dev/null 2>&1
            ;;
        apk)
            apk add --no-cache curl wget tar gzip >/dev/null 2>&1
            ;;
        pacman)
            pacman -Sy --noconfirm curl wget tar gzip >/dev/null 2>&1
            ;;
        zypper)
            zypper install -y -q curl wget tar gzip >/dev/null 2>&1
            ;;
        *)
            warn "未知包管理器，请确保已安装 curl wget tar"
            ;;
    esac
    msg "依赖安装完成"
}

# ============ 获取公网 IP ============
get_public_ip() {
    local ip=""
    for url in "https://api.ipify.org" "https://ifconfig.me" "https://icanhazip.com" "https://ip.sb"; do
        ip="$(curl -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')" && [[ -n "$ip" ]] && break
    done
    [[ -z "$ip" ]] && ip="$(hostname -I | awk '{print $1}')"
    echo "$ip"
}

# ============ 随机生成 ============
rand_port() {
    shuf -i 10000-65000 -n 1
}

rand_str() {
    local len="${1:-8}"
    head -c 256 /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c "$len" || true
}

# ============ 防火墙 ============
configure_firewall() {
    local port="$1"
    info "配置防火墙 (端口: ${port})..."

    # ufw
    if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
        ufw allow "$port"/tcp >/dev/null 2>&1
        msg "ufw 已放行端口 ${port}"
        return
    fi

    # firewalld
    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
        msg "firewalld 已放行端口 ${port}"
        return
    fi

    # iptables
    if command -v iptables &>/dev/null; then
        if ! iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
            iptables -I INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null
            # 保存规则
            if command -v iptables-save &>/dev/null; then
                iptables-save > /etc/iptables.rules 2>/dev/null || true
            fi
            msg "iptables 已放行端口 ${port}"
        fi
        return
    fi

    warn "未检测到活跃的防火墙，跳过配置"
}

remove_firewall_rule() {
    local port="$1"
    if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
        ufw delete allow "$port"/tcp >/dev/null 2>&1 || true
    fi
    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --remove-port="${port}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
    if command -v iptables &>/dev/null; then
        iptables -D INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
    fi
}

# ============ systemd 服务 ============
write_service() {
    cat > "$1" <<EOF
[Unit]
Description=SOCKS5 Proxy Service (gost)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${SOCKS5_CMD} _serve
Restart=always
RestartPreventExitStatus=78
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
}

# ============ 管理命令与服务入口 ============
write_socks5_cmd() {
    cat > "$1" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="/etc/socks5"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
USERS_FILE="${CONFIG_DIR}/users.txt"
ROUTE_FILE="${CONFIG_DIR}/routes.conf"
SERVICE_NAME="socks5-proxy"
GOST_BIN="/usr/local/bin/gost"
ROUTED_BIN="/usr/local/bin/gost-routed"
umask 077

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
msg()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }
info() { echo -e "${CYAN}[i]${NC} $*"; }
# 文字进度条只反映真实阶段，不做计时动画。
step() {
    local n="$1" total="$2" label="$3" bar="" i
    for ((i=1; i<=total; i++)); do
        if (( i <= n )); then bar+='='; else bar+='-'; fi
    done
    info "[${bar}] ${n}/${total} ${label}"
}

[[ $EUID -eq 0 ]] || err "请使用 root 权限运行"

get_port() { sed -nE 's/^[[:space:]]*(# )?addr:[[:space:]]*"?:([0-9]+)"?[[:space:]]*$/\2/p' "$CONFIG_FILE"; }
valid_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }

# JSON 风格双引号是合法的 YAML 字符串，必须逐字转义凭据。
yaml_string() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\xc2\x85'/\\u0085}
    value=${value//$'\xe2\x80\xa8'/\\u2028}
    value=${value//$'\xe2\x80\xa9'/\\u2029}
    printf '"%s"' "$value"
}

valid_user() {
    local LC_ALL=C
    [[ -n "$1" && -n "$2" && "$1" != *:* && "$1$2" != *[[:cntrl:]]* && ${#1} -le 255 && ${#2} -le 255 ]]
}

generate_config() {
    local port="$1" line user pass
    valid_port "$port" || err "配置中的端口无效"
    [[ -f "$2" && -r "$2" ]] || err "找不到或无法读取 users.txt"
    if ! awk -F: 'length($0) && seen["u" $1]++ { exit 1 }' "$2"; then
        err "users.txt 中存在重复用户名或无法读取"
    fi
    if ! grep -q '.' "$2"; then
        # 空用户配置即使绕过服务入口也不包含任何监听器。
        printf '# addr: ":%s"\nservices: []\n' "$port"
        return
    fi
    cat <<YAML
services:
- name: socks5-service
  addr: ":${port}"
  handler:
    type: socks5
    auther: socks5-users
  listener:
    type: tcp

authers:
- name: socks5-users
  auths:
YAML
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        user=${line%%:*}
        pass=${line#*:}
        if [[ "$line" != *:* ]] || ! valid_user "$user" "$pass"; then
            err "users.txt 中存在无效凭据"
        fi
        printf '  - username: %s\n    password: %s\n' "$(yaml_string "$user")" "$(yaml_string "$pass")"
    done < "$2"
}

has_users() { [[ -s "$USERS_FILE" ]] && LC_ALL=C grep -q '^.\+:.' "$USERS_FILE"; }

has_policy() { [[ -e "$ROUTE_FILE" || -L "$ROUTE_FILE" ]]; }

check_route() {
    local bin="$1" route="${2:-$ROUTE_FILE}" output
    [[ -e "$route" || -L "$route" ]] || return 0
    [[ -f "$route" && -r "$route" ]] || err "无法读取路由文件 ${route}"
    [[ -x "$bin" ]] || err "未找到多出口组件 ${bin}；请先运行 sudo bash install.sh upgrade（在线）或指定本地包"
    # 使用 -V 防止误启动原版二进制；自定义版校验成功后先于 -V 退出。
    if ! output=$(SOCKS5_ROUTE_CHECK=1 SOCKS5_ROUTE_FILE="$route" "$bin" -V 2>&1); then
        [[ -z "$output" ]] || printf '%s\n' "$output" >&2
        err "路由文件校验失败"
    fi
    [[ -z "$output" ]] || err "此 GOST 不支持路由文件校验，请使用构建脚本生成的二进制"
}

get_public_ip() {
    local ip=""
    for url in "https://api.ipify.org" "https://ifconfig.me" "https://icanhazip.com"; do
        ip="$(curl -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')" && [[ -n "$ip" ]] && break
    done
    [[ -z "$ip" ]] && ip="$(hostname -I | awk '{print $1}')"
    echo "$ip"
}

rand_str() { head -c 256 /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c "${1:-8}" || true; }
check_service() {
    check_auth_config
    check_route "$ROUTED_BIN"
}

check_auth_config() {
    local expected
    # GOST 可将空认证表视作未启用认证；此时不启动任何监听器。
    has_users || { warn "没有有效用户，拒绝启动"; exit 78; }
    expected=$(generate_config "$(get_port)" "$USERS_FILE") || exit 78
    printf '%s\n' "$expected" | cmp -s - "$CONFIG_FILE" || err "认证配置与 users.txt 不一致"
}

start_service() {
    local verb="$1" port pid attempt listeners
    port=$(get_port)
    valid_port "$port" || return 1
    systemctl "$verb" "$SERVICE_NAME" || return 1
    # Type=simple 在 GOST 绑定端口前可能已经返回成功。
    for ((attempt=0; attempt<30; attempt++)); do
        systemctl is-active --quiet "$SERVICE_NAME" || return 1
        pid=$(systemctl show -p MainPID "$SERVICE_NAME") || return 1
        pid=${pid#MainPID=}
        listeners=$(ss -H -ltnp "sport = :$port") || return 1
        if [[ "$pid" =~ ^[1-9][0-9]*$ && "$listeners" == *"pid=$pid,"* ]]; then
            return 0
        fi
        sleep 0.1
    done
    return 1
}

update_users() {
    local work="$1" was_active=0 empty=0
    generate_config "$(get_port)" "$work/users" > "$work/config"
    if grep -Fxq 'services: []' "$work/config"; then
        empty=1
    else
        check_route "$ROUTED_BIN"
    fi
    if systemctl is-active --quiet "$SERVICE_NAME"; then was_active=1; fi
    cp -p -- "$USERS_FILE" "$work/old-users"
    cp -p -- "$CONFIG_FILE" "$work/old-config"
    if (( empty )); then
        systemctl stop "$SERVICE_NAME"
    fi
    if mv -f -- "$work/users" "$USERS_FILE" && mv -f -- "$work/config" "$CONFIG_FILE" &&
        { (( empty )) || start_service restart; }; then
        if (( empty )); then warn "已无用户，服务已停止"; fi
        return 0
    fi

    warn "更改未能应用，正在恢复用户和配置"
    systemctl stop "$SERVICE_NAME" || true
    mv -f -- "$work/old-users" "$USERS_FILE"
    mv -f -- "$work/old-config" "$CONFIG_FILE"
    if (( was_active )); then start_service start || warn "无法恢复服务，请检查路由文件和服务日志"; fi
    err "更新用户失败"
}

show_info() {
    local ip port
    ip="$(get_public_ip)"
    port="$(get_port)"
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════${NC}"
    echo -e "${BOLD}       SOCKS5 节点信息${NC}"
    echo -e "${BOLD}═══════════════════════════════════════${NC}"
    echo -e " 服务器: ${CYAN}${ip}${NC}"
    echo -e " 端口:   ${CYAN}${port}${NC}"
    echo ""
    echo -e " ${BOLD}连接链接:${NC}"
    while IFS=: read -r user pass; do
        [[ -z "$user" ]] && continue
        echo -e "  ${GREEN}socks5://${user}:${pass}@${ip}:${port}${NC}"
    done < "$USERS_FILE"
    echo -e "${BOLD}═══════════════════════════════════════${NC}"
    echo ""
}

config_lock() {
    exec 9>>"$CONFIG_DIR/.lock"
    flock -x 9
}

confirm_action() {
    local answer
    while IFS= read -rp "确认$1? (y/N): " answer; do
        case "${answer,,}" in
            y|yes) return 0 ;;
            ''|n|no) break ;;
            *) warn "请输入 y 或 n" ;;
        esac
    done
    info "已取消"
    return 1
}

read_users() {
    local line
    users=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == ?*:* ]] && users+=("${line%%:*}")
    done < "$1"
}

print_users() {
    local i
    info "当前用户列表:"
    for i in "${!users[@]}"; do printf '  %d) %s\n' "$((i+1))" "${users[i]}"; done
    if (( ${#users[@]} == 0 )); then warn "没有用户"; fi
}

add_user() {
    local menu="${1:-}" new_user new_pass line port ip work
    while :; do
        IFS= read -rp "用户名 (回车随机): " new_user || return 0
        if [[ -z "$new_user" ]]; then new_user="user_$(rand_str 4)"; fi
        IFS= read -rsp "密码 (回车随机): " new_pass || { if [[ -t 0 ]]; then printf '\n'; fi; return 0; }
        if [[ -t 0 ]]; then printf '\n'; fi
        if [[ -z "$new_pass" ]]; then new_pass="$(rand_str 12)"; fi
        if valid_user "$new_user" "$new_pass"; then break; fi
        if [[ "$menu" != menu ]]; then err "凭据无效：用户名不能包含冒号，凭据不能含控制字符或超过 255 字节"; fi
        warn "凭据无效：用户名不能包含冒号，凭据不能含控制字符或超过 255 字节"
    done
    if [[ "$menu" == menu ]]; then
        printf '将添加用户: %s\n' "$new_user"
        confirm_action "添加用户" || return 0
        step 1 2 "获取配置锁并准备用户配置"
    fi
    config_lock
    work=$(mktemp -d "$CONFIG_DIR/.users.XXXXXX")
    trap 'rm -rf -- "$work"' EXIT
    { while IFS= read -r line || [[ -n "$line" ]]; do printf '%s\n' "$line"; done < "$USERS_FILE"
      printf '%s:%s\n' "$new_user" "$new_pass"; } > "$work/users"
    if [[ "$menu" == menu ]]; then step 2 2 "应用配置并验证服务"; fi
    update_users "$work"
    port="$(get_port)"
    exec 9>&-
    msg "用户已添加"
    if [[ "$menu" != menu ]]; then
        ip="$(get_public_ip)"
        printf '  %b%s%b\n' "$GREEN" "socks5://${new_user}:${new_pass}@${ip}:${port}" "$NC"
    fi
    # EXIT trap 不能引用已经离开作用域的局部变量。
    rm -rf -- "$work"
    trap - EXIT
}

delete_user() {
    local menu="${1:-}" del_user choice before work line found=0
    local -a users=()
    if [[ "$menu" == menu ]]; then
        config_lock
        before=$(sha256sum -- "$USERS_FILE")
        read_users "$USERS_FILE"
        exec 9>&-
    else
        read_users "$USERS_FILE"
    fi
    print_users
    if (( ${#users[@]} == 0 )); then return 0; fi
    if [[ "$menu" == menu ]]; then
        while :; do
            IFS= read -rp "选择用户编号 (0 返回): " choice || return 0
            [[ "$choice" != 0 ]] || return 0
            if [[ "$choice" =~ ^[1-9][0-9]{0,8}$ ]] && (( choice <= ${#users[@]} )); then break; fi
            warn "无效的用户编号"
        done
        del_user=${users[choice-1]}
        printf '将删除用户: %s\n' "$del_user"
        if (( ${#users[@]} == 1 )); then warn "这是最后一个用户，删除后服务将停止"; fi
        confirm_action "删除用户" || return 0
        step 1 2 "获取配置锁并检查用户列表"
    else
        IFS= read -rp "输入要删除的用户名: " del_user || return 0
        [[ -n "$del_user" ]] || err "请输入用户名"
    fi
    config_lock
    if [[ "$menu" == menu ]]; then
        [[ "$(sha256sum -- "$USERS_FILE")" == "$before" ]] || err "用户列表已变化，请重新选择"
    fi
    work=$(mktemp -d "$CONFIG_DIR/.users.XXXXXX")
    trap 'rm -rf -- "$work"' EXIT
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "${line%%:*}" == "$del_user" ]]; then found=1; else printf '%s\n' "$line"; fi
    done < "$USERS_FILE" > "$work/users"
    (( found )) || err "用户名不存在"
    if [[ "$menu" == menu ]]; then step 2 2 "应用配置并验证服务"; fi
    update_users "$work"
    printf '用户 %s 已删除\n' "$del_user"
    rm -rf -- "$work"
    trap - EXIT
}

menu_action() {
    case "$1" in
        add) add_user menu ;;
        del) delete_user menu ;;
        users) local -a users=(); read_users "$USERS_FILE"; print_users ;;
        start|stop|restart)
            local verb="$1" label
            case "$verb" in start) label=启动服务 ;; stop) label=停止服务 ;; restart) label=重启服务 ;; esac
            confirm_action "$label" || return 0
            step 1 2 "执行${label}"
            bash "${BASH_SOURCE[0]}" "$verb" || return 1
            step 2 2 "操作完成"
            ;;
        *) return 1 ;;
    esac
}

# 当前策略的首个有效行；文件不存在表示系统默认选路。
route_mode() {
    if has_policy; then
        awk 'NF && $1 !~ /^#/ { print $1; exit }' "$ROUTE_FILE" 2>/dev/null
    else
        echo default
    fi
}

route_show() {
    local mode
    mode=$(route_mode)
    case "$mode" in
        ingress)
            info "当前策略：按接入 IP 绑定出口（ingress）"
            ;;
        username)
            info "当前策略：按用户名绑定出口（username）"
            local line
            while IFS= read -r line || [[ -n "$line" ]]; do
                [[ -z "$line" || "${line:0:1}" == "#" || "$line" == username ]] && continue
                printf '  %s\n' "$line"
            done < "$ROUTE_FILE"
            ;;
        default) info "当前策略：系统默认选路（未绑定出口）" ;;
        *) warn "当前策略文件格式未知：${mode:-空}" ;;
    esac
    if [[ "$mode" != default ]]; then
        warn "策略需要自定义 GOST；未映射用户或绑定失败时请求会被拒绝"
    fi
}

route_stamp() {
    if has_policy; then sha256sum -- "$ROUTE_FILE"; else echo absent; fi
}

# 事务在子 shell 中执行：失败只影响本次操作，不退出菜单。
# 返回 2 表示用户取消，其余非零为失败。
route_apply() (
    local mode="$1" policy="$2" work old existed=0 active=0 line
    work=$(mktemp -d "$CONFIG_DIR/.route.XXXXXX") || { warn "无法创建临时目录"; exit 1; }
    trap 'rm -rf -- "$work"' EXIT
    printf '%s' "$policy" > "$work/routes"
    chmod 600 "$work/routes"
    if has_policy; then cp -p -- "$ROUTE_FILE" "$work/old"; existed=1; fi

    step 1 4 "校验出口策略"
    if [[ "$mode" != default ]]; then
        check_route "$ROUTED_BIN" "$work/routes"
    fi

    printf '\n策略预览（%s）：\n' "$mode"
    while IFS= read -r line || [[ -n "$line" ]]; do printf '  %s\n' "$line"; done < "$work/routes"
    if [[ "$mode" == username ]]; then
        warn "策略中未列出的用户将无法转发"
    fi
    confirm_action "应用出口策略" || exit 2

    step 2 4 "获取配置锁并确认配置未变化"
    local users_before route_before
    users_before=$(sha256sum -- "$USERS_FILE")
    route_before=$(route_stamp)
    config_lock
    [[ "$(sha256sum -- "$USERS_FILE")" == "$users_before" && "$(route_stamp)" == "$route_before" ]] ||
        err "用户或策略已被修改，请重新选择"

    step 3 4 "备份并应用策略"
    if [[ "$mode" == default ]]; then
        rm -f -- "$ROUTE_FILE"
    else
        mv -fT -- "$work/routes" "$ROUTE_FILE"
        check_route "$ROUTED_BIN" "$ROUTE_FILE"
    fi

    systemctl is-active --quiet "$SERVICE_NAME" && active=1
    if (( active )); then
        step 4 4 "重启服务并确认端口监听"
        if ! start_service restart; then
            warn "应用后服务未能监听，正在恢复原策略"
            if (( existed )); then
                mv -fT -- "$work/old" "$ROUTE_FILE"
            else
                rm -f -- "$ROUTE_FILE"
            fi
            if ! start_service restart; then
                trap - EXIT
                err "回滚后服务仍无法启动；原策略保留在 $work，请查看 journalctl -u $SERVICE_NAME"
            fi
            err "策略未生效，已恢复原策略和服务状态"
        fi
    else
        info "服务当前未运行，策略已保存；启动服务后生效"
    fi
    trap - EXIT
    rm -rf -- "$work"
    msg "出口策略已应用"
)

route_menu() {
    local choice action mode ip user rc=0
    local -a users=()
    if [[ ! -x "$ROUTED_BIN" ]]; then
        warn "未安装多出口组件（${ROUTED_BIN}），出口策略无法生效"
        warn "安装方法：sudo bash install.sh upgrade（在线）或指定本地包"
    fi
    while :; do
        printf '\n出口配置\n'
        route_show
        printf '%s\n' '  1) 系统默认   2) 按接入 IP   3) 按用户名' \
            '  4) 查看当前   0) 返回'
        IFS= read -rp "请选择 [0-4]: " choice || return 0
        action="$choice"
        case "$choice" in
            0) return 0 ;;
            4) continue ;;
            1)
                if route_apply default ""; then continue; else rc=$?; fi
                ;;
            2)
                if route_apply ingress $'ingress\n'; then continue; else rc=$?; fi
                ;;
            3)
                read_users "$USERS_FILE"
                local -a lines=()
                for user in "${users[@]}"; do
                    while :; do
                        IFS= read -rp "${user} 的出口 IP (回车跳过该用户): " ip || return 0
                        ip=${ip//[[:space:]]/}
                        [[ -n "$ip" ]] || break
                        if [[ "$ip" == *[=\#]* ]]; then
                            warn "IP 不能包含 = 或 #，请重新输入"
                            continue
                        fi
                        lines+=("${user}=${ip}")
                        break
                    done
                done
                if (( ${#lines[@]} == 0 )); then
                    warn "未填写任何映射，请重新选择"
                    continue
                fi
                mode=$'username\n'
                for ip in "${lines[@]}"; do mode+="${ip}"$'\n'; done
                if route_apply username "$mode"; then continue; else rc=$?; fi
                ;;
            *) warn "无效的选项"; continue ;;
        esac
        (( rc == 2 )) && continue
        printf '%s\n' '  1) 重试  0) 返回'
        IFS= read -rp "请选择 [0-1]: " choice || return 0
        [[ "$choice" == 1 ]] || continue
        case "$action" in
            1) route_apply default "" || true ;;
            2) route_apply ingress $'ingress\n' || true ;;
            3) route_apply username "$mode" || true ;;
        esac
    done
}

# 每次操作由独立脚本进程执行，菜单中的条件判断不会禁用子进程的 errexit。
menu_run() {
    local retry rc
    while :; do
        if bash "${BASH_SOURCE[0]}" "$@"; then return 0; else rc=$?; fi
        if [[ "$1" == status && "$rc" == 3 ]]; then return 0; fi
        warn "操作失败 (退出状态 $rc)"
        printf '  1) 重试  0) 返回\n'
        while IFS= read -rp "请选择 [0-1]: " retry; do
            case "$retry" in
                1) break ;;
                ''|0) return 0 ;;
                *) warn "无效的选项" ;;
            esac
        done
        [[ "$retry" == 1 ]] || return 0
    done
}

# 查看服务日志；journalctl 不可用时给出明确提示，不退出菜单。
logs_menu() {
    local choice lines
    while :; do
        printf '\n查看日志\n%s\n' '  1) 最近 50 行   2) 最近 200 行   0) 返回'
        IFS= read -rp "请选择 [0-2]: " choice || return 0
        case "$choice" in
            0) return 0 ;;
            1) lines=50 ;;
            2) lines=200 ;;
            *) warn "无效的选项"; continue ;;
        esac
        info "最近 ${lines} 行日志："
        journalctl -u "$SERVICE_NAME" -n "$lines" --no-pager -o cat || warn "无法读取日志，请确认 journalctl 可用"
    done
}

open_port() {
    local port="$1"
    if command -v ufw >/dev/null 2>&1; then ufw allow "$port"/tcp >/dev/null 2>&1 || true; fi
    if command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
    if command -v iptables >/dev/null 2>&1; then
        iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null ||
            iptables -I INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
    fi
}

# 事务在子 shell 中执行，失败不会退出菜单；返回 2 表示取消。
port_apply() (
    local current cur new work active=0 users_before port_before
    current=$(get_port)
    cur=${current:-0}
    info "当前端口：${current:-未知}"
    while :; do
        IFS= read -rp "新端口 (1-65535，回车取消): " new || exit 2
        [[ -n "$new" ]] || exit 2
        if ! valid_port "$new"; then warn "端口必须是 1-65535 的数字"; continue; fi
        new=$((10#$new))
        if (( new == 10#$cur )); then info "端口未变化"; exit 2; fi
        break
    done
    if ss -H -ltn "sport = :$new" 2>/dev/null | grep -q ":${new}[[:space:]]"; then
        err "端口 ${new} 已被占用，请选择其他端口"
    fi
    printf '将把端口从 %s 改为 %s。\n' "$current" "$new"
    confirm_action "修改端口" || exit 2
    step 1 4 "生成并校验新配置"
    work=$(mktemp -d "$CONFIG_DIR/.port.XXXXXX") || err "无法创建临时目录"
    trap 'rm -rf -- "$work"' EXIT
    bash "${BASH_SOURCE[0]}" _generate "$new" "$USERS_FILE" > "$work/config" || err "生成配置失败"
    step 2 4 "获取配置锁并确认配置未变化"
    users_before=$(sha256sum -- "$USERS_FILE")
    port_before=$(get_port)
    config_lock
    [[ "$(sha256sum -- "$USERS_FILE")" == "$users_before" && "$(get_port)" == "$port_before" ]] ||
        err "用户或端口已被修改，请重新选择"
    cp -p -- "$CONFIG_FILE" "$work/old-config"
    step 3 4 "应用端口并放行防火墙"
    install -m 600 -- "$work/config" "$CONFIG_FILE"
    open_port "$new"
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        step 4 4 "重启服务并确认新端口监听"
        if ! start_service restart; then
            install -m 600 -- "$work/old-config" "$CONFIG_FILE"
            if ! start_service restart; then
                trap - EXIT
                err "回滚后服务仍无法启动；原配置保留在 $work"
            fi
            err "端口修改未生效，已恢复原端口"
        fi
    else
        info "服务当前未运行，端口已保存；启动服务后生效"
    fi
    trap - EXIT
    rm -rf -- "$work"
    msg "端口已修改为 $new；请同步更新客户端配置"
)

port_menu() {
    local rc choice
    while :; do
        if port_apply; then return 0; else rc=$?; fi
        (( rc == 2 )) && return 0
        printf '  1) 重试  0) 返回\n'
        IFS= read -rp "请选择 [0-1]: " choice || return 0
        [[ "$choice" == 1 ]] || return 0
    done
}

upgrade_menu() {
    local installer="$CONFIG_DIR/installer.sh" path choice
    local version routed_version
    if [[ ! -r "$installer" ]]; then
        warn "未找到本地安装脚本；请在源码目录运行 sudo bash install.sh upgrade /绝对路径/gost-routed"
        return 0
    fi
    version=$("$GOST_BIN" -V 2>/dev/null) || version=未知
    info "当前版本：${version}"
    if [[ -x "$ROUTED_BIN" ]]; then
        routed_version=$("$ROUTED_BIN" -V 2>/dev/null) || routed_version=未知
        info "自定义版本：${routed_version}"
    fi
    while :; do
        IFS= read -rp "升级包地址（https 或绝对路径，回车取消）: " path || return 0
        [[ -n "$path" ]] || return 0
        if [[ "$path" == https://* ]]; then break; fi
        if [[ "$path" == http://* ]]; then warn "仅支持 https 下载"; continue; fi
        if [[ "$path" != /* ]]; then warn "请输入 https 地址或绝对路径"; continue; fi
        if [[ ! -f "$path" || ! -r "$path" ]]; then warn "文件不存在或不可读"; continue; fi
        break
    done
    printf '将使用 %s 升级，保留端口和用户。\n' "$path"
    confirm_action "升级 GOST" || return 0
    while :; do
        if bash "$installer" upgrade "$path"; then return 0; fi
        printf '  1) 重试  0) 返回\n'
        IFS= read -rp "请选择 [0-1]: " choice || return 0
        [[ "$choice" == 1 ]] || return 0
    done
}

show_menu() {
    local choice active port
    [[ -t 0 && -t 1 ]] || err "管理菜单需要交互式终端，请使用 socks5 help 查看命令"
    while :; do
        active=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null) || true
        port=$(get_port 2>/dev/null) || true
        printf '\nSOCKS5 管理菜单  |  服务: %s  |  端口: %s\n' "${active:-未知}" "${port:-未知}"
        printf '%s\n' '  1) 状态   2) 连接信息   3) 用户列表' \
            '  4) 启动   5) 停止       6) 重启' \
            '  7) 添加   8) 删除       9) 出口配置' \
            ' 10) 查看日志  11) 修改端口  12) 升级' \
            ' 13) 卸载   0) 退出'
        IFS= read -rp "请选择 [0-13]: " choice || return 0
        case "$choice" in
            0) return 0 ;;
            1) menu_run status ;;
            2) menu_run info ;;
            3) menu_run _menu_action users ;;
            4) menu_run _menu_action start ;;
            5) menu_run _menu_action stop ;;
            6) menu_run _menu_action restart ;;
            7) menu_run _menu_action add ;;
            8) menu_run _menu_action del ;;
            9) route_menu ;;
            10) logs_menu ;;
            11) port_menu ;;
            12) upgrade_menu ;;
            13) menu_run uninstall; if [[ ! -d "$CONFIG_DIR" ]]; then return 0; fi ;;
            *) warn "无效的选项" ;;
        esac
    done
}

if (( $# == 0 )) && [[ -t 0 && -t 1 ]]; then set -- menu; fi
case "${1:-help}" in
    menu) show_menu ;;
    _menu_action) menu_action "$2" ;;
    _generate) generate_config "$2" "$3" ;;
    _port) get_port ;;
    _route_check) check_route "$2" "${3:-}" ;;
    _check) check_service ;;
    _start) start_service start ;;
    _restart) start_service restart ;;
    _serve)
        ( check_service ) || exit 78
        unset SOCKS5_ROUTE_CHECK SOCKS5_ROUTE_FILE
        if has_policy; then
            export SOCKS5_ROUTE_FILE="$ROUTE_FILE"
            exec "$ROUTED_BIN" -C "$CONFIG_FILE"
        fi
        exec "$GOST_BIN" -C "$CONFIG_FILE"
        ;;
    status)
        systemctl status "$SERVICE_NAME" --no-pager
        ;;
    restart)
        exec 9>"$CONFIG_DIR/.lock"
        flock -x 9
        check_service
        start_service restart || err "服务未监听预期端口，请查看服务日志"
        msg "服务已重启"
        ;;
    stop)
        systemctl stop "$SERVICE_NAME"
        msg "服务已停止"
        ;;
    start)
        exec 9>"$CONFIG_DIR/.lock"
        flock -x 9
        check_service
        start_service start || err "服务未监听预期端口，请查看服务日志"
        msg "服务已启动"
        ;;
    info)
        show_info
        ;;
    add)
        read -rp "用户名 (回车随机): " new_user
        [[ -z "$new_user" ]] && new_user="user_$(rand_str 4)"
        read -rp "密码 (回车随机): " new_pass
        [[ -z "$new_pass" ]] && new_pass="$(rand_str 12)"
        valid_user "$new_user" "$new_pass" || err "凭据无效：用户名不能包含冒号，凭据不能含控制字符或超过 255 字节"
        exec 9>"$CONFIG_DIR/.lock"
        flock -x 9
        work=$(mktemp -d "$CONFIG_DIR/.users.XXXXXX")
        trap 'rm -rf -- "$work"' EXIT
        { while IFS= read -r line || [[ -n "$line" ]]; do printf '%s\n' "$line"; done < "$USERS_FILE"
          printf '%s:%s\n' "$new_user" "$new_pass"; } > "$work/users"
        update_users "$work"
        _ip="$(get_public_ip)"
        _port="$(get_port)"
        msg "用户已添加"
        echo -e "  ${GREEN}socks5://${new_user}:${new_pass}@${_ip}:${_port}${NC}"
        ;;
    del)
        if [[ ! -s "$USERS_FILE" ]]; then
            warn "没有用户可删除"
            exit 0
        fi
        echo ""
        info "当前用户列表:"
        _i=1
        while IFS=: read -r user pass; do
            [[ -z "$user" ]] && continue
            echo "  ${_i}) ${user}"
            ((_i++))
        done < "$USERS_FILE"
        echo ""
        read -rp "输入要删除的用户名: " del_user
        [[ -n "$del_user" ]] || err "请输入用户名"
        exec 9>"$CONFIG_DIR/.lock"
        flock -x 9
        work=$(mktemp -d "$CONFIG_DIR/.users.XXXXXX")
        trap 'rm -rf -- "$work"' EXIT
        found=0
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "${line%%:*}" == "$del_user" ]]; then
                found=1
            else
                printf '%s\n' "$line"
            fi
        done < "$USERS_FILE" > "$work/users"
        (( found )) || err "用户名不存在"
        update_users "$work"
        msg "用户 ${del_user} 已删除"
        ;;
    list)
        echo ""
        info "当前用户列表:"
        _ip="$(get_public_ip)"
        _port="$(get_port)"
        while IFS=: read -r user pass; do
            [[ -z "$user" ]] && continue
            echo -e "  ${CYAN}${user}${NC} -> socks5://${user}:${pass}@${_ip}:${_port}"
        done < "$USERS_FILE"
        echo ""
        ;;
    uninstall)
        echo ""
        warn "即将卸载 SOCKS5 代理服务"
        read -rp "确认卸载? (y/N): " confirm
        if [[ "${confirm,,}" == "y" ]]; then
            _port="$(get_port)" 2>/dev/null || _port=""
            systemctl stop "$SERVICE_NAME" 2>/dev/null || true
            systemctl disable "$SERVICE_NAME" 2>/dev/null || true
            rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
            systemctl daemon-reload
            rm -f "$GOST_BIN" "$ROUTED_BIN"
            rm -rf "$CONFIG_DIR"
            # 清理防火墙
            if [[ -n "${_port:-}" ]]; then
                if command -v ufw &>/dev/null; then ufw delete allow "$_port"/tcp 2>/dev/null || true; fi
                if command -v firewall-cmd &>/dev/null; then
                    firewall-cmd --permanent --remove-port="${_port}/tcp" 2>/dev/null || true
                    firewall-cmd --reload 2>/dev/null || true
                fi
                if command -v iptables &>/dev/null; then
                    iptables -D INPUT -p tcp --dport "$_port" -j ACCEPT 2>/dev/null || true
                fi
            fi
            rm -f "/usr/local/bin/socks5"
            msg "卸载完成"
        else
            info "已取消"
        fi
        ;;
    *)
        echo ""
        echo -e "${BOLD}SOCKS5 管理工具${NC}"
        echo ""
        echo "  socks5            打开交互菜单（终端）"
        echo "  socks5 menu       打开交互菜单"
        echo "  socks5 info       查看连接信息"
        echo "  socks5 status     查看服务状态"
        echo "  socks5 start      启动服务"
        echo "  socks5 stop       停止服务"
        echo "  socks5 restart    重启服务"
        echo "  socks5 add        添加用户"
        echo "  socks5 del        删除用户"
        echo "  socks5 list       用户列表"
        echo "  socks5 uninstall  卸载"
        echo ""
        ;;
esac
SCRIPT
    chmod 755 "$1"
}

# ============ 下载 gost ============
download_gost() {
    info "下载 gost v${GOST_VERSION} (${ARCH})..."
    local filename="gost_${GOST_VERSION}_linux_${ARCH}.tar.gz"
    local url="${GOST_REPO}/${filename}"
    local tmp_dir
    tmp_dir="$(mktemp -d)"

    if ! curl -fsSL --retry 3 --connect-timeout 10 -o "${tmp_dir}/${filename}" "$url"; then
        err "下载失败，请检查网络连接后重试"
    fi

    tar -xzf "${tmp_dir}/${filename}" -C "${tmp_dir}"
    cp "${tmp_dir}/gost" "$GOST_BIN"
    chmod +x "$GOST_BIN"
    rm -rf "$tmp_dir"
    msg "gost 下载完成"
}

# ============ 单独更新管理命令 ============
do_update_cli() (
    check_root
    [[ $# -eq 0 ]] || err "用法：sudo bash install.sh update-cli"
    [[ -d "$CONFIG_DIR" && -x "$SOCKS5_CMD" ]] || err "未找到可更新的 SOCKS5 安装"
    umask 077
    exec 9>"$CONFIG_DIR/.lock"
    flock -x 9
    [[ -f "$CONFIG_FILE" && -f "$USERS_FILE" && -f "$SERVICE_FILE" ]] &&
        grep -Fxq "ExecStart=${SOCKS5_CMD} _serve" "$SERVICE_FILE" ||
        err "当前安装不支持单独更新菜单，请使用原地升级"

    local candidate port
    candidate=$(mktemp "${SOCKS5_CMD}.update.XXXXXX")
    trap 'rm -f -- "$candidate"' EXIT
    write_socks5_cmd "$candidate"
    bash -n "$candidate" || err "新管理脚本语法检查失败，未替换原文件"
    port=$(bash "$candidate" _port) || err "无法读取现有端口，未替换原文件"
    [[ "$port" =~ ^[0-9]{1,5}$ ]] && (( 10#$port >= 1 && 10#$port <= 65535 )) ||
        err "现有端口无效，未替换原文件"
    mv -fT -- "$candidate" "$SOCKS5_CMD"
    msg "管理菜单已更新，未重启服务。运行 sudo socks5 打开菜单。"
)

# 保存安装脚本副本供管理菜单复用。通过管道运行时（$0 为 /dev/fd/*），
# 改为下载最新脚本；只有语法和入口标记完整时才覆盖，避免保存截断内容。
save_installer() {
    local source_path="$0" tmp
    case "$source_path" in
        /dev/fd/*|/proc/*|"") ;;
        *)
            if [[ -f "$source_path" && -r "$source_path" ]]; then
                install -m 700 -- "$source_path" "$CONFIG_DIR/installer.sh" 2>/dev/null || true
                return 0
            fi
            ;;
    esac
    command -v curl >/dev/null 2>&1 || return 0
    tmp=$(mktemp "${CONFIG_DIR}/.installer.XXXXXX") || return 0
    if curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 60 \
        -o "$tmp" "$INSTALLER_URL" &&
        bash -n "$tmp" 2>/dev/null &&
        grep -q '^# ============ 入口' "$tmp"; then
        install -m 700 -- "$tmp" "$CONFIG_DIR/installer.sh" 2>/dev/null || true
    fi
    rm -f -- "$tmp"
    return 0
}

# ============ 原地升级 ============
do_upgrade() (
    check_root
    local src="" tmp=""
    [[ $# -eq 1 ]] || err "用法：sudo bash install.sh upgrade <https://地址|绝对路径>"
    [[ -x "$GOST_BIN" && -f "$CONFIG_FILE" && -f "$USERS_FILE" && -f "$SERVICE_FILE" ]] ||
        err "未找到已有安装，请先运行 bash install.sh"
    case "$1" in
        https://*)
            command -v curl >/dev/null 2>&1 || err "未找到 curl，无法在线下载"
            tmp=$(mktemp /tmp/gost-routed.XXXXXX) || err "无法创建临时文件"
            trap 'if [[ -n "$tmp" ]]; then rm -f -- "$tmp"; fi' EXIT
            info "正在下载升级包..."
            curl -fL --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 300 -o "$tmp" "$1" ||
                err "下载失败：$1"
            [[ -s "$tmp" ]] || err "下载内容为空：$1"
            chmod 700 "$tmp"
            src=$tmp
            ;;
        http://*)
            err "仅支持 https 下载；请使用 https 地址或本地绝对路径"
            ;;
        /*)
            [[ -f "$1" && -r "$1" ]] || err "文件不存在或不可读：$1"
            src=$1
            ;;
        *)
            err "用法：sudo bash install.sh upgrade <https://地址|绝对路径>"
            ;;
    esac

    umask 077
    # 兼容旧安装曾以 0644 生成含明文凭据的 YAML。
    chmod 600 "$USERS_FILE" "$CONFIG_FILE"
    exec 9>"$CONFIG_DIR/.lock"
    flock -x 9
    local work port was_active=0 i path
    local -a targets=("$ROUTED_BIN" "$SOCKS5_CMD" "$CONFIG_FILE" "$SERVICE_FILE")
    work=$(mktemp -d "$CONFIG_DIR/.upgrade.XXXXXX")
    trap 'rm -rf -- "$work"; if [[ -n "$tmp" ]]; then rm -f -- "$tmp"; fi' EXIT
    write_socks5_cmd "$work/socks5"
    write_service "$work/service"
    port=$(bash "$work/socks5" _port)
    bash "$work/socks5" _generate "$port" "$USERS_FILE" > "$work/config"
    install -m 755 -- "$src" "$work/gost-routed"
    # 即使尚未创建正式策略，也先确认二进制实现校验契约。
    printf 'ingress\n' > "$work/probe"
    bash "$work/socks5" _route_check "$work/gost-routed" "$work/probe"
    bash "$work/socks5" _route_check "$work/gost-routed"
    # 保留安装脚本副本，供管理菜单内的升级使用。
    save_installer

    if systemctl is-active --quiet "$SERVICE_NAME"; then was_active=1; fi
    for i in "${!targets[@]}"; do
        path=${targets[i]}
        if [[ -e "$path" || -L "$path" ]]; then
            cp -a -- "$path" "$work/old-$i"
        fi
    done

    # 先停止服务，避免旧服务在切换过程中重启并载入不完整的配置。
    systemctl stop "$SERVICE_NAME"
    if install -m 755 -- "$work/gost-routed" "$ROUTED_BIN" &&
        install -m 755 -- "$work/socks5" "$SOCKS5_CMD" &&
        install -m 600 -- "$work/config" "$CONFIG_FILE" &&
        install -m 644 -- "$work/service" "$SERVICE_FILE" &&
        systemctl daemon-reload &&
        { (( ! was_active )) || grep -Fxq 'services: []' "$CONFIG_FILE" || bash "$SOCKS5_CMD" _start; }; then
        msg "GOST 已升级，保留端口和用户；路由文件由管理员维护"
        return 0
    fi

    warn "升级未能应用，正在恢复原安装"
    systemctl stop "$SERVICE_NAME" || true
    local restored=1
    for i in "${!targets[@]}"; do
        path=${targets[i]}
        if [[ -e "$work/old-$i" || -L "$work/old-$i" ]]; then
            mv -f -- "$work/old-$i" "$path" || restored=0
        else
            rm -f -- "$path" || restored=0
        fi
    done
    if (( ! restored )); then
        trap - EXIT
        err "无法恢复原安装，备份保留在 ${work}"
    fi
    systemctl daemon-reload || err "已恢复原文件，但无法重新加载服务配置"
    if (( was_active )); then
        # 旧版内联认证或空用户配置不能安全地恢复监听。
        if cmp -s "$CONFIG_FILE" "$work/config" && ! grep -Fxq 'services: []' "$work/config"; then
            systemctl start "$SERVICE_NAME" || warn "原服务未能恢复，请检查服务日志"
        else
            warn "原配置未通过认证检查，服务保持停止"
        fi
    fi
    err "升级失败"
)

# ============ 在线升级到最新发布 ============
# 不带参数时按当前架构从发布列表解析资产地址，再复用 do_upgrade 的下载、
# 路由契约校验、替换和失败恢复流程。只接受文件名与架构完全一致的资产。
do_online_upgrade() (
    check_root
    local json url
    [[ $# -eq 0 ]] || err "用法：sudo bash install.sh upgrade"
    [[ -x "$GOST_BIN" && -f "$CONFIG_FILE" && -f "$USERS_FILE" && -f "$SERVICE_FILE" ]] ||
        err "未找到已有安装，请先运行 bash install.sh"
    command -v curl >/dev/null 2>&1 || err "未找到 curl，无法在线升级"
    detect_arch
    info "正在解析最新发布..."
    json=$(curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 30 \
        -H 'Accept: application/vnd.github+json' "$RELEASES_API") ||
        err "无法获取发布信息，请检查网络或改用 upgrade <https 地址>"
    [[ "$json" != *'API rate limit'* ]] || err "GitHub API 限流，请稍后重试或改用 upgrade <https 地址>"
    # 发布按时间倒序排列；取第一个匹配当前架构的资产（含预发布版本）。
    url=$(printf '%s\n' "$json" |
        grep -o '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*/gost-routed-linux-'"$ARCH"'"' |
        head -n 1 |
        sed -E 's/^.*"(https:[^"]*)"$/\1/') || true
    [[ -n "$url" ]] ||
        err "最新发布中没有适用于 ${ARCH} 的升级包；请在源码目录构建后使用 upgrade <绝对路径>"
    info "升级包：${url}"
    do_upgrade "$url"
)

# ============ 主安装流程 ============
do_install() (
    # 修复 bash <(curl ...) 方式运行时 stdin 被占用的问题
    exec < /dev/tty || err "无法连接终端，请在交互式终端中运行此脚本"

    echo ""
    echo -e "${BOLD}╔═══════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║     SOCKS5 一键部署脚本               ║${NC}"
    echo -e "${BOLD}╚═══════════════════════════════════════╝${NC}"
    echo ""

    check_root
    detect_os
    detect_arch

    # 检查是否已安装
    if [[ -f "$GOST_BIN" ]] && [[ -f "$CONFIG_FILE" ]]; then
        warn "检测到已有安装；如需保留端口和用户，请使用 install.sh upgrade"
        read -rp "是否重新安装? (y/N): " reinstall
        [[ "${reinstall,,}" != "y" ]] && { info "已取消"; exit 0; }
        systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    fi

    install_deps

    # 端口
    local default_port
    default_port="$(rand_port)"
    read -rp "$(echo -e "${CYAN}[?]${NC} 端口 (回车随机 ${default_port}): ")" S5_PORT
    S5_PORT="${S5_PORT:-$default_port}"

    # 验证端口是否为合法十进制数字
    if ! [[ "$S5_PORT" =~ ^[0-9]{1,5}$ ]] || (( 10#$S5_PORT < 1 || 10#$S5_PORT > 65535 )); then
        err "无效端口: ${S5_PORT}，请输入 1-65535 之间的数字"
    fi
    S5_PORT=$((10#$S5_PORT))

    # 检查端口是否被占用
    if ss -tlnp | grep -q ":${S5_PORT} "; then
        err "端口 ${S5_PORT} 已被占用，请更换"
    fi

    # 用户名
    local default_user="user_$(rand_str 4)"
    read -rp "$(echo -e "${CYAN}[?]${NC} 用户名 (回车随机 ${default_user}): ")" S5_USER
    S5_USER="${S5_USER:-$default_user}"

    # 密码
    local default_pass
    default_pass="$(rand_str 16)"
    read -rp "$(echo -e "${CYAN}[?]${NC} 密码 (回车随机): ")" S5_PASS
    S5_PASS="${S5_PASS:-$default_pass}"

    echo ""
    info "开始安装..."

    # 安装和管理命令共用同一个配置生成器。
    mkdir -p -m 700 "$CONFIG_DIR"
    umask 077
    local work
    work=$(mktemp -d "$CONFIG_DIR/.install.XXXXXX")
    trap 'rm -rf -- "$work"' EXIT
    write_socks5_cmd "$work/socks5"
    printf '%s:%s\n' "$S5_USER" "$S5_PASS" > "$work/users"
    bash "$work/socks5" _generate "$S5_PORT" "$work/users" > "$work/config"
    bash "$work/socks5" _route_check "$ROUTED_BIN"
    write_service "$work/service"
    download_gost
    install -m 600 -- "$work/users" "$USERS_FILE"
    install -m 600 -- "$work/config" "$CONFIG_FILE"
    install -m 755 -- "$work/socks5" "$SOCKS5_CMD"
    install -m 644 -- "$work/service" "$SERVICE_FILE"
    # 保留安装脚本副本，供管理菜单内的升级使用。
    save_installer

    configure_firewall "$S5_PORT"
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
    bash "$SOCKS5_CMD" _restart || { systemctl stop "$SERVICE_NAME" || true; err "服务未监听预期端口，请查看服务日志"; }
    msg "服务已启动并设置开机自启"
    rm -rf -- "$work"
    trap - EXIT

    # 获取公网 IP
    local PUBLIC_IP
    PUBLIC_IP="$(get_public_ip)"

    # 输出信息
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════${NC}"
    echo -e "${GREEN}${BOLD}  ✓ 安装完成!${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════${NC}"
    echo ""
    echo -e "  服务器:  ${CYAN}${PUBLIC_IP}${NC}"
    echo -e "  端口:    ${CYAN}${S5_PORT}${NC}"
    echo -e "  用户名:  ${CYAN}${S5_USER}${NC}"
    echo -e "  密码:    ${CYAN}${S5_PASS}${NC}"
    echo ""
    echo -e "  ${BOLD}连接链接:${NC}"
    echo -e "  ${GREEN}${BOLD}socks5://${S5_USER}:${S5_PASS}@${PUBLIC_IP}:${S5_PORT}${NC}"
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════${NC}"
    echo -e "  管理菜单: ${CYAN}socks5${NC}（命令帮助：socks5 help）"
    echo -e "${BOLD}═══════════════════════════════════════════${NC}"
    echo ""
)

# ============ 入口 ============
# 如果通过 socks5 命令调用则转发参数
# 如果直接运行则执行安装
case "${1:-install}" in
    install) do_install ;;
    upgrade)
        shift
        # 无参数或 latest：在线解析最新发布；否则按 https 地址或本地路径升级。
        if [[ $# -eq 0 ]] || [[ $# -eq 1 && "$1" == latest ]]; then
            do_online_upgrade
        else
            do_upgrade "$@"
        fi
        ;;
    update-cli) shift; do_update_cli "$@" ;;
    *)
        # 如果存在管理命令则转发
        if [[ -x "$SOCKS5_CMD" ]]; then
            exec "$SOCKS5_CMD" "$@"
        else
            do_install
        fi
        ;;
esac
