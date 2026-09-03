#!/bin/bash
if [ "$EUID" -ne 0 ]; then echo "Jalankan sebagai root"; exit 1; fi

# === UBAH VARIABEL INI ===
MASTER_IP="111.222.333.111"    # IP Server Primary
MASTER_NS="ns1.domainanda.com" # Hostname Server Primary
DB_NAME="powerdns_slave"
DB_USER="pdns_slave_user"
DB_PASS="P@ss_Slave_$(date +%s)"
# =========================

apt update && apt upgrade -y
export DEBIAN_FRONTEND=noninteractive
apt install -y mariadb-server pdns-server pdns-backend-mysql curl ufw

systemctl enable --now mariadb
mysql -e "CREATE DATABASE IF NOT EXISTS $DB_NAME;"
mysql -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';"
mysql -e "FLUSH PRIVILEGES;"

SCHEMA=$(ls /usr/share/doc/pdns-backend-mysql/schema.mysql.sql* 2>/dev/null | head -n 1)
if [[ $SCHEMA == *.gz ]]; then zcat "$SCHEMA" | mysql $DB_NAME; else cat "$SCHEMA" | mysql $DB_NAME; fi

mysql $DB_NAME -e "INSERT INTO supermasters (ip, nameserver, account) VALUES ('$MASTER_IP', '$MASTER_NS', 'admin');"

rm -f /etc/powerdns/pdns.d/bind.conf
cat <<EOF > /etc/powerdns/pdns.d/pdns.local.gmysql.conf
launch=gmysql
gmysql-host=127.0.0.1
gmysql-port=3306
gmysql-dbname=$DB_NAME
gmysql-user=$DB_USER
gmysql-password=$DB_PASS
gmysql-dnssec=yes
EOF

cat <<EOF >> /etc/powerdns/pdns.conf
secondary=yes
autosecondary=yes
EOF

systemctl disable --now systemd-resolved
rm -f /etc/resolv.conf
echo "nameserver 8.8.8.8" > /etc/resolv.conf

systemctl restart pdns && systemctl enable pdns

ufw allow 53/tcp
ufw allow 53/udp
ufw --force enable

echo -e "\n=== NS2 SELESAI ==="
echo "Server siap menerima sync dari $MASTER_IP"
