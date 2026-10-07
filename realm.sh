#!/bin/bash
# realm 一键转发安装脚本 - 支持自定义 本机端口 / 落地IP / 落地端口
# GitHub: https://github.com/YOUR_USERNAME/realm-forwarder
# 一键命令: bash <(curl -sL https://raw.githubusercontent.com/YOUR_USERNAME/realm-forwarder/main/install.sh) 38509 198.12.95.40 42039
set -e

# --- 颜色 ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; PLAIN='\033[0m'

# --- 默认配置 ---
REALM_VERSION="v2.7.0"
INSTALL_DIR="/opt/realm"
CONFIG_DIR="/etc/realm"
CONFIG_FILE="${CONFIG_DIR}/config.toml"
BIN_PATH="${INSTALL_DIR}/realm"
SERVICE_FILE="/etc/systemd/system/realm.service"

LISTEN_ADDR="0.0.0.0"
LISTEN_PORT=""
REMOTE_IP=""
REMOTE_PORT=""
REMOTE_ADDR=""

# --- 参数解析 ---
usage() {
    echo -e "${GREEN}realm 转发一键安装脚本${PLAIN}"
    echo "用法1 (位置参数): $0 <本机端口> <落地IP> <落地端口>"
    echo "  示例: $0 38509 198.12.95.40 42039"
    echo ""
    echo "用法2 (命名参数): $0 -l <本机端口> -i <落地IP> -p <落地端口> [-a 监听地址]"
    echo "  示例: $0 -l 38509 -i 198.12.95.40 -p 42039"
    echo "  示例: $0 -l 38509 -a 0.0.0.0 -i 198.12.95.40 -p 42039"
    echo ""
    echo "用法3 (一键远程):"
    echo "  bash <(curl -sL https://raw.githubusercontent.com/YOUR_USERNAME/realm-forwarder/main/install.sh) 38509 198.12.95.40 42039"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -l|--listen-port) LISTEN_PORT="$2"; shift 2;;
        -a|--listen-addr) LISTEN_ADDR="$2"; shift 2;;
        -i|--remote-ip) REMOTE_IP="$2"; shift 2;;
        -p|--remote-port) REMOTE_PORT="$2"; shift 2;;
        -r|--remote) REMOTE_ADDR="$2"; shift 2;; # 支持直接传 IP:PORT
        -v|--version) REALM_VERSION="$2"; shift 2;;
        -h|--help) usage;;
        *)
            # 位置参数兼容
            if [[ -z "$LISTEN_PORT" ]]; then LISTEN_PORT="$1"
            elif [[ -z "$REMOTE_IP" ]]; then REMOTE_IP="$1"
            elif [[ -z "$REMOTE_PORT" ]]; then REMOTE_PORT="$1"
            else echo -e "${RED}未知参数: $1${PLAIN}"; usage
            fi
            shift;;
    esac
done

# 支持 -r 198.12.95.40:42039 这种写法
if [[ -n "$REMOTE_ADDR" && -z "$REMOTE_IP" ]]; then
    REMOTE_IP=$(echo $REMOTE_ADDR | cut -d: -f1)
    REMOTE_PORT=$(echo $REMOTE_ADDR | cut -d: -f2)
fi

# 支持环境变量
[[ -z "$LISTEN_PORT" && -n "$PORT" ]] && LISTEN_PORT=$PORT
[[ -z "$LISTEN_PORT" ]] && LISTEN_PORT=${LISTEN_PORT_ENV:-}
[[ -z "$REMOTE_IP" ]] && REMOTE_IP=${REMOTE_IP_ENV:-}
[[ -z "$REMOTE_PORT" ]] && REMOTE_PORT=${REMOTE_PORT_ENV:-}

# 交互式输入 (如果没传参)
if [[ -z "$LISTEN_PORT" ]]; then
    read -p "请输入本机监听端口 [默认 38509]: " input
    LISTEN_PORT=${input:-38509}
fi
if [[ -z "$REMOTE_IP" ]]; then
    read -p "请输入落地IP [例如 198.12.95.40]: " REMOTE_IP
    [[ -z "$REMOTE_IP" ]] && echo -e "${RED}落地IP不能为空${PLAIN}" && exit 1
fi
if [[ -z "$REMOTE_PORT" ]]; then
    read -p "请输入落地端口 [默认 42039]: " input
    REMOTE_PORT=${input:-42039}
fi

LISTEN="${LISTEN_ADDR}:${LISTEN_PORT}"
REMOTE="${REMOTE_IP}:${REMOTE_PORT}"

echo -e "${GREEN}=== realm 一键安装 ===${PLAIN}"
echo -e "本机监听: ${YELLOW}${LISTEN}${PLAIN}"
echo -e "落地地址: ${YELLOW}${REMOTE}${PLAIN}"
echo -e "版本: ${YELLOW}${REALM_VERSION}${PLAIN}"
echo ""

# --- 检查 root ---
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}请使用 root 权限运行: sudo bash $0${PLAIN}" 
   exit 1
fi

# --- 1. 修复 DNS (你原脚本) ---
echo -e "${GREEN}[1/6] 修复 DNS...${PLAIN}"
echo -e "nameserver 1.1.1.1\nnameserver 8.8.8.8" > /etc/resolv.conf
ping 1.1.1.1 -c 1 -W 2 >/dev/null 2>&1 || echo -e "${YELLOW}警告: ping 1.1.1.1 失败，但继续安装${PLAIN}"

