bash <(curl -fsSL https://raw.githubusercontent.com/jake712/srbvps/main/autow.sh)

curl -L https://raw.githubusercontent.com/jake712/realm/main/realm.sh | bash -s -- 38509 198.12.95.40 42039
# 然後前台跑
/opt/realm/realm -c /etc/realm/config.toml
