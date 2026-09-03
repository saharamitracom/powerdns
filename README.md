# PowerDNS (Primary–Secondary) + Poweradmin — Debian 13

Script otomasi untuk membangun DNS authoritative dengan topologi Primary–Secondary
menggunakan PowerDNS, ditambah web panel Poweradmin di server primary.

| File | Peran | Dijalankan di |
|---|---|---|
| `install_ns1.sh` | PowerDNS Primary + MariaDB + Apache + Poweradmin + TLS | Server NS1 |
| `install_ns2.sh` | PowerDNS Secondary (autosecondary) + MariaDB | Server NS2 |

Kedua script mengumpulkan seluruh input di awal, menampilkan ringkasan, lalu
berjalan sampai selesai tanpa interupsi.

---

## Persyaratan

- 2 server / VPS dengan Debian 13 (trixie) atau Debian 12 (bookworm), sebaiknya fresh install.
- Akses `root` di kedua server.
- IP publik statis di masing-masing server.
- Di firewall provider: port **53 TCP+UDP** dan **80 + 443 TCP** terbuka.
- Untuk TLS otomatis: A record hostname panel (mis. `dns.domainanda.com`) sudah
  mengarah ke IP NS1 **sebelum** script dijalankan. Kalau belum, script melewati
  langkah TLS dan mencetak perintah certbot yang bisa dijalankan menyusul.

Port SSH dideteksi otomatis dari `sshd_config` dan diizinkan **sebelum** UFW
diaktifkan, jadi sesi SSH tidak akan terputus.

---

## 1. Server Primary (NS1)

```bash
scp install_ns1.sh root@IP_NS1:/root/
ssh root@IP_NS1
chmod +x install_ns1.sh
./install_ns1.sh
```

### Input yang ditanyakan

| # | Pertanyaan | Default |
|---|---|---|
| 1 | Domain utama | — |
| 2 | Hostname NS1 | `ns1.<domain>` |
| 3 | IP publik NS1 | dideteksi otomatis dari interface |
| 4 | Hostname NS2 | `ns2.<domain>` |
| 5 | IP publik NS2 | — |
| 6 | Email hostmaster | `hostmaster@<domain>` |
| 7 | Hostname panel Poweradmin | `dns.<domain>` |
| 8 | Konfirmasi ringkasan | `N` |

Tidak ditanyakan karena di-generate atau dideteksi sendiri: nama & user database,
password database (28 karakter acak), port SSH, lokasi `schema.mysql.sql`,
versi rilis Poweradmin.

Override lewat environment bila perlu: `DB_NAME`, `DB_USER`.

### Yang dilakukan script

- Memasang MariaDB, Apache, PHP (termasuk `php-intl`), PowerDNS, Poweradmin.
- Menonaktifkan `systemd-resolved` **sebelum** PowerDNS dipasang agar port 53 bebas.
- Import skema PowerDNS (lokasi file dicari lewat `dpkg -L`) lalu memverifikasi tabel `domains`.
- Menulis konfigurasi ke `/etc/powerdns/pdns.d/` sebagai file terpisah, mode 640 `root:pdns`.
- Menyetel `default-soa-content` dari hostname NS1 + email hostmaster, sehingga zona
  baru yang dibuat lewat Poweradmin langsung punya SOA yang benar.
- Membuat zona domain utama beserta record:

  ```
  SOA  <domain>       ns1.<domain> hostmaster.<domain> <serial> 10800 3600 604800 3600
  NS   <domain>       ns1.<domain>
  NS   <domain>       ns2.<domain>
  A    ns1.<domain>   <IP NS1>
  A    ns2.<domain>   <IP NS2>
  A    dns.<domain>   <IP NS1>
  ```

- Memasang Poweradmin dari tag rilis terbaru sebagai **DocumentRoot** vhost sendiri
  (bukan subfolder) — Poweradmin v4 memakai routing Symfony + `.htaccess`, jadi butuh
  `AllowOverride All` dan `mod_rewrite`.
- Menjalankan certbot untuk hostname panel dan mengaktifkan redirect ke HTTPS.
- Mengaktifkan UFW: SSH, 80, 443, 53/tcp, 53/udp.

### Keluaran

