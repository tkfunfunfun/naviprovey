#!/bin/bash
# ====================================
# 服务器管理脚本
# 功能：SSL证书 / 系统更新 / BBR / NaiveProxy
# Debian / Ubuntu
# ====================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'
red='\e[91m'; green='\e[92m'; yellow='\e[93m'
magenta='\e[95m'; cyan='\e[96m'; none='\e[0m'

success()    { echo -e "${GREEN}${BOLD} ✔  $1${NC}"; }
error_exit() { echo -e "${RED}${BOLD} ✘  $1${NC}"; exit 1; }
info()       { echo -e "${CYAN} ➤  $1${NC}"; }
warn()       { echo -e "${YELLOW} !  $1${NC}"; }
_error()     { echo -e "\n$red 输入错误！$none\n"; }
pause()      { read -rsp "$(echo -e "按 $green Enter$none 继续，$red Ctrl+C$none 取消")" -d $'\n'; echo; }

[ "$EUID" -ne 0 ] && error_exit "请使用 root 权限运行: sudo bash ssl_manager.sh"

# 系统检测
cmd="apt-get"
[[ $(command -v yum) ]] && cmd="yum"
[[ $(command -v apt-get) ]] && cmd="apt-get"
sys_bit=$(uname -m)
case $sys_bit in
    'amd64'|x86_64)      caddy_arch="amd64" ;;
    *aarch64*|*armv8*)   caddy_arch="arm64" ;;
    *) echo -e "$red 不支持的系统架构$none" && exit 1 ;;
esac
uuid=$(cat /proc/sys/kernel/random/uuid)
systemd=true

do_service() { systemctl $1 $2 $3 2>/dev/null; }

get_ip() {
    ipv4=$(curl -s --max-time 5 https://ipinfo.io/ip)
    [[ -z $ipv4 ]] && ipv4=$(curl -s --max-time 5 https://api.ipify.org)
    [[ -z $ipv4 ]] && ipv4=$(curl -s --max-time 5 icanhazip.com)
    ipv6=$(ip a | grep inet6 | grep global | awk '{print $2}' | awk -F'/' '{print $1}')
    ip_all="$ipv4 $ipv6"
}

domain_check() {
    test_domain=$(curl -sH 'accept: application/dns-json' \
        "https://cloudflare-dns.com/dns-query?name=$domain&type=A" | \
        grep -oE "([0-9]{1,3}\.){3}[0-9]{1,3}" | head -1)
    if ! echo "$ip_all" | grep -q "$test_domain"; then
        echo -e "$red 域名解析检测失败$none"
        echo -e " 域名 $yellow$domain$none 未解析到: $cyan$ip_all$none"
        echo -e " 当前解析到: $cyan$test_domain$none"
        echo " 如使用 Cloudflare，请将代理状态改为仅DNS（灰色云朵）"
    fi
}

# ══════════════════════════════════════
#  NaiveProxy 函数
# ══════════════════════════════════════
naive_input_config() {
    echo
    while :; do
        echo -e "请输入 ${yellow}NaiveProxy${none} 端口 [${magenta}1-65535${none}]，不能用 ${magenta}80${none} 端口"
        read -p "$(echo -e "(默认: ${cyan}443${none}): ")" naive_port
        [ -z "$naive_port" ] && naive_port=443
        case $naive_port in
        80) echo -e "\n$red 不能使用 80 端口！$none\n" ;;
        [1-9]|[1-9][0-9]|[1-9][0-9][0-9]|[1-9][0-9][0-9][0-9]|\
        [1-5][0-9][0-9][0-9][0-9]|6[0-4][0-9][0-9][0-9]|65[0-4][0-9][0-9]|655[0-3][0-5])
            echo -e "$yellow 端口 = $cyan$naive_port$none"; break ;;
        *) _error ;;
        esac
    done

    while :; do
        echo
        echo -e "请输入 ${magenta}正确的域名${none}（必须已解析到此服务器）"
        read -p "(例如: n.abc.com): " domain
        [ -z "$domain" ] && _error && continue
        echo -e "$yellow 域名 = $cyan$domain$none"; break
    done

    while :; do
        echo
        echo -e "请输入 ${magenta}邮箱${none}（用于申请证书）"
        read -p "(例如: name@abc.com): " email
        [ -z "$email" ] && _error && continue
        echo -e "$yellow 邮箱 = $cyan$email$none"; break
    done

    get_ip
    echo
    echo -e "$yellow 请将 $magenta$domain$none $yellow 解析到: $cyan$ipv4$none"
    echo
    while :; do
        read -p "$(echo -e "已正确解析了吗？输入 [${magenta}Y${none}] 确认: ")" record
        [[ "$record" == [Yy] ]] && domain_check && break || _error
    done
}

