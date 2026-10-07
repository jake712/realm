#!/bin/bash
set -e

# 必須 root
if [ "$EUID" -ne 0 ]; then
  echo "請用 root 執行: sudo bash $0 [監聽端口] [落地IP] [落地端口]"
  exit 1
fi

# --- 1. 你的原始邏輯 保留 ---
echo -e "nameserver 1.1.1.1\nnameserver 8.8.8.8" > /etc/resolv.conf
cat /etc/resolv.conf
ping 1.1.1.1 -c 1



curl -L --resolve github.com:443:140.82.121.4 -o realm.tar.gz https://github.com/zhboner/realm/releases/download/v2.7.0/realm-x86_64-unknown-linux-musl.tar.gz

ls -lh realm.tar.gz
tar xvf realm.tar.gz
chmod +x realm
./realm --version
mv -f realm /usr/local/bin/realm

# --- 2. 自定義端口和IP ---
# 用法: bash install.sh 38509 198.12.95.40 42039
# 不帶參數就會互動輸入

LISTEN_PORT=${1:-}
REMOTE_IP=${2:-}
REMOTE_PORT=${3:-}

if [ -z "$LISTEN_PORT" ]; then
  read -p "請輸入監聽端口 [38509]: " LISTEN_PORT
  LISTEN_PORT=${LISTEN_PORT:-38509}
fi

if [ -z "$REMOTE_IP" ]; then
  read -p "請輸入落地IP [198.12.95.40]: " REMOTE_IP
  REMOTE_IP=${REMOTE_IP:-198.12.95.40}
fi

if [ -z "$REMOTE_PORT" ]; then
  read -p "請輸入落地端口 [42039]: " REMOTE_PORT
  REMOTE_PORT=${REMOTE_PORT:-42039}
fi

echo ""
echo "配置: 0.0.0.0:$LISTEN_PORT -> $REMOTE_IP:$REMOTE_PORT"

# --- 3. 生成 config.toml ---
mkdir -p /etc/realm
cat > /etc/realm/config.toml <<EOF
[[endpoints]]
listen = "0.0.0.0:$LISTEN_PORT"
remote = "$REMOTE_IP:$REMOTE_PORT"
EOF

# 同時在當前目錄也生成一份，方便你./realm -c config.toml
cat >./config.toml <<EOF
[[endpoints]]
listen = "0.0.0.0:$LISTEN_PORT"
remote = "$REMOTE_IP:$REMOTE_PORT"
EOF

cat /etc/realm/config.toml
echo ""

# --- 4. 啟動 ---
# 創建 systemd 自啟動
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

echo "=============================="
echo "安裝並啟動完成！"
echo "配置文件: /etc/realm/config.toml"
echo "手動前台運行: /usr/local/bin/realm -c /etc/realm/config.toml"
echo "查看日誌: journalctl -u realm -f"
echo "=============================="