# --- 2. 检测架构 ---
echo -e "${GREEN}[2/6] 检测系统架构...${PLAIN}"
ARCH=$(uname -m)
case $ARCH in
    x86_64|amd64) REALM_ARCH="x86_64-unknown-linux-musl" ;;
    aarch64|arm64) REALM_ARCH="aarch64-unknown-linux-musl" ;;
    armv7l) REALM_ARCH="armv7-unknown-linux-musleabihf" ;;
    *) echo -e "${RED}不支持的架构: $ARCH${PLAIN}"; exit 1 ;;
esac
echo "架构: $ARCH -> $REALM_ARCH"

# --- 3. 下载 realm ---
echo -e "${GREEN}[3/6] 下载 realm ${REALM_VERSION}...${PLAIN}"
mkdir -p $INSTALL_DIR $CONFIG_DIR
cd /tmp
TARBALL="realm-${REALM_ARCH}.tar.gz"
DOWNLOAD_URL="https://github.com/zhboner/realm/releases/download/${REALM_VERSION}/realm-${REALM_ARCH}.tar.gz"

# 先尝试直连，失败则使用 --resolve 绕过 DNS 污染 (你原脚本的技巧)
if ! curl -L -o ${TARBALL} --connect-timeout 10 --retry 2 $DOWNLOAD_URL; then
    echo -e "${YELLOW}直连失败，尝试使用 GitHub IP 直连...${PLAIN}"
    curl -L --resolve github.com:443:140.82.121.4 -o ${TARBALL} $DOWNLOAD_URL || {
        echo -e "${RED}下载失败，请检查网络${PLAIN}"; exit 1
    }
fi

ls -lh ${TARBALL}
tar xvf ${TARBALL} -C /tmp
chmod +x /tmp/realm
mv -f /tmp/realm $BIN_PATH
ln -sf $BIN_PATH /usr/local/bin/realm
$BIN_PATH --version

# --- 4. 生成 config.toml ---
echo -e "${GREEN}[4/6] 生成配置文件...${PLAIN}"
cat > $CONFIG_FILE <<EOF
# realm 转发配置 - 由一键脚本生成
# 监听: ${LISTEN} -> 落地: ${REMOTE}
# 生成时间: $(date)

[network]
no_tcp = false
use_udp = true

[[endpoints]]
listen = "${LISTEN}"
remote = "${REMOTE}"

[[endpoints]]
listen = "${LISTEN}"
remote = "${REMOTE}"
remote_type = "udp"
EOF

# 其实 realm 新版本一个 endpoint 自动支持 tcp+udp，上面的双写是为了兼容
# 简化为单条 (更推荐):
cat > $CONFIG_FILE <<EOF
[network]
no_tcp = false
use_udp = true

[[endpoints]]
listen = "${LISTEN}"
remote = "${REMOTE}"
EOF

echo -e "${PLAIN}配置文件已写入: $CONFIG_FILE"
cat $CONFIG_FILE

# --- 5. 创建 systemd 服务 ---
echo -e "${GREEN}[5/6] 创建 systemd 服务...${PLAIN}"
cat > $SERVICE_FILE <<EOF
[Unit]
Description=realm - A lightweight, high-performance relay server
After=network.target
Wants=network.target

[Service]
Type=simple
User=root
ExecStart=${BIN_PATH} -c ${CONFIG_FILE}
Restart=always
RestartSec=3
LimitNOFILE=1048576
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable realm >/dev/null 2>&1
systemctl restart realm

# --- 6. 放行防火墙 & 检查 ---
echo -e "${GREEN}[6/6] 检查运行状态...${PLAIN}"
sleep 2
systemctl status realm --no-pager -l | head -n 20

if command -v ufw >/dev/null 2>&1; then
    ufw allow ${LISTEN_PORT}/tcp >/dev/null 2>&1 || true
    ufw allow ${LISTEN_PORT}/udp >/dev/null 2>&1 || true
fi
if command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port=${LISTEN_PORT}/tcp >/dev/null 2>&1 || true
    firewall-cmd --permanent --add-port=${LISTEN_PORT}/udp >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
fi

echo ""
echo -e "${GREEN}=== 安装完成 ===${PLAIN}"
echo -e "监听: ${YELLOW}${LISTEN}${PLAIN}"
echo -e "转发到: ${YELLOW}${REMOTE}${PLAIN}"
echo -e "配置: ${YELLOW}${CONFIG_FILE}${PLAIN}"
echo -e "二进制: ${YELLOW}${BIN_PATH}${PLAIN}"
echo ""
echo -e "常用命令:"
echo -e "  查看日志: ${YELLOW}journalctl -u realm -f${PLAIN}"
echo -e "  重启服务: ${YELLOW}systemctl restart realm${PLAIN}"
echo -e "  修改配置: ${YELLOW}vim ${CONFIG_FILE} && systemctl restart realm${PLAIN}"
echo -e "  查看端口: ${YELLOW}ss -tlnp | grep ${LISTEN_PORT}${PLAIN}"
echo -e "  卸载: ${YELLOW}bash <(curl -sL https://raw.githubusercontent.com/YOUR_USERNAME/realm-forwarder/main/uninstall.sh)${PLAIN}"
ss -tlnp | grep -E "${LISTEN_PORT}|realm" || true