install_caddy_bin() {
    mkdir -p /root/src && cd /root/src/
    rm -f caddy-forwardproxy-naive.tar.xz
    info "下载 caddy-forwardproxy-naive..."
    wget -q --show-progress \
        https://github.com/klzgrad/forwardproxy/releases/download/v2.7.5-caddy2-naive2/caddy-forwardproxy-naive.tar.xz
    tar xf caddy-forwardproxy-naive.tar.xz
    do_service stop naive
    \cp caddy-forwardproxy-naive/caddy /usr/bin/
    chmod +x /usr/bin/caddy
    setcap cap_net_bind_service=+ep /usr/bin/caddy
    /usr/bin/caddy version && success "Caddy 安装成功" || error_exit "Caddy 安装失败"
}

install_deps_naive() {
    if [[ $cmd == "apt-get" ]]; then
        $cmd update -y -qq
        $cmd install -y curl lrzsz git zip unzip wget libcap2-bin tar certbot -qq
    else
        $cmd install -y lrzsz git zip unzip curl wget libcap epel-release tar ca-certificates certbot
    fi
}

write_caddy_config() {
    local np_user="${1:-User}"
    local np_pass="${2:-$uuid}"
    mkdir -p /etc/caddy
    cat > /etc/caddy/caddy_config.json << EOF
{
  "admin": { "disabled": true },
  "apps": {
    "http": {
      "servers": {
        "srv0": {
          "listen": [":$naive_port"],
          "routes": [{
            "handle": [{
              "handler": "subroute",
              "routes": [
                {
                  "handle": [{
                    "auth_user_deprecated": "$np_user",
                    "auth_pass_deprecated": "$np_pass",
                    "handler": "forward_proxy",
                    "hide_ip": true,
                    "hide_via": true,
                    "probe_resistance": {}
                  }]
                },
                {
                  "match": [{"host": ["$domain"]}],
                  "handle": [{
                    "handler": "file_server",
                    "root": "/var/www/html",
                    "index_names": ["index.html"]
                  }],
                  "terminal": true
                }
              ]
            }]
          }],
          "tls_connection_policies": [{"match": {"sni": ["$domain"]}}],
          "automatic_https": {"disable": true}
        }
      }
    },
    "tls": {
      "certificates": {
        "load_files": [{
          "certificate": "/etc/letsencrypt/live/$domain/fullchain.pem",
          "key": "/etc/letsencrypt/live/$domain/privkey.pem"
        }]
      }
    }
  }
}
EOF
}

write_naive_service() {
    cat > /etc/systemd/system/naive.service << 'EOF'
[Unit]
Description=Caddy NaiveProxy
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
User=root
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/caddy_config.json
ExecReload=/usr/bin/caddy reload --config /etc/caddy/caddy_config.json
TimeoutStopSec=5s
LimitNOFILE=1048576
PrivateTmp=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
EOF
    do_service daemon-reload
    do_service enable naive
    do_service restart naive
    sleep 2
    do_service status naive --no-pager
}

save_naive_autoconfig() {
    local np_user="${1:-User}"
    local np_pass="${2:-$uuid}"
    mkdir -p /etc/caddy
    {
        echo ""
        echo "域名domain   =$domain"
        echo "端口port     =$naive_port"
        echo "用户名user   =$np_user"
        echo "密码password =$np_pass"
        echo "邮箱email    =$email"
    } > /etc/caddy/.autoconfig
}

