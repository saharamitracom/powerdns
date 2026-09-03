#!/bin/bash
if [ "$EUID" -ne 0 ]; then echo "Jalankan sebagai root"; exit 1; fi

clear
echo "=============================================="
echo " INSTALASI POWERDNS PRIMARY (NS1) & POWERADMIN"
echo "=============================================="
read -p "Masukkan IP Publik Server Secondary (NS2): " NS2_IP

# Validasi format IP
if [[ ! $NS2_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Error: Format IP tidak valid!"
    exit 1
fi

DB_NAME="powerdns"
DB_USER="powerdns_user"
DB_PASS="P@ss_Primary_$(date +%s)"
WEB_DIR="/var/www/html/poweradmin"

apt update && apt upgrade -y
apt install -y mariadb-server apache2 php libapache2-mod-php php-mysql php-xml php-mbstring php-curl gettext git unzip curl ufw

systemctl enable --now mariadb
mysql -e "CREATE DATABASE IF NOT EXISTS $DB_NAME;"
mysql -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';"
mysql -e "FLUSH PRIVILEGES;"

export DEBIAN_FRONTEND=noninteractive
apt install -y pdns-server pdns-backend-mysql

SCHEMA=$(ls /usr/share/doc/pdns-backend-mysql/schema.mysql.sql* 2>/dev/null | head -n 1)
if [[ $SCHEMA == *.gz ]]; then zcat "$SCHEMA" | mysql $DB_NAME; else cat "$SCHEMA" | mysql $DB_NAME; fi

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

# Konfigurasi NS Primary
primary=yes
allow-axfr-ips=$NS2_IP
also-notify=$NS2_IP
EOF

systemctl disable --now systemd-resolved
rm -f /etc/resolv.conf
echo "nameserver 8.8.8.8" > /etc/resolv.conf

systemctl restart pdns && systemctl enable pdns

rm -rf $WEB_DIR
git clone https://github.com/poweradmin/poweradmin.git $WEB_DIR
chown -R www-data:www-data /var/www/html/
chmod -R 755 /var/www/html/

ufw allow 80/tcp
ufw allow 53/tcp
ufw allow 53/udp
ufw --force enable

echo -e "\n=============================================="
echo " INSTALASI NS1 SELESAI"
echo "=============================================="
echo "Database: $DB_NAME | User: $DB_USER | Pass: $DB_PASS"
echo "Buka: http://$(hostname -I | awk '{print $1}')/poweradmin/install/"
echo "=============================================="
