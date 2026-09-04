#!/usr/bin/env bash
#===============================================================================
# install_ns2.sh — PowerDNS Authoritative SECONDARY (NS2 / autosecondary)
#
#   Target OS : Debian 13 (trixie) / Debian 12 (bookworm)
#   Jalankan  : sudo ./install_ns2.sh
#               sudo ./install_ns2.sh --env /root/ns2-setup.env   (dari NS1)
#   Log       : /var/log/install_ns2.log
#
#   MASTER_NS harus SAMA PERSIS dengan record NS di zona pada NS1. Kalau tidak
#   cocok, PowerDNS menolak NOTIFY dan zona tidak pernah dibuat di sini.
#===============================================================================
set -Eeuo pipefail

DB_NAME="${DB_NAME:-powerdns_slave}"
DB_USER="${DB_USER:-pdns_slave_user}"
CRED_FILE="/root/powerdns-ns2-credentials.txt"
LOG_FILE="/var/log/install_ns2.log"
STAMP="$(date +%Y%m%d-%H%M%S)"

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

#----------------------------------------------------------------- argumen ----
ENV_FILE=""
AUTO_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --env)  ENV_FILE="${2:-}"; shift 2 ;;
    --env=*) ENV_FILE="${1#*=}"; shift ;;
    -y|--yes) AUTO_YES=1; shift ;;
    -h|--help)
      echo "Pemakaian: $0 [--env FILE] [-y]"
      exit 0 ;;
    *) die "Argumen tidak dikenal: $1" ;;
  esac
done

if [ -n "$ENV_FILE" ]; then
  [ -r "$ENV_FILE" ] || die "Berkas env tidak terbaca: $ENV_FILE"
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  AUTO_YES=1
fi

clear || true
echo "=============================================================="
echo "  SETUP POWERDNS SECONDARY (NS2)"
echo "=============================================================="
if [ -r /etc/os-release ]; then
  . /etc/os-release
  echo "  OS: ${PRETTY_NAME:-unknown}"
  [ "${ID:-}" = "debian" ] || warn "Script diuji untuk Debian 12/13."
fi
echo

#===============================================================================
# WIZARD
#===============================================================================
NS2_IP_LOCAL="$(detect_ip || true)"

echo "--- Data server Primary (NS1) --------------------------------"
if [ -n "${MASTER_IP:-}" ] && valid_ip "$MASTER_IP"; then
  printf '  %-22s %s (dari %s)\n' "IP NS1" "$MASTER_IP" "${ENV_FILE:-environment}"
else
  ask MASTER_IP "IP publik NS1" "" valid_ip
fi
if [ -n "${MASTER_NS:-}" ] && valid_host "$MASTER_NS"; then
  printf '  %-22s %s (dari %s)\n' "Hostname NS1" "$MASTER_NS" "${ENV_FILE:-environment}"
else
  ask MASTER_NS "Hostname NS1 (mis. ns1.domainanda.com)" "" valid_host
fi
echo

echo "--- Ringkasan ------------------------------------------------"
printf '  %-22s %s (%s)\n' "Primary NS1" "$MASTER_NS" "$MASTER_IP"
printf '  %-22s %s\n' "IP server ini"  "${NS2_IP_LOCAL:-tidak terdeteksi}"
printf '  %-22s %s / %s (password acak)\n' "Database" "$DB_NAME" "$DB_USER"
echo
echo "  Yang akan dilakukan:"
echo "   - pasang MariaDB + PowerDNS sebagai autosecondary"
echo "   - matikan systemd-resolved (bebaskan port 53)"
echo "   - daftarkan ${MASTER_NS} sebagai autoprimary"
echo "   - aktifkan UFW (SSH tetap dibuka)"
echo
if [ "$AUTO_YES" -eq 0 ]; then
  read -r -p "  Lanjutkan instalasi? [y/N]: " CONFIRM
  [[ "${CONFIRM,,}" == "y" ]] || die "Dibatalkan oleh pengguna."
fi
echo

#===============================================================================
# EKSEKUSI
#===============================================================================
touch "$LOG_FILE" && chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1
info "Mulai instalasi $STAMP"

export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

info "Memperbarui indeks paket..."
apt-get update
info "Upgrade sistem..."
apt-get "${APT_OPTS[@]}" upgrade

info "Memasang MariaDB dan dependensi..."
apt-get "${APT_OPTS[@]}" install \
  mariadb-server mariadb-client git curl ca-certificates openssl ufw dnsutils

#--------------------------------------- bebaskan port 53 SEBELUM install pdns --
info "Menonaktifkan systemd-resolved (membebaskan port 53)..."
# CATATAN: jangan pakai `systemctl ... | grep -q` di sini. Di bawah
# `set -o pipefail`, grep -q keluar lebih dulu, systemd-resolved kena SIGPIPE
# (exit 141), dan seluruh pipeline dianggap gagal -> disable tidak pernah jalan.
systemctl disable --now systemd-resolved >/dev/null 2>&1 || true
systemctl stop         systemd-resolved >/dev/null 2>&1 || true
if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
  warn "systemd-resolved masih aktif setelah disable — akan ditangani free_port53()."
fi
if [ -e /etc/resolv.conf ]; then
  cp -aL /etc/resolv.conf "/etc/resolv.conf.bak.$STAMP" 2>/dev/null || true
  rm -f /etc/resolv.conf