add_naive_cron() {
    cat > /etc/caddy/.renew.sh << 'EOF'
#!/bin/bash
systemctl stop naive
certbot renew
systemctl start naive
EOF
    chmod +x /etc/caddy/.renew.sh
    mkdir -p /var/spool/cron/
    touch /var/spool/cron/root
    if [ "$(grep -c 'naive' /var/spool/cron/root 2>/dev/null)" -lt 1 ]; then
        echo "0 1 * * * /etc/caddy/.renew.sh" >> /var/spool/cron/root
    fi
    success "证书自动续期已配置（每天 01:00）"
}

allow_ports_naive() {
    if [[ $(command -v apt-get) ]]; then
        iptables -I INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null
        iptables -I INPUT -p tcp --dport "$naive_port" -j ACCEPT 2>/dev/null
        iptables -I INPUT -p udp --dport "$naive_port" -j ACCEPT 2>/dev/null
        iptables-save 2>/dev/null || true
    elif [[ $(command -v firewall-cmd) ]]; then
        firewall-cmd --zone=public --add-port=80/tcp --permanent 2>/dev/null
        firewall-cmd --zone=public --add-port="$naive_port"/tcp --permanent 2>/dev/null
        firewall-cmd --reload 2>/dev/null
    fi
    success "防火墙已开放端口 $naive_port"
}

show_naive_info() {
    echo ""
    echo -e "${MAGENTA}${BOLD}  ╔══════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}${BOLD}  ║   ✔  NaiveProxy 配置信息             ║${NC}"
    echo -e "${MAGENTA}${BOLD}  ╠══════════════════════════════════════╣${NC}"
    cat /etc/caddy/.autoconfig | grep -v '^$' | while IFS= read -r line; do
        echo -e "${MAGENTA}${BOLD}  ║${NC}  ${WHITE}$line${NC}"
    done
    echo -e "${MAGENTA}${BOLD}  ╚══════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  客户端下载:"
    echo -e "  ${CYAN}Win/Linux: https://github.com/klzgrad/naiveproxy/releases${NC}"
    echo -e "  ${CYAN}Android  : NekoBox / husi / SagerNet${NC}"
}

install_naive() {
    if [[ -f /usr/bin/caddy && -f /etc/caddy/caddy_config.json ]]; then
        echo
        echo " NaiveProxy 已安装，请选择："
        echo " 1) 重新安装"
        echo " 2) 仅更新 Caddy 二进制"
        echo " 其他) 取消"
        read -p "请选择: " ch
        case $ch in
        1) do_service stop naive ;;
        2)
            install_caddy_bin
            do_service start naive
            show_naive_info
            return ;;
        *) return ;;
        esac
    fi

    naive_input_config
    allow_ports_naive

    info "安装依赖..."
    install_deps_naive

    # 申请证书
    if ls /etc/letsencrypt/live/ 2>/dev/null | grep -q "$domain"; then
        certbot renew
    else
        certbot certonly --standalone -d "$domain" --agree-tos --email "$email"
    fi

    # 创建伪装页
    mkdir -p /var/www/html
    cat > /var/www/html/index.html << 'EOF'
<!DOCTYPE html><html><head><title>Welcome</title></head>
<body><h1>Welcome!</h1><p>It works.</p></body></html>
EOF

    # 时区同步
    ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
    timedatectl set-timezone Asia/Shanghai 2>/dev/null
    timedatectl set-ntp true 2>/dev/null

    install_caddy_bin
    write_caddy_config "User" "$uuid"
    write_naive_service
    save_naive_autoconfig "User" "$uuid"
    add_naive_cron
    show_naive_info
}

