#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
  echo "請用 root: sudo bash \$0 [監聽端口] [落地IP] [落地端口]"
  exit 1
fi

echo -e "nameserver 1.1.1.1\nnameserver 8.8.8.8" > /etc/resolv.conf
ping 1.1.1.1 -c 1

cd /tmp
rm -rf realm.tar.gz realm realm-install
mkdir realm-install && cd realm-install
curl -L --resolve github.com:443:140.82.121.4 -o realm.tar.gz https://github.com/zhboner/realm/releases/download/v2.7.0/realm-x86_64-unknown-linux-musl.tar.gz
ls -lh realm.tar.gz
tar xvf realm.tar.gz
chmod +x realm
./realm --version
mv -f realm /usr/local/bin/realm

# 自定義參數
LISTEN_PORT=${1:-}
REMOTE_IP=${2:-}
REMOTE_PORT=${3:-}

[ -z "$LISTEN_PORT" ] && read -p "監聽端口 [38509]: " LISTEN_PORT && LISTEN_PORT=${LISTEN_PORT:-38509}
[ -z "$REMOTE_IP" ] && read -p "落地IP [198.12.95.40]: " REMOTE_IP && REMOTE_IP=${REMOTE_IP:-198.12.95.40}
[ -z "$REMOTE_PORT" ] && read -p "落地端口 [42039]: " REMOTE_PORT && REMOTE_PORT=${REMOTE_PORT:-42039}

echo "配置: 0.0.0.0:$LISTEN_PORT -> $REMOTE_IP:$REMOTE_PORT"

mkdir -p /etc/realm
mkdir -p /etc/systemd/system

cat > /etc/realm/config.toml <<EOF
[[endpoints]]
listen = "0.0.0.0:$LISTEN_PORT"
remote = "$REMOTE_IP:$REMOTE_PORT"
EOF

cat >./config.toml <<EOF
[[endpoints]]
listen = "0.0.0.0:$LISTEN_PORT"
remote = "$REMOTE_IP:$REMOTE_PORT"
EOF

cat /etc/realm/config.toml

# 判斷是不是 systemd 系統
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  cat > /etc/systemd/system/realm.service <<SERVICE
[Unit]
Description=realm
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=/usr/local/bin/realm -c /etc/realm/config.toml
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
SERVICE
  systemctl daemon-reload
  systemctl enable --now realm
  echo "已用 systemd 啟動"
  systemctl status realm --no-pager || true
else
  echo "檢測到非 systemd 系統，改用 nohup 後台運行"
  nohup /usr/local/bin/realm -c /etc/realm/config.toml >/var/log/realm.log 2>&1 &
  echo "後台運行中: ps aux | grep realm"
  echo "日誌: tail -f /var/log/realm.log"
  echo "手動運行:./realm -c config.toml"
fi