| Berkas | Isi |
|---|---|
| `/root/powerdns-ns1-credentials.txt` | Kredensial database dan ringkasan konfigurasi (mode 600) |
| `/root/ns2-setup.env` | `MASTER_IP` dan `MASTER_NS` siap pakai untuk NS2 |
| `/var/log/install_ns1.log` | Log lengkap instalasi |

### Menyelesaikan Poweradmin

1. Buka `https://dns.<domain>/install/`
2. Isi kredensial database dari `/root/powerdns-ns1-credentials.txt`
3. Tentukan password admin Poweradmin
4. Setelah selesai, **wajib**:

   ```bash
   rm -rf /var/www/poweradmin/install
   chmod 640 /var/www/poweradmin/config/settings.php
   ```

---

## 2. Server Secondary (NS2)

Cara termudah — pakai berkas jawaban yang dihasilkan NS1, sehingga hostname primary
mustahil salah ketik:

```bash
scp /root/ns2-setup.env root@IP_NS2:/root/
scp install_ns2.sh      root@IP_NS2:/root/
ssh root@IP_NS2
chmod +x install_ns2.sh
./install_ns2.sh --env /root/ns2-setup.env      # jalan tanpa tanya apa-apa
```

Atau interaktif:

```bash
./install_ns2.sh
#   IP publik NS1  : 203.0.113.10
#   Hostname NS1   : ns1.domainanda.com
```

> **`MASTER_NS` harus sama persis dengan record NS di zona pada NS1.** Autosecondary
> mencocokkan nama server pada paket NOTIFY dengan tabel `supermasters`; kalau tidak
> cocok, zona tidak akan pernah dibuat otomatis. Inilah penyebab "AXFR tidak jalan"
> yang paling sering.

Argumen: `--env FILE` (baca `MASTER_IP`/`MASTER_NS`), `-y` (lewati konfirmasi).

---

## 3. Verifikasi Zone Transfer

1. Di Poweradmin (NS1), tambahkan **Master Zone** baru, mis. `domain-testing.com`,
   lengkap dengan record NS `ns1.<domain>` dan `ns2.<domain>`.
2. Di NS2, pantau log:

   ```bash
   journalctl -u pdns -f
   ```

   Yang diharapkan: `received NOTIFY`, lalu `AXFR started` dan `AXFR done`.
3. Bandingkan serial di kedua server:

   ```bash
   dig @IP_NS1 domain-testing.com SOA +short
   dig @IP_NS2 domain-testing.com SOA +short
   ```

Jika NOTIFY tidak masuk:

```bash
# di NS1
grep -r allow-axfr-ips /etc/powerdns/          # harus memuat IP NS2
pdns_control notify domain-testing.com         # picu NOTIFY manual
# di NS2
mysql powerdns_slave -e "SELECT * FROM supermasters;"
mysql powerdns_slave -e "SELECT name,type,master FROM domains;"
```

4. Terakhir, daftarkan glue record `ns1.<domain>` dan `ns2.<domain>` di registrar domain.

---

## Ringkasan konfigurasi

| Aspek | NS1 | NS2 |
|---|---|---|
| Backend | `gmysql`, DNSSEC aktif | `gmysql`, DNSSEC aktif |
| Peran | `primary=yes` | `secondary=yes`, `autosecondary=yes` |
| Kontrol transfer | `allow-axfr-ips`, `also-notify`, `only-notify` | `allow-notify-from=<NS1>/32`, `disable-axfr=yes` |
| SOA default | `default-soa-content` dari input wizard | — |
| File konfigurasi | `/etc/powerdns/pdns.d/pdns.local.*.conf` (640, `root:pdns`) | idem |
| `systemd-resolved` | dimatikan sebelum pdns dipasang | idem |
| Firewall | SSH, 80, 443, 53/tcp, 53/udp | SSH, 53/tcp, 53/udp |

Konfigurasi ditulis sebagai file terpisah di `pdns.d/`, bukan di-append ke `pdns.conf`,
sehingga script aman dijalankan ulang tanpa menghasilkan parameter ganda.

---

## Rollback

```bash
systemctl stop pdns apache2
apt-get purge -y pdns-server pdns-backend-mysql
mysql -e "DROP DATABASE powerdns; DROP USER 'powerdns_user'@'localhost';"
rm -rf /var/www/poweradmin /etc/powerdns/pdns.d/pdns.local.*
rm -f /etc/apache2/sites-enabled/poweradmin.conf
systemctl enable --now systemd-resolved
```