edit_naive() {
    [ ! -f /etc/caddy/.autoconfig ] && error_exit "未找到 NaiveProxy 配置，请先安装"
    domain=$(grep 'domain' /etc/caddy/.autoconfig | awk -F'=' '{print $2}')
    naive_port=$(grep 'port' /etc/caddy/.autoconfig | awk -F'=' '{print $2}')
    np_user=$(grep 'user' /etc/caddy/.autoconfig | awk -F'=' '{print $2}')
    np_pass=$(grep 'password' /etc/caddy/.autoconfig | awk -F'=' '{print $2}')
    email=$(grep 'email' /etc/caddy/.autoconfig | awk -F'=' '{print $2}')

    read -p "$(echo -e "端口 (当前: ${cyan}${naive_port}${none}，直接回车保留): ")" p1
    [ -n "$p1" ] && naive_port=$p1
    read -p "$(echo -e "用户名 (当前: ${cyan}${np_user}${none}，直接回车保留): ")" u1
    [ -n "$u1" ] && np_user=$u1
    read -p "$(echo -e "密码 (当前: ${cyan}${np_pass}${none}，直接回车保留): ")" pw1
    [ -n "$pw1" ] && np_pass=$pw1

    write_caddy_config "$np_user" "$np_pass"
    save_naive_autoconfig "$np_user" "$np_pass"
    do_service restart naive
    success "配置已更新"
    show_naive_info
}

naive_menu() {
    while :; do
        echo ""
        echo -e "${MAGENTA}${BOLD}  ╔════════════════════════════════════════╗${NC}"
        echo -e "${MAGENTA}${BOLD}  ║   NaiveProxy 管理                      ║${NC}"
        echo -e "${MAGENTA}${BOLD}  ╠════════════════════════════════════════╣${NC}"
        echo -e "${MAGENTA}${BOLD}  ║  ${magenta}[1]${none} 安装 / 更新                      ${MAGENTA}${BOLD}║${NC}"
        echo -e "${MAGENTA}${BOLD}  ║  ${magenta}[2]${none} 显示配置信息                    ${MAGENTA}${BOLD}║${NC}"
        echo -e "${MAGENTA}${BOLD}  ║  ${magenta}[3]${none} 修改配置                        ${MAGENTA}${BOLD}║${NC}"
        echo -e "${MAGENTA}${BOLD}  ║  ${magenta}[4]${none} 证书续签                        ${MAGENTA}${BOLD}║${NC}"
        echo -e "${MAGENTA}${BOLD}  ║  ${magenta}[5]${none} 重启服务                        ${MAGENTA}${BOLD}║${NC}"
        echo -e "${MAGENTA}${BOLD}  ║  ${magenta}[6]${none} 卸载                            ${MAGENTA}${BOLD}║${NC}"
        echo -e "${MAGENTA}${BOLD}  ║  ${red}[0]${none} 返回主菜单                      ${MAGENTA}${BOLD}║${NC}"
        echo -e "${MAGENTA}${BOLD}  ╚════════════════════════════════════════╝${NC}"
        echo ""
        read -p "$(echo -e "请选择 [${magenta}0-6${none}]: ")" ch
        case $ch in
        1) install_naive; break ;;
        2) show_naive_info
           do_service status naive --no-pager; break ;;
        3) edit_naive; break ;;
        4)
            if netstat -nltp 2>/dev/null | grep -q ":80 "; then
                warn "请先关闭占用 80 端口的服务再续签"
            else
                do_service stop naive
                certbot renew
                do_service start naive
                success "续签完成"
            fi; break ;;
        5) do_service restart naive; success "服务已重启"; break ;;
        6)
            do_service disable naive
            do_service stop naive
            rm -f /etc/systemd/system/naive.service
            rm -rf /usr/bin/caddy /etc/caddy /root/src/caddy-forwardproxy-naive*
            success "NaiveProxy 已卸载"; break ;;
        0) return ;;
        *) _error ;;
        esac
    done
}

