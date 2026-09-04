#!/usr/bin/env bash
#===============================================================================
# install_ns1.sh — PowerDNS Authoritative PRIMARY (NS1) + Poweradmin
#
#   Target OS : Debian 13 (trixie) / Debian 12 (bookworm)
#   Jalankan  : sudo ./install_ns1.sh
#   Log       : /var/log/install_ns1.log
#
#   Script menanyakan seluruh input di awal, menampilkan ringkasan, lalu
#   mengeksekusi tanpa interupsi lagi.
#===============================================================================
set -Eeuo pipefail

PA_DIR="/var/www/poweradmin"
PA_REPO="https://github.com/poweradmin/poweradmin.git"
CRED_FILE="/root/powerdns-ns1-credentials.txt"
NS2_ENV_FILE="/root/ns2-setup.env"
LOG_FILE="/var/log/install_ns1.log"
STAMP="$(date +%Y%m%d-%H%M%S)"
SERIAL="$(date +%Y%m%d)01"

DB_NAME="${DB_NAME:-powerdns}"
DB_USER="${DB_USER:-powerdns_user}"

#-------------------------------------------------------------------- helper --
info() { printf '\033[1;34m[INFO ]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK  ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN ]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

on_err() {
  local rc=$? line=$1
  printf '\033[1;31m[FATAL]\033[0m Gagal pada baris %s (exit %s). Log: %s\n' "$line" "$rc" "$LOG_FILE" >&2
  exit "$rc"
}
trap 'on_err $LINENO' ERR

valid_ip() {
  local ip="$1" a b c d o
  [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
  IFS=. read -r a b c d <<<"$ip"
  for o in "$a" "$b" "$c" "$d"; do
    [ "$o" -ge 0 ] 2>/dev/null && [ "$o" -le 255 ] || return 1
  done
  return 0
}
valid_host() {
  [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]]
}
valid_email() {
  [[ "$1" =~ ^[A-Za-z0-9._%+-]+@([A-Za-z0-9-]+\.)+[A-Za-z]{2,}$ ]]
}
detect_ip() {
  ip -4 route get 1.1.1.1 2>/dev/null \
    | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
}

# --- port 53 ---------------------------------------------------------------
# PowerDNS bind ke 0.0.0.0:53, jadi bentrok juga dengan stub 127.0.0.53:53.
show_port53() {
  ss -lunp 'sport = :53' 2>/dev/null || true
  ss -ltnp 'sport = :53' 2>/dev/null || true
}

free_port53() {
  local svc pids
  # Hentikan pdns sendiri dulu supaya tidak bentrok dengan instance lamanya.
  systemctl stop pdns        >/dev/null 2>&1 || true
  systemctl reset-failed pdns >/dev/null 2>&1 || true

  for svc in systemd-resolved dnsmasq bind9 named unbound pdns-recursor; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      warn "Layanan '$svc' aktif dan memakai port 53 — dinonaktifkan."
      systemctl disable --now "$svc" >/dev/null 2>&1 || true
    fi
  done
  sleep 1

  local busy
  busy="$(ss -lun 'sport = :53' 2>/dev/null | tail -n +2)"
  if [ -n "$busy" ]; then
    warn "Port 53/UDP masih dipakai:"
    show_port53
    pids="$(ss -lunp 'sport = :53' 2>/dev/null | grep -oE 'pid=[0-9]+' \
            | cut -d= -f2 | sort -u | tr '\n' ' ')"
    if [ -n "$pids" ]; then
      warn "PID pemakai: $pids"
      ps -o pid,ppid,user,cmd -p $pids 2>/dev/null || true
    fi
    return 1
  fi
  return 0
}

# ask VAR "Pertanyaan" "default" validator
ask() {
  local __var="$1" prompt="$2" def="${3:-}" fn="${4:-}" val=""
  local shown="$prompt"
  [ -n "$def" ] && shown="$prompt [$def]"
  while :; do
    read -r -p "  $shown: " val
    val="${val:-$def}"
    val="$(printf '%s' "$val" | tr -d '[:space:]')"
    if [ -z "$val" ]; then warn "Tidak boleh kosong."; continue; fi
    if [ -n "$fn" ] && ! "$fn" "$val"; then warn "Format tidak valid."; continue; fi
    printf -v "$__var" '%s' "$val"
    return 0
  done
}

#---------------------------------------------------------------- pra-syarat --
[ "$(id -u)" -eq 0 ] || die "Script harus dijalankan sebagai root (gunakan: sudo $0)"
command -v systemctl >/dev/null || die "systemd tidak ditemukan. OS tidak didukung."
command -v apt-get   >/dev/null || die "apt-get tidak ditemukan. OS tidak didukung."

clear || true
echo "=============================================================="
echo "  SETUP POWERDNS PRIMARY (NS1) + POWERADMIN"
echo "=============================================================="
if [ -r /etc/os-release ]; then
  . /etc/os-release
  echo "  OS: ${PRETTY_NAME:-unknown}"
  [ "${ID:-}" = "debian" ] || warn "Script diuji untuk Debian 12/13."
fi
echo

#===============================================================================
# WIZARD — seluruh input dikumpulkan di sini
#===============================================================================
DETECTED_IP="$(detect_ip || true)"

echo "--- [1/4] Identitas nameserver -------------------------------"
ask DOMAIN    "Domain utama"        ""                         valid_host
ask NS1_HOST  "Hostname NS1"        "ns1.${DOMAIN}"            valid_host
ask NS1_IP    "IP publik NS1"       "${DETECTED_IP}"           valid_ip
ask NS2_HOST  "Hostname NS2"        "ns2.${DOMAIN}"            valid_host
ask NS2_IP    "IP publik NS2"       ""                         valid_ip
echo
echo "--- [2/4] Kontak ---------------------------------------------"
ask ADMIN_EMAIL "Email hostmaster"  "hostmaster@${DOMAIN}"     valid_email
echo
echo "--- [3/4] Panel Poweradmin -----------------------------------"
ask PANEL_HOST  "Hostname panel"    "dns.${DOMAIN}"            valid_host
echo

[ "$NS1_IP" != "$NS2_IP" ] || die "IP NS1 dan NS2 tidak boleh sama."
[ "$NS1_HOST" != "$NS2_HOST" ] || die "Hostname NS1 dan NS2 tidak boleh sama."

# RNAME SOA: user@domain -> user.domain
SOA_RNAME="${ADMIN_EMAIL/@/.}"

echo "--- [4/4] Ringkasan ------------------------------------------"
printf '  %-22s %s\n' "Domain utama"      "$DOMAIN"
printf '  %-22s %s (%s)\n' "Primary  NS1"  "$NS1_HOST" "$NS1_IP"
printf '  %-22s %s (%s)\n' "Secondary NS2" "$NS2_HOST" "$NS2_IP"
printf '  %-22s %s\n' "Email hostmaster"  "$ADMIN_EMAIL"
printf '  %-22s https://%s\n' "Panel Poweradmin" "$PANEL_HOST"
printf '  %-22s %s / %s (password acak)\n' "Database" "$DB_NAME" "$DB_USER"
echo
echo "  Yang akan dilakukan:"
echo "   - pasang MariaDB, Apache, PHP, PowerDNS, Poweradmin"
echo "   - matikan systemd-resolved (bebaskan port 53)"
echo "   - buat zona $DOMAIN + record NS/A untuk $NS1_HOST dan $NS2_HOST"
echo "   - pasang sertifikat Let's Encrypt untuk $PANEL_HOST"
echo "   - aktifkan UFW (SSH tetap dibuka)"
echo
read -r -p "  Lanjutkan instalasi? [y/N]: " CONFIRM
[[ "${CONFIRM,,}" == "y" ]] || die "Dibatalkan oleh pengguna."
echo

#===============================================================================
# EKSEKUSI
#===============================================================================
touch "$LOG_FILE" && chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1
info "Mulai instalasi $STAMP"

if [ -f /etc/powerdns/pdns.d/pdns.local.gmysql.conf ]; then
  warn "Konfigurasi PowerDNS lama ditemukan — akan ditimpa (backup dibuat)."
fi

export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

info "Memperbarui indeks paket..."
apt-get update
info "Upgrade sistem..."
apt-get "${APT_OPTS[@]}" upgrade

info "Memasang MariaDB, Apache, PHP dan dependensi..."
apt-get "${APT_OPTS[@]}" install \
  mariadb-server mariadb-client \
  apache2 libapache2-mod-php \
  php-cli php-mysql php-xml php-mbstring php-curl php-intl php-gd php-zip \
  git curl ca-certificates openssl ufw dnsutils unzip

#------------------------------------------ bebaskan port 53 SEBELUM install --
info "Menonaktifkan systemd-resolved (membebaskan port 53)..."
# CATATAN: jangan pakai `systemctl ... | grep -q` di sini. Di bawah
# `set -o pipefail`, grep -q keluar lebih dulu, systemd-resolved kena SIGPIPE
# (exit 141), dan seluruh pipeline dianggap gagal -> disable tidak pernah jalan.
systemctl disable --now systemd-resolved >/dev/null 2>&1 || true
systemctl stop         systemd-resolved >/dev/null 2>&1 || true
if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
  warn "systemd-resolved masih aktif setelah disable — akan ditangani free_port53()."
fi
# Resolver upstream yang sudah bekerja di server ini — dipakai sebagai cadangan.
# Di banyak jaringan (termasuk ISP), DNS publik 1.1.1.1/8.8.8.8 diblokir keluar.
UPSTREAM_NS="$(awk '/^[[:space:]]*nameserver/ && $2 !~ /^127\./ {print $2}' \
                 /etc/resolv.conf 2>/dev/null | head -2 | tr '\n' ' ')"

if [ -e /etc/resolv.conf ]; then
  cp -aL /etc/resolv.conf "/etc/resolv.conf.bak.$STAMP" 2>/dev/null || true
  rm -f /etc/resolv.conf
fi

write_resolv() {
  local ns
  : > /etc/resolv.conf
  for ns in "$@"; do printf 'nameserver %s\n' "$ns" >> /etc/resolv.conf; done
  printf 'options timeout:2 attempts:2\n' >> /etc/resolv.conf
  chmod 644 /etc/resolv.conf
}
dns_works() { getent hosts deb.debian.org >/dev/null 2>&1; }
current_ns() { awk '/^nameserver/{printf "%s ", $2}' /etc/resolv.conf; }

if [ -n "${RESOLVERS:-}" ]; then
  # shellcheck disable=SC2086
  write_resolv $RESOLVERS
elif [ -n "$UPSTREAM_NS" ]; then
  # shellcheck disable=SC2086
  write_resolv $UPSTREAM_NS 1.1.1.1
else
  write_resolv 1.1.1.1 8.8.8.8
fi

if ! dns_works; then
  warn "Resolver saat ini tidak menjawab — mencoba DNS publik."
  write_resolv 1.1.1.1 8.8.8.8
fi

dns_works || die "Resolusi DNS tidak berfungsi (resolver dicoba: $(current_ns)).
       Jalankan ulang dengan resolver yang benar, contoh:
         RESOLVERS='10.10.10.1 10.10.10.2' $0"
ok "Resolver sistem: $(current_ns)"

info "Memasang PowerDNS Authoritative Server..."
apt-get "${APT_OPTS[@]}" install pdns-server pdns-backend-mysql

#------------------------------------------------------------------ database --
info "Menyiapkan MariaDB..."
systemctl enable --now mariadb

DB_PASS="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-28)"
[ ${#DB_PASS} -ge 20 ] || die "Gagal membuat password acak."

mysql --protocol=socket -uroot <<SQLEOF
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQLEOF
ok "Database '$DB_NAME' dan user '$DB_USER' siap."

#--------------------------------------------------------- import skema pdns --
# Direktori schema juga berisi berkas migrasi (mis. 3.4.0_to_4.1.0_schema.mysql.sql).
# Pola harus dikunci ke nama berkas persis 'schema.mysql.sql', bukan akhirannya saja.
find_schema() {
  local f=""
  f="$(dpkg -L pdns-backend-mysql 2>/dev/null | grep -E '/schema\.mysql\.sql(\.gz)?$' | head -n1 || true)"
  if [ -z "$f" ]; then
    f="$(find /usr/share/pdns-backend-mysql \
              /usr/share/doc/pdns-backend-mysql \
              /usr/share/doc/pdns-server \
              /usr/share/dbconfig-common/data \
              \( -name 'schema.mysql.sql' -o -name 'schema.mysql.sql.gz' \) \
              2>/dev/null | head -n1 || true)"
  fi
  printf '%s' "$f"
}

# Pastikan berkas yang dipilih memang skema awal (membuat tabel), bukan migrasi.
schema_is_full() {
  local f="$1"
  if [[ "$f" == *.gz ]]; then
    zgrep -qiE 'CREATE TABLE( IF NOT EXISTS)? +.?domains' "$f"
  else
    grep  -qiE 'CREATE TABLE( IF NOT EXISTS)? +.?domains' "$f"
  fi
}

if [ -n "$(mysql -N -B "$DB_NAME" -e "SHOW TABLES LIKE 'domains';" 2>/dev/null)" ]; then
  info "Skema PowerDNS sudah ada — import dilewati."
else
  SCHEMA="$(find_schema)"
  [ -n "$SCHEMA" ] || die "schema.mysql.sql tidak ditemukan. Cek: dpkg -L pdns-backend-mysql | grep schema"
  schema_is_full "$SCHEMA" \
    || die "Berkas '$SCHEMA' bukan skema awal (tidak memuat CREATE TABLE domains)."
  info "Import skema dari: $SCHEMA"
  if [[ "$SCHEMA" == *.gz ]]; then
    zcat "$SCHEMA" | mysql "$DB_NAME"
  else
    mysql "$DB_NAME" < "$SCHEMA"
  fi
fi
[ -n "$(mysql -N -B "$DB_NAME" -e "SHOW TABLES LIKE 'domains';" 2>/dev/null)" ] \
  || die "Import skema gagal — tabel 'domains' tidak ada."
ok "Skema PowerDNS terverifikasi."

#------------------------------------------------------ konfigurasi powerdns --
install -d -m 0755 /etc/powerdns/pdns.d

if [ -f /etc/powerdns/pdns.d/bind.conf ]; then
  mv /etc/powerdns/pdns.d/bind.conf "/etc/powerdns/pdns.d/bind.conf.disabled.$STAMP"
  info "Backend bind dinonaktifkan."
fi
if grep -q '^# Konfigurasi NS Primary' /etc/powerdns/pdns.conf 2>/dev/null; then
  cp -a /etc/powerdns/pdns.conf "/etc/powerdns/pdns.conf.bak.$STAMP"
  sed -i '/^# Konfigurasi NS Primary$/,/^also-notify=.*$/d' /etc/powerdns/pdns.conf
  warn "Blok konfigurasi instalasi lama dihapus dari pdns.conf."
fi

cat > /etc/powerdns/pdns.d/pdns.local.gmysql.conf <<GMYSQLEOF
# Backend MySQL — install_ns1.sh $STAMP
launch=gmysql
gmysql-host=127.0.0.1
gmysql-port=3306
gmysql-dbname=${DB_NAME}
gmysql-user=${DB_USER}
gmysql-password=${DB_PASS}
gmysql-dnssec=yes
GMYSQLEOF

cat > /etc/powerdns/pdns.d/pdns.local.primary.conf <<PRIMARYEOF
# Peran: PRIMARY (master) — install_ns1.sh $STAMP
primary=yes
secondary=no
allow-axfr-ips=${NS2_IP},127.0.0.1
also-notify=${NS2_IP}
only-notify=${NS2_IP}
# SOA default untuk zona baru yang dibuat lewat Poweradmin
default-soa-content=${NS1_HOST} ${SOA_RNAME} 0 10800 3600 604800 3600
default-ttl=3600
webserver=no
api=no
version-string=anonymous
PRIMARYEOF

for f in /etc/powerdns/pdns.d/pdns.local.gmysql.conf /etc/powerdns/pdns.d/pdns.local.primary.conf; do
  chmod 640 "$f"
  if getent group pdns >/dev/null; then chown root:pdns "$f"; fi
done
ok "Konfigurasi PowerDNS ditulis (mode 640)."

info "Memastikan port 53 bebas..."
free_port53 || die "Port 53 masih dipakai proses di atas. Matikan proses tersebut lalu jalankan ulang script."
ok "Port 53 bebas."

info "Menjalankan ulang PowerDNS..."
systemctl enable pdns >/dev/null 2>&1 || true
if ! systemctl restart pdns; then
  journalctl -u pdns -n 40 --no-pager || true
  die "PowerDNS gagal start."
fi
sleep 2
systemctl is-active --quiet pdns || { journalctl -u pdns -n 40 --no-pager; die "PowerDNS tidak aktif."; }
ok "PowerDNS aktif."

#-------------------------------------------------------------- zona pertama --
if [ -n "$(mysql -N -B "$DB_NAME" -e "SELECT name FROM domains WHERE name='${DOMAIN}' LIMIT 1;" 2>/dev/null)" ]; then
  info "Zona ${DOMAIN} sudah ada — pembuatan zona dilewati."
else
  info "Membuat zona ${DOMAIN} beserta record NS dan glue..."
  {
    printf "INSERT INTO domains (name, type) VALUES ('%s','MASTER');\n" "$DOMAIN"
    printf "SET @did := LAST_INSERT_ID();\n"
    printf "INSERT INTO records (domain_id,name,type,content,ttl,prio,disabled,auth) VALUES\n"
    printf "  (@did,'%s','SOA','%s %s %s 10800 3600 604800 3600',3600,0,0,1),\n" \
           "$DOMAIN" "$NS1_HOST" "$SOA_RNAME" "$SERIAL"
    printf "  (@did,'%s','NS','%s',3600,0,0,1),\n"  "$DOMAIN" "$NS1_HOST"
    printf "  (@did,'%s','NS','%s',3600,0,0,1);\n" "$DOMAIN" "$NS2_HOST"
    # Glue A record hanya jika hostname berada di dalam domain ini.
    if [[ "$NS1_HOST" == *".$DOMAIN" || "$NS1_HOST" == "$DOMAIN" ]]; then
      printf "INSERT INTO records (domain_id,name,type,content,ttl,prio,disabled,auth) VALUES (@did,'%s','A','%s',3600,0,0,1);\n" "$NS1_HOST" "$NS1_IP"
    fi
    if [[ "$NS2_HOST" == *".$DOMAIN" || "$NS2_HOST" == "$DOMAIN" ]]; then
      printf "INSERT INTO records (domain_id,name,type,content,ttl,prio,disabled,auth) VALUES (@did,'%s','A','%s',3600,0,0,1);\n" "$NS2_HOST" "$NS2_IP"
    fi
    if [[ "$PANEL_HOST" == *".$DOMAIN" ]]; then
      printf "INSERT INTO records (domain_id,name,type,content,ttl,prio,disabled,auth) VALUES (@did,'%s','A','%s',3600,0,0,1);\n" "$PANEL_HOST" "$NS1_IP"
    fi
  } | mysql "$DB_NAME"

  pdns_control rediscover >/dev/null 2>&1 || true
  SOA_OUT="$(dig @127.0.0.1 "$DOMAIN" SOA +short 2>/dev/null || true)"
  if [ -n "$SOA_OUT" ] && [ "${SOA_OUT#*"$NS1_HOST"}" != "$SOA_OUT" ]; then
    ok "Zona ${DOMAIN} aktif dan menjawab dari 127.0.0.1"
  else
    warn "Zona dibuat tetapi belum menjawab — cek: dig @127.0.0.1 $DOMAIN SOA"
  fi
fi

#---------------------------------------------------------------- poweradmin --
getent hosts github.com >/dev/null 2>&1 \
  || die "Tidak bisa me-resolve github.com. Cek /etc/resolv.conf dan koneksi keluar server."
info "Mengunduh Poweradmin (rilis stabil terbaru)..."
PA_TAG="$(git ls-remote --tags --refs "$PA_REPO" 'v*' 2>/dev/null \
          | awk -F/ '{print $NF}' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
          | sort -V | tail -n1 || true)"

if [ -e "$PA_DIR" ]; then
  mv "$PA_DIR" "${PA_DIR}.bak.$STAMP"
  warn "Direktori lama dipindah ke ${PA_DIR}.bak.$STAMP"
fi
if [ -n "$PA_TAG" ]; then
  info "Versi Poweradmin: $PA_TAG"
  git clone --quiet --depth 1 --branch "$PA_TAG" "$PA_REPO" "$PA_DIR"
else
  warn "Tag rilis tidak terdeteksi — memakai branch default."
  git clone --quiet --depth 1 "$PA_REPO" "$PA_DIR"
fi
[ -f "$PA_DIR/index.php" ] || die "Clone Poweradmin gagal."
[ -d "$PA_DIR/vendor" ]   || die "Direktori vendor/ tidak ada — rilis ini butuh 'composer install'."

chown -R root:www-data "$PA_DIR"
find "$PA_DIR" -type d -exec chmod 750 {} +
find "$PA_DIR" -type f -exec chmod 640 {} +
chown -R www-data:www-data "$PA_DIR/config"
chmod 770 "$PA_DIR/config"
ok "Poweradmin terpasang di $PA_DIR"

#-------------------------------------------------------------------- apache --
a2enmod rewrite headers >/dev/null

cat > /etc/apache2/sites-available/poweradmin.conf <<VHOSTEOF
<VirtualHost *:80>
    ServerName ${PANEL_HOST}
    ServerAdmin ${ADMIN_EMAIL}
    DocumentRoot ${PA_DIR}

    <Directory ${PA_DIR}>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    <DirectoryMatch "^${PA_DIR}/(config|lib|sql|tests|locale)/">
        Require all denied
    </DirectoryMatch>

    ServerSignature Off
    ErrorLog  \${APACHE_LOG_DIR}/poweradmin_error.log
    CustomLog \${APACHE_LOG_DIR}/poweradmin_access.log combined
</VirtualHost>
VHOSTEOF

a2dissite 000-default >/dev/null 2>&1 || true
a2ensite poweradmin >/dev/null
apache2ctl configtest || die "Konfigurasi Apache tidak valid."
systemctl enable apache2 >/dev/null 2>&1 || true
systemctl restart apache2
ok "Apache aktif (ServerName ${PANEL_HOST})."

PHP_MODS="$(php -m 2>/dev/null || true)"
for m in intl gettext mbstring pdo_mysql openssl curl; do
  grep -qix "$m" <<<"$PHP_MODS" || warn "Ekstensi PHP '$m' tidak terdeteksi."
done

#------------------------------------------------------------------ firewall --
# SSH dibuka SEBELUM ufw aktif agar sesi tidak terputus.
SSH_PORT="$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/{print $2; exit}' \
             /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null || true)"
SSH_PORT="${SSH_PORT:-22}"
info "Membuka firewall (SSH port $SSH_PORT)..."
ufw allow "${SSH_PORT}/tcp" >/dev/null
ufw allow OpenSSH >/dev/null 2>&1 || true
for p in 80/tcp 443/tcp 53/tcp 53/udp; do ufw allow "$p" >/dev/null; done
ufw --force enable >/dev/null
ok "UFW aktif."

#------------------------------------------------------------------------ TLS --
PANEL_URL="http://${PANEL_HOST}/"
info "Menyiapkan sertifikat TLS untuk ${PANEL_HOST}..."
RESOLVED="$(getent ahostsv4 "$PANEL_HOST" 2>/dev/null | awk '{print $1; exit}' || true)"
if [ "$RESOLVED" != "$NS1_IP" ]; then
  warn "DNS ${PANEL_HOST} mengarah ke '${RESOLVED:-tidak ada}', bukan ${NS1_IP}."
  warn "TLS dilewati. Setelah A record benar, jalankan:"
  warn "  certbot --apache -n --agree-tos -m ${ADMIN_EMAIL} -d ${PANEL_HOST} --redirect"
else
  apt-get "${APT_OPTS[@]}" install certbot python3-certbot-apache
  if certbot --apache -n --agree-tos -m "$ADMIN_EMAIL" -d "$PANEL_HOST" --redirect; then
    PANEL_URL="https://${PANEL_HOST}/"
    ok "Sertifikat terpasang, HTTP dialihkan ke HTTPS."
  else
    warn "Certbot gagal. Panel tetap bisa diakses via HTTP."
  fi
fi

#--------------------------------------------------------- berkas keluaran ----
umask 077
cat > "$CRED_FILE" <<CREDEOF
PowerDNS NS1 — kredensial instalasi ($STAMP)
--------------------------------------------
Database host   : 127.0.0.1
Database port   : 3306
Database name   : ${DB_NAME}
Database user   : ${DB_USER}
Database pass   : ${DB_PASS}

Domain utama    : ${DOMAIN}
Primary  (NS1)  : ${NS1_HOST} (${NS1_IP})
Secondary (NS2) : ${NS2_HOST} (${NS2_IP})
Hostmaster      : ${ADMIN_EMAIL}
Panel           : ${PANEL_URL}install/
Direktori web   : ${PA_DIR}
CREDEOF
chmod 600 "$CRED_FILE"

cat > "$NS2_ENV_FILE" <<ENVEOF
# Salin file ini ke server NS2, lalu jalankan:
#   ./install_ns2.sh --env ns2-setup.env
MASTER_IP=${NS1_IP}
MASTER_NS=${NS1_HOST}
ENVEOF
chmod 600 "$NS2_ENV_FILE"

#-------------------------------------------------------------------- ringkas --
echo
echo "=============================================================="
echo "  INSTALASI NS1 SELESAI"
echo "=============================================================="
printf '  Database : %s\n  User     : %s\n  Password : %s\n' "$DB_NAME" "$DB_USER" "$DB_PASS"
echo "  (tersimpan di $CRED_FILE, mode 600)"
echo
echo "  Zona ${DOMAIN} sudah dibuat dengan record:"
echo "    SOA  ${NS1_HOST} ${SOA_RNAME}"
echo "    NS   ${NS1_HOST} , ${NS2_HOST}"
echo "    A    ${NS1_HOST} -> ${NS1_IP} , ${NS2_HOST} -> ${NS2_IP}"
echo
echo "  LANGKAH BERIKUTNYA"
echo "  1. Buka ${PANEL_URL}install/ dan isi kredensial DB di atas,"
echo "     lalu tentukan password admin Poweradmin."
echo "  2. Setelah wizard selesai, WAJIB:"
echo "       rm -rf ${PA_DIR}/install"
echo "       chmod 640 ${PA_DIR}/config/settings.php"
echo "  3. Salin berkas jawaban ke NS2 lalu jalankan installer di sana:"
echo "       scp ${NS2_ENV_FILE} root@${NS2_IP}:/root/"
echo "       ssh root@${NS2_IP} './install_ns2.sh --env /root/ns2-setup.env'"
echo "  4. Daftarkan glue record ${NS1_HOST}/${NS2_HOST} di registrar domain."
echo
echo "  Log lengkap: $LOG_FILE"
echo "=============================================================="
