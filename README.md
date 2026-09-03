Markdown
# Panduan Instalasi PowerDNS (Master-Slave) & Poweradmin - Debian 13

Dokumentasi ini panduan penggunaan script otomasi untuk membangun infrastruktur DNS Server menggunakan PowerDNS dengan topologi Primary-Secondary (Master-Slave) beserta web panel Poweradmin di lingkungan operasi Debian 13.

## Persyaratan Sistem

* 2 buah server/Virtual Private Server (VPS) dengan OS Debian 13 (direkomendasikan instalasi baru/fresh install).
* Akses `root` pada kedua server.
* IP Publik statis pada masing-masing server.
* Port 53 (TCP/UDP) dan Port 80 (TCP) terbuka di sisi provider VPS.

---

## 1. Persiapan Primary Server (NS1)

Server pertama bertindak sebagai Master DNS. Semua manajemen domain (zona) dilakukan di server ini melalui antarmuka web Poweradmin.

### Langkah Instalasi:
1. Login ke server Primary menggunakan SSH sebagai `root`.
2. Buat file eksekusi baru:
   ```bash
   nano install_ns1.sh
Tempelkan seluruh kode script NS1.

Penting: Ubah variabel NS2_IP di bagian atas script dengan IP Publik server Secondary.

Simpan file dan berikan hak akses eksekusi:

Bash
chmod +x install_ns1.sh
Jalankan instalasi:

Bash
./install_ns1.sh
Catat informasi nama database, user, dan password yang muncul pada akhir proses eksekusi.

Penyelesaian via Web (Poweradmin):
Buka web browser dan akses URL: http://<IP_Server_NS1>/poweradmin/install/

Masukkan informasi kredensial database yang dicatat sebelumnya.

Tentukan password untuk login administrator Poweradmin (admin).

Setelah instalasi web selesai, wajib hapus direktori instalasi untuk keamanan:

Bash
rm -rf /var/www/html/poweradmin/install/
2. Persiapan Secondary Server (NS2)
Server kedua bertindak sebagai Slave DNS. Server ini pasif dan hanya menunggu pembaruan (AXFR zone transfer) dari Master DNS secara otomatis. Tidak ada antarmuka web di server ini.

Langkah Instalasi:
Login ke server Secondary menggunakan SSH sebagai root.

Buat file eksekusi baru:

Bash
nano install_ns2.sh
Tempelkan seluruh kode script NS2.

Penting: Ubah variabel di bagian atas script:

MASTER_IP: Isi dengan IP Publik server Primary (NS1).

MASTER_NS: Isi dengan hostname untuk NS1 (misal: ns1.domainanda.com).

Simpan file dan berikan hak akses eksekusi:

Bash
chmod +x install_ns2.sh
Jalankan instalasi:

Bash
./install_ns2.sh
3. Pengujian Sinkronisasi Zone Transfer
Verifikasi apakah arsitektur Master-Slave sudah berjalan dengan normal dan NS2 menerima data dari NS1.

Buka web panel Poweradmin di NS1.

Tambahkan Master Zone baru (misal: domain-testing.com).

Tambahkan beberapa record (A, CNAME, atau TXT) di dalam zona tersebut.

Login ke terminal server NS2.

Periksa log layanan PowerDNS secara real-time:

Bash
journalctl -u pdns -f
Jika konfigurasi sukses, log NS2 akan menampilkan status bahwa server menerima notifikasi (received NOTIFY) dan berhasil menyelesaikan proses transfer zona (AXFR started, AXFR done).