# ══════════════════════════════════════
#  主菜单
# ══════════════════════════════════════
clear
echo ""
echo -e "${CYAN}${BOLD}  ╔════════════════════════════════════════╗${NC}"
echo -e "${CYAN}${BOLD}  ║                                        ║${NC}"
echo -e "${CYAN}${BOLD}  ║  ${WHITE}★  服务器一键管理脚本  ★${CYAN}${BOLD}              ║${NC}"
echo -e "${CYAN}${BOLD}  ║  ${DIM}${WHITE}Debian / Ubuntu                     ${CYAN}${BOLD}  ║${NC}"
echo -e "${CYAN}${BOLD}  ║                                        ║${NC}"
echo -e "${CYAN}${BOLD}  ╠════════════════════════════════════════╣${NC}"
echo -e "${CYAN}${BOLD}  ║                                        ║${NC}"
echo -e "${CYAN}${BOLD}  ║  ${GREEN}${BOLD}[1]${NC}${WHITE} 申请 SSL 证书                  ${CYAN}${BOLD}  ║${NC}"
echo -e "${CYAN}${BOLD}  ║  ${GREEN}${BOLD}[2]${NC}${WHITE} 查询 SSL 证书                  ${CYAN}${BOLD}  ║${NC}"
echo -e "${CYAN}${BOLD}  ║  ${GREEN}${BOLD}[3]${NC}${WHITE} 续期 SSL 证书                  ${CYAN}${BOLD}  ║${NC}"
echo -e "${CYAN}${BOLD}  ║                                        ║${NC}"
echo -e "${CYAN}${BOLD}  ║  ${YELLOW}${BOLD}[4]${NC}${WHITE} 系统更新                       ${CYAN}${BOLD}  ║${NC}"
echo -e "${CYAN}${BOLD}  ║  ${YELLOW}${BOLD}[5]${NC}${WHITE} 开启 BBR 加速                  ${CYAN}${BOLD}  ║${NC}"
echo -e "${CYAN}${BOLD}  ║                                        ║${NC}"
echo -e "${CYAN}${BOLD}  ║  ${MAGENTA}${BOLD}[6]${NC}${WHITE} NaiveProxy 管理                ${CYAN}${BOLD}  ║${NC}"
echo -e "${CYAN}${BOLD}  ║                                        ║${NC}"
echo -e "${CYAN}${BOLD}  ║  ${RED}${BOLD}[0]${NC}${WHITE} 退出                           ${CYAN}${BOLD}  ║${NC}"
echo -e "${CYAN}${BOLD}  ║                                        ║${NC}"
echo -e "${CYAN}${BOLD}  ╚════════════════════════════════════════╝${NC}"
echo ""
read -rp "$(echo -e ${WHITE}${BOLD}"  请输入选项: "${NC})" ACTION
echo ""

case "$ACTION" in

1)
    echo -e "${GREEN}${BOLD}  ── 申请 SSL 证书 ──${NC}\n"
    read -rp "$(echo -e ${WHITE}"  请输入域名: "${NC})" DOMAIN
    [ -z "$DOMAIN" ] && error_exit "域名不能为空"

    # 选择验证方式
    echo ""
    echo -e "${CYAN}${BOLD}  请选择证书申请方式:${NC}"
    echo -e "  ${GREEN}[1]${NC} Standalone  （需要 80 端口对外开放）"
    echo -e "  ${GREEN}[2]${NC} Cloudflare DNS（无需开放端口，推荐）"
    echo ""
    read -rp "$(echo -e ${WHITE}"  请选择 [1/2]: "${NC})" SSL_MODE
    [ -z "$SSL_MODE" ] && SSL_MODE=1

    info "安装依赖..."
    apt update -y -qq && apt install -y curl nginx certbot dnsutils -qq

    info "获取服务器 IP..."
    SERVER_IP=$(curl -4 -s --max-time 5 ifconfig.me)
    DNS_IP=$(dig +short "$DOMAIN" A | tail -n1)
    echo -e "  服务器 IP : ${WHITE}$SERVER_IP${NC}"
    echo -e "  域名解析  : ${WHITE}$DNS_IP${NC}"
    [ "$DNS_IP" != "$SERVER_IP" ] && error_exit "域名未解析到当前服务器，请检查 DNS"
    success "DNS 检查通过"

    if [ "$SSL_MODE" = "2" ]; then
        # ── Cloudflare DNS 验证 ──
        info "安装 Cloudflare certbot 插件..."
        apt install -y python3-certbot-dns-cloudflare -qq
        echo ""
        echo -e "${YELLOW}  请前往 Cloudflare → My Profile → API Tokens → Create Token${NC}"
        echo -e "${YELLOW}  模板选 [Edit zone DNS]，Zone 选你的域名，创建后复制 Token${NC}"
        echo ""
        read -rp "$(echo -e ${WHITE}"  请粘贴 Cloudflare API Token: "${NC})" CF_TOKEN
        [ -z "$CF_TOKEN" ] && error_exit "Token 不能为空"

        mkdir -p ~/.secrets
        cat > ~/.secrets/cloudflare.ini << CFEOF
