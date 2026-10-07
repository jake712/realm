#!/bin/bash
# realm.sh - 兼容 systemd / 非 systemd 系统最终版 - 修复版
# 用法: sudo bash realm.sh 38509 198.12.95.40 42039
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; PLAIN='\033[0m'

REALM_VERSION="v2.7.0"
INSTALL_DIR="/opt/realm"
CONFIG_DIR="/etc/realm"
CONFIG_FILE="${CONFIG_DIR}/config.toml"
BIN_PATH="${INSTALL_DIR}/realm"
SERVICE_FILE="/etc/systemd/system/realm.service"
SERVICE_DIR="/etc/systemd/system"

LISTEN_ADDR="0.0.0.0"
LISTEN_PORT=""
REMOTE_IP=""
REMOTE_PORT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -l|--listen-port) LISTEN_PORT="$2"; shift 2;;
        -a|--listen-addr) LISTEN_ADDR="$2"; shift 2;;
        -i|--remote-ip) REMOTE_IP="$2"; shift 2;;
        -p|--remote-port) REMOTE_PORT="$2"; shift 2;;
        -v|--version) REALM_VERSION="$2"; shift 2;;
        -h|--help) echo "用法: $0 <本机端口> <落地IP> <落地端口>"; exit 0;;
        *) if [[ -z "$LISTEN_PORT" ]]; then LISTEN_PORT="$1"
           elif [[ -z "$REMOTE_IP" ]]; then REMOTE_IP="$1"
           elif [[ -z "$REMOTE_PORT" ]]; then REMOTE_PORT="$1"
           else echo "未知参数 $1"; exit 1; fi; shift;;
    esac
done

[[ -z "$LISTEN_PORT" ]] && read -p "本机端口 [38509]: " i && LISTEN_PORT=${i:-38509}
[[ -z "$REMOTE_IP" ]] && read -p "落地IP: " REMOTE_IP && [[ -z "$REMOTE_IP" ]] && exit 1
[[ -z "$REMOTE_PORT" ]] && read -p "落地端口 [42039]: " i && REMOTE_PORT=${i:-42039}

LISTEN="${LISTEN_ADDR}:${LISTEN_PORT}"
REMOTE="${REMOTE_IP}:${REMOTE_PORT}"

echo -e "${GREEN}=== realm.sh 安装 ${LISTEN} -> ${REMOTE} ===${PLAIN}"

if [[ $EUID -ne 0 ]]; then echo -e "${RED}请用 root 运行${PLAIN}"; exit 1; fi

echo -e "${GREEN}[1/5] 修复 DNS...${PLAIN}"
echo -e "nameserver 1.1.1.1\nnameserver 8.8.8.8" > /etc/resolv.conf 2>/dev/null || true
ping 1.1.1.1 -c 1 -W 2 >/dev/null 2>&1 || echo -e "${YELLOW}ping 失败，继续${PLAIN}"

echo -e "${GREEN}[2/5] 检测架构...${PLAIN}"
ARCH=$(uname -m)
case $ARCH in
    x86_64|amd64) REALM_ARCH="x86_64-unknown-linux-musl" ;;
    aarch64|arm64) REALM_ARCH="aarch64-unknown-linux-musl" ;;
    armv7l) REALM_ARCH="armv7-unknown-linux-musleabihf" ;;
    *) echo -e "${RED}不支持 $ARCH${PLAIN}"; exit 1;;
esac

echo -e "${GREEN}[3/5] 下载 realm ${REALM_VERSION}...${PLAIN}"
mkdir -p $INSTALL_DIR $CONFIG_DIR
mkdir -p $SERVICE_DIR || true
cd /tmp
TARBALL="realm-${REALM_ARCH}.tar.gz"
URL="https://github.com/zhboner/realm/releases/download/${REALM_VERSION}/realm-${REALM_ARCH}.tar.gz"

rm -f $TARBALL realm
if ! curl -L -o $TARBALL --connect-timeout 10 --retry 2 $URL; then
    echo -e "${YELLOW}直连失败，尝试 --resolve 绕过...${PLAIN}"
    curl -L --resolve github.com:443:140.82.121.4 -o $TARBALL $URL || { echo -e "${RED}下载失败${PLAIN}"; exit 1; }
fi
tar xvf $TARBALL -C /tmp
chmod +x /tmp/realm
mv -f /tmp/realm $BIN_PATH
ln -sf $BIN_PATH /usr/local/bin/realm
$BIN_PATH --version

echo -e "${GREEN}[4/5] 生成配置...${PLAIN}"
cat > $CONFIG_FILE <<EOF
[network]
no_tcp = false
use_udp = true

[[endpoints]]
listen = "${LISTEN}"
remote = "${REMOTE}"
EOF
cat $CONFIG_FILE

echo -e "${GREEN}[5/5] 启动...${PLAIN}"

if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    echo -e "${GREEN}检测到 systemd，使用 systemd 启动...${PLAIN}"
    cat > $SERVICE_FILE <<EOF
[Unit]
Description=realm relay ${LISTEN} -> ${REMOTE}
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
    systemctl enable realm >/dev/null 2>&1 || true
    systemctl restart realm
    sleep 1
    systemctl status realm --no-pager -l | head -n 30 || true
else
    echo -e "${YELLOW}未检测到 systemd，改用 nohup 后台启动...${PLAIN}"
    pkill -f "${BIN_PATH}.*${CONFIG_FILE}" || true
    nohup $BIN_PATH -c $CONFIG_FILE > ${INSTALL_DIR}/realm.log 2>&1 &
    sleep 1
    ps aux | grep -v grep | grep realm || true
    (crontab -l 2>/dev/null; echo "@reboot ${BIN_PATH} -c ${CONFIG_FILE} >/dev/null 2>&1 &") | crontab - 2>/dev/null || true
    echo -e "${GREEN}nohup 启动完成，日志: ${INSTALL_DIR}/realm.log${PLAIN}"
fi

ss -tlnp 2>/dev/null | grep -E "${LISTEN_PORT}|realm" || netstat -tlnp 2>/dev/null | grep -E "${LISTEN_PORT}|realm" || ps aux | grep realm | grep -v grep || true
echo -e "${GREEN}完成: ${LISTEN} -> ${REMOTE}${PLAIN}"
