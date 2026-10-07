#!/bin/bash
# realm 一键转发安装脚本 - 文件名: realm.sh
# 用法: bash <(curl -sL https://raw.githubusercontent.com/你的用户名/你的仓库/main/realm.sh) 38509 198.12.95.40 42039
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; PLAIN='\033[0m'

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

usage() {
    echo -e "${GREEN}realm 转发 - realm.sh${PLAIN}"
    echo "用法1: $0 <本机端口> <落地IP> <落地端口>"
    echo "  示例: $0 38509 198.12.95.40 42039"
    echo "用法2: $0 -l <本机端口> -i <落地IP> -p <落地端口>"
    echo "一键远程: bash <(curl -sL https://raw.githubusercontent.com/用户名/仓库/main/realm.sh) 38509 198.12.95.40 42039"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -l|--listen-port) LISTEN_PORT="$2"; shift 2;;
        -a|--listen-addr) LISTEN_ADDR="$2"; shift 2;;
        -i|--remote-ip) REMOTE_IP="$2"; shift 2;;
        -p|--remote-port) REMOTE_PORT="$2"; shift 2;;
        -r|--remote) REMOTE_ADDR="$2"; shift 2;;
        -v|--version) REALM_VERSION="$2"; shift 2;;
        -h|--help) usage;;
        *) if [[ -z "$LISTEN_PORT" ]]; then LISTEN_PORT="$1"
           elif [[ -z "$REMOTE_IP" ]]; then REMOTE_IP="$1"
           elif [[ -z "$REMOTE_PORT" ]]; then REMOTE_PORT="$1"
           else usage; fi; shift;;
    esac
done

if [[ -n "$REMOTE_ADDR" && -z "$REMOTE_IP" ]]; then
    REMOTE_IP=$(echo $REMOTE_ADDR | cut -d: -f1)
    REMOTE_PORT=$(echo $REMOTE_ADDR | cut -d: -f2)
fi

# 交互式
if [[ -z "$LISTEN_PORT" ]]; then read -p "本机监听端口 [38509]: " i; LISTEN_PORT=${i:-38509}; fi
if [[ -z "$REMOTE_IP" ]]; then read -p "落地IP: " REMOTE_IP; [[ -z "$REMOTE_IP" ]] && exit 1; fi
if [[ -z "$REMOTE_PORT" ]]; then read -p "落地端口 [42039]: " i; REMOTE_PORT=${i:-42039}; fi

LISTEN="${LISTEN_ADDR}:${LISTEN_PORT}"
REMOTE="${REMOTE_IP}:${REMOTE_PORT}"

echo -e "${GREEN}=== realm 一键安装 (realm.sh) ===${PLAIN}"
echo -e "监听: ${YELLOW}${LISTEN}${PLAIN} -> 落地: ${YELLOW}${REMOTE}${PLAIN}"

if [[ $EUID -ne 0 ]]; then echo -e "${RED}请用 root: sudo bash $0${PLAIN}"; exit 1; fi

echo -e "${GREEN}[1/6] 修复 DNS...${PLAIN}"
echo -e "nameserver 1.1.1.1\nnameserver 8.8.8.8" > /etc/resolv.conf
ping 1.1.1.1 -c 1 -W 2 >/dev/null 2>&1 || echo -e "${YELLOW}ping 失败，继续${PLAIN}"

echo -e "${GREEN}[2/6] 检测架构...${PLAIN}"
ARCH=$(uname -m)
case $ARCH in
    x86_64|amd64) REALM_ARCH="x86_64-unknown-linux-musl" ;;
    aarch64|arm64) REALM_ARCH="aarch64-unknown-linux-musl" ;;
    armv7l) REALM_ARCH="armv7-unknown-linux-musleabihf" ;;
    *) echo -e "${RED}不支持架构: $ARCH${PLAIN}"; exit 1;;
esac

echo -e "${GREEN}[3/6] 下载 realm ${REALM_VERSION}...${PLAIN}"
mkdir -p $INSTALL_DIR $CONFIG_DIR
cd /tmp
TARBALL="realm-${REALM_ARCH}.tar.gz"
URL="https://github.com/zhboner/realm/releases/download/${REALM_VERSION}/realm-${REALM_ARCH}.tar.gz"
if ! curl -L -o ${TARBALL} --connect-timeout 10 --retry 2 $URL; then
    echo -e "${YELLOW}直连失败，尝试 --resolve...${PLAIN}"
    curl -L --resolve github.com:443:140.82.121.4 -o ${TARBALL} $URL || { echo -e "${RED}下载失败${PLAIN}"; exit 1; }
fi
tar xvf ${TARBALL} -C /tmp
chmod +x /tmp/realm
mv -f /tmp/realm $BIN_PATH
ln -sf $BIN_PATH /usr/local/bin/realm
$BIN_PATH --version

echo -e "${GREEN}[4/6] 生成配置...${PLAIN}"
cat > $CONFIG_FILE <<EOF
[network]
no_tcp = false
use_udp = true

[[endpoints]]
listen = "${LISTEN}"
remote = "${REMOTE}"
EOF
cat $CONFIG_FILE

echo -e "${GREEN}[5/6] 创建 systemd 服务...${PLAIN}"
cat > $SERVICE_FILE <<EOF
[Unit]
Description=realm relay
After=network.target

[Service]
Type=simple
User=root
ExecStart=${BIN_PATH} -c ${CONFIG_FILE}
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable realm >/dev/null 2>&1
systemctl restart realm
sleep 1
systemctl status realm --no-pager -l | head -n 20

echo -e "${GREEN}[6/6] 放行防火墙...${PLAIN}"
command -v ufw >/dev/null 2>&1 && { ufw allow ${LISTEN_PORT}/tcp; ufw allow ${LISTEN_PORT}/udp; } || true
command -v firewall-cmd >/dev/null 2>&1 && { firewall-cmd --permanent --add-port=${LISTEN_PORT}/tcp; firewall-cmd --permanent --add-port=${LISTEN_PORT}/udp; firewall-cmd --reload; } || true

echo -e "${GREEN}安装完成: ${LISTEN} -> ${REMOTE}${PLAIN}"
ss -tlnp | grep -E "${LISTEN_PORT}|realm" || ps aux | grep realm | grep -v grep
echo -e "日志: journalctl -u realm -f"