dns_cloudflare_api_token = $CF_TOKEN
CFEOF
        chmod 600 ~/.secrets/cloudflare.ini

        info "申请证书中（DNS 验证）..."
        certbot certonly \
            --dns-cloudflare \
            --dns-cloudflare-credentials ~/.secrets/cloudflare.ini \
            --dns-cloudflare-propagation-seconds 30 \
            -d "$DOMAIN" \
            --agree-tos --register-unsafely-without-email --non-interactive
        [ $? -ne 0 ] && error_exit "证书申请失败，请检查 Token 权限或域名是否正确"

        # 自动续期脚本（DNS 模式）
        cat > /usr/local/bin/ssl_renew.sh << RENEWEOF
#!/bin/bash
certbot renew --dns-cloudflare --dns-cloudflare-credentials ~/.secrets/cloudflare.ini --quiet >> /var/log/ssl_renew.log 2>&1
RENEWEOF

    else
        # ── Standalone 验证 ──
        info "停止占用 80 端口的服务..."
        systemctl stop nginx 2>/dev/null
        pkill -f nginx 2>/dev/null
        sleep 1
        if ss -lntp | grep -qE ':80\b'; then
            PROC=$(ss -lntp | grep ':80 ' | awk '{print $NF}' | head -1)
            error_exit "80 端口被其他进程占用: $PROC，请手动释放后重试"
        fi
        info "申请证书中（Standalone 验证）..."
        certbot certonly --standalone -d "$DOMAIN" \
            --agree-tos --register-unsafely-without-email --non-interactive
        [ $? -ne 0 ] && { systemctl start nginx 2>/dev/null; error_exit "证书申请失败，请确认 80 端口对外开放"; }
        systemctl start nginx 2>/dev/null

        # 自动续期脚本（Standalone 模式）
        cat > /usr/local/bin/ssl_renew.sh << 'RENEWEOF'
#!/bin/bash
systemctl stop nginx
certbot renew --standalone --quiet >> /var/log/ssl_renew.log 2>&1
systemctl start nginx
RENEWEOF
    fi

    chmod +x /usr/local/bin/ssl_renew.sh
    echo "30 3 * * * root /usr/local/bin/ssl_renew.sh" > /etc/cron.d/ssl-renew
    systemctl restart cron 2>/dev/null

    echo ""
    echo -e "${GREEN}${BOLD}  ╔══════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}  ║   ✔  证书申请成功！                  ║${NC}"
    echo -e "${GREEN}${BOLD}  ╠══════════════════════════════════════╣${NC}"
    echo -e "${GREEN}${BOLD}  ║${NC}  证书路径:                            ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}  ║${NC}  ${WHITE}/etc/letsencrypt/live/$DOMAIN/${NC}"
    echo -e "${GREEN}${BOLD}  ║${NC}  fullchain.pem  /  privkey.pem        ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}  ║${NC}  自动续期: 每天 ${YELLOW}03:30${NC} 自动检查        ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}  ╚══════════════════════════════════════╝${NC}"
    ;;