fi
cat > /etc/resolv.conf <<'RESOLVEOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
options timeout:2 attempts:2
RESOLVEOF
chmod 644 /etc/resolv.conf
ok "Resolver sistem: 1.1.1.1 / 8.8.8.8"

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
[ -n "$(mysql -N -B "$DB_NAME" -e "SHOW TABLES LIKE 'supermasters';" 2>/dev/null)" ] \
  || die "Import skema gagal — tabel 'supermasters' tidak ada."
ok "Skema PowerDNS terverifikasi."

info "Mendaftarkan autoprimary ${MASTER_NS} (${MASTER_IP})..."
mysql "$DB_NAME" <<SUPEREOF
DELETE FROM supermasters WHERE ip='${MASTER_IP}' AND nameserver='${MASTER_NS}';
INSERT INTO supermasters (ip, nameserver, account) VALUES ('${MASTER_IP}', '${MASTER_NS}', 'admin');
SUPEREOF
ok "Autoprimary terdaftar."

#------------------------------------------------------ konfigurasi powerdns --
install -d -m 0755 /etc/powerdns/pdns.d

if [ -f /etc/powerdns/pdns.d/bind.conf ]; then
  mv /etc/powerdns/pdns.d/bind.conf "/etc/powerdns/pdns.d/bind.conf.disabled.$STAMP"
  info "Backend bind dinonaktifkan."
fi
if grep -qE '^(secondary|autosecondary|slave|superslave)=' /etc/powerdns/pdns.conf 2>/dev/null; then
  cp -a /etc/powerdns/pdns.conf "/etc/powerdns/pdns.conf.bak.$STAMP"
  sed -i -E '/^(secondary|autosecondary|slave|superslave)=/d' /etc/powerdns/pdns.conf
  warn "Parameter instalasi lama dihapus dari pdns.conf."
fi

cat > /etc/powerdns/pdns.d/pdns.local.gmysql.conf <<GMYSQLEOF
# Backend MySQL — install_ns2.sh $STAMP
launch=gmysql
gmysql-host=127.0.0.1
gmysql-port=3306
gmysql-dbname=${DB_NAME}
gmysql-user=${DB_USER}
gmysql-password=${DB_PASS}
gmysql-dnssec=yes
GMYSQLEOF

cat > /etc/powerdns/pdns.d/pdns.local.secondary.conf <<SECONDARYEOF
# Peran: SECONDARY (autosecondary) — install_ns2.sh $STAMP
primary=no
secondary=yes
autosecondary=yes
# Hanya terima NOTIFY dari primary.
allow-notify-from=${MASTER_IP}/32
# Jangan layani AXFR ke pihak lain.
disable-axfr=yes
xfr-cycle-interval=60
webserver=no
api=no
version-string=anonymous
SECONDARYEOF

for f in /etc/powerdns/pdns.d/pdns.local.gmysql.conf /etc/powerdns/pdns.d/pdns.local.secondary.conf; do
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

#------------------------------------------------------------------ firewall --
SSH_PORT="$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/{print $2; exit}' \
             /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null || true)"
SSH_PORT="${SSH_PORT:-22}"
info "Membuka firewall (SSH port $SSH_PORT)..."
ufw allow "${SSH_PORT}/tcp" >/dev/null
ufw allow OpenSSH >/dev/null 2>&1 || true
for p in 53/tcp 53/udp; do ufw allow "$p" >/dev/null; done
ufw --force enable >/dev/null
ok "UFW aktif."

#------------------------------------------------------------- uji konektivitas --
info "Menguji akses ke primary..."
if dig +time=3 +tries=1 @"${MASTER_IP}" version.bind CH TXT >/dev/null 2>&1; then
  ok "Port 53 pada ${MASTER_IP} dapat dijangkau."
else
  warn "Tidak bisa menghubungi ${MASTER_IP}:53 — cek firewall provider di sisi NS1."
fi

#---------------------------------------------------------------- kredensial --
umask 077
cat > "$CRED_FILE" <<CREDEOF
PowerDNS NS2 — kredensial instalasi ($STAMP)
--------------------------------------------
Database host   : 127.0.0.1
Database name   : ${DB_NAME}
Database user   : ${DB_USER}
Database pass   : ${DB_PASS}

Primary (NS1)   : ${MASTER_NS} (${MASTER_IP})
IP server ini   : ${NS2_IP_LOCAL:-unknown}
CREDEOF
chmod 600 "$CRED_FILE"

#-------------------------------------------------------------------- ringkas --
echo
echo "=============================================================="
echo "  INSTALASI NS2 SELESAI"
echo "=============================================================="
printf '  Database : %s\n  User     : %s\n  Password : %s\n' "$DB_NAME" "$DB_USER" "$DB_PASS"
echo "  (tersimpan di $CRED_FILE, mode 600)"
echo
echo "  Siap menerima NOTIFY + AXFR dari ${MASTER_NS} (${MASTER_IP})."
echo
echo "  VERIFIKASI"
echo "    journalctl -u pdns -f        # tunggu 'received NOTIFY' lalu 'AXFR done'"
echo "    mysql ${DB_NAME} -e 'SELECT name,type FROM domains;'"
echo "    dig @127.0.0.1 <domain> SOA +short"
echo
echo "  Kalau zona tidak muncul, di NS1 jalankan:"
echo "    pdns_control notify <domain>"
echo
echo "  Log lengkap: $LOG_FILE"
echo "=============================================================="