2)
    echo -e "${GREEN}${BOLD}  ── 查询 SSL 证书 ──${NC}\n"
    read -rp "$(echo -e ${WHITE}"  请输入域名: "${NC})" DOMAIN
    CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    [ ! -f "$CERT" ] && error_exit "未找到 $DOMAIN 的证书"
    NOT_AFTER=$(openssl x509 -in "$CERT" -noout -enddate | cut -d= -f2)
    DAYS=$(( ( $(date -d "$NOT_AFTER" +%s) - $(date +%s) ) / 86400 ))
    if [ "$DAYS" -le 7 ]; then DAY_COLOR="${RED}${BOLD}"; DAY_TIP="（即将到期！）"
    elif [ "$DAYS" -le 30 ]; then DAY_COLOR="${YELLOW}${BOLD}"; DAY_TIP="（建议续期）"
    else DAY_COLOR="${GREEN}${BOLD}"; DAY_TIP=""; fi
    echo ""
    echo -e "${CYAN}${BOLD}  ╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}  ║   证书信息                           ║${NC}"
    echo -e "${CYAN}${BOLD}  ╠══════════════════════════════════════╣${NC}"
    echo -e "${CYAN}${BOLD}  ║${NC}  域名    : ${WHITE}${BOLD}$DOMAIN${NC}"
    echo -e "${CYAN}${BOLD}  ║${NC}  到期时间: ${WHITE}$NOT_AFTER${NC}"
    echo -e "${CYAN}${BOLD}  ║${NC}  剩余天数: ${DAY_COLOR}${DAYS} 天 ${DAY_TIP}${NC}"
    echo -e "${CYAN}${BOLD}  ╚══════════════════════════════════════╝${NC}"
    ;;

3)
    echo -e "${GREEN}${BOLD}  ── 续期 SSL 证书 ──${NC}\n"
    read -rp "$(echo -e ${WHITE}"  请输入域名（留空续期所有）: "${NC})" DOMAIN
    info "停止 Nginx..."
    systemctl stop nginx
    if [ -z "$DOMAIN" ]; then certbot renew --standalone
    else
        certbot certonly --standalone -d "$DOMAIN" \
            --agree-tos --register-unsafely-without-email \
            --non-interactive --force-renewal
    fi
    systemctl start nginx
    success "续期完成"
    ;;

4)
    echo -e "${YELLOW}${BOLD}  ── 系统更新 ──${NC}\n"
    info "更新软件源..."; apt update -y
    info "升级软件包..."; apt upgrade -y
    info "清理无用包..."; apt autoremove -y && apt autoclean -y
    success "系统更新完成！"
    if [ -f /var/run/reboot-required ]; then
        warn "系统需要重启才能完成更新"
        read -rp "$(echo -e ${WHITE}"  现在重启？[y/N]: "${NC})" REBOOT
        [[ "$REBOOT" == [Yy] ]] && reboot || warn "请稍后手动执行 reboot"
    fi
    ;;

5)
    echo -e "${YELLOW}${BOLD}  ── 开启 BBR 加速 ──${NC}\n"
    CURRENT_CC=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    CURRENT_QDISC=$(sysctl net.core.default_qdisc 2>/dev/null | awk '{print $3}')
    if [ "$CURRENT_CC" = "bbr" ] && [ "$CURRENT_QDISC" = "fq" ]; then
        success "BBR 已开启，无需重复操作"
        echo -e "  拥塞控制: ${GREEN}$CURRENT_CC${NC}  队列调度: ${GREEN}$CURRENT_QDISC${NC}"
        exit 0
    fi
    KERNEL=$(uname -r | cut -d. -f1-2 | tr -d '.')
    [ "$KERNEL" -lt 49 ] && error_exit "内核版本过低（需要 4.9+），当前：$(uname -r)"
    info "写入 BBR 配置..."
    cat >> /etc/sysctl.conf << 'EOF'

# BBR 加速
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    sysctl -p >/dev/null 2>&1
    CC=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
    QD=$(sysctl net.core.default_qdisc | awk '{print $3}')
    if [ "$CC" = "bbr" ] && [ "$QD" = "fq" ]; then
        success "BBR 开启成功！"
        echo -e "  拥塞控制: ${GREEN}${BOLD}$CC${NC}  队列调度: ${GREEN}${BOLD}$QD${NC}"
    else
        error_exit "BBR 开启失败，请检查内核是否支持"
    fi
    ;;

6)
    naive_menu
    ;;

0)
    echo -e "${DIM}  再见！${NC}\n"; exit 0
    ;;

*)
    error_exit "无效选项，请输入 0-6"
    ;;
esac

echo ""
