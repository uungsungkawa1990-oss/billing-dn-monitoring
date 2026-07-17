# Simpul — ISP Billing & Monitoring CRM

Frontend statis (HTML/JS, tanpa build step) yang tersambung langsung ke Supabase.
Dibuat untuk di-hosting di Cloudflare Pages, terhubung ke repo GitHub ini.

## File yang perlu di-upload ke GitHub

```
simpul/
├── index.html      ← aplikasi (wajib)
├── config.js        ← koneksi Supabase (wajib, aman untuk publik — lihat catatan di bawah)
├── schema.sql        ← skema database, TIDAK dijalankan otomatis, hanya referensi/dokumentasi
├── README.md          ← dokumen ini
└── .gitignore
```

Hanya `index.html` dan `config.js` yang benar-benar dibutuhkan agar situs bisa jalan di Cloudflare Pages.
`schema.sql` tidak perlu ikut di-deploy, tapi sebaiknya tetap disimpan di repo sebagai dokumentasi/riwayat skema database.

**Jangan pernah upload:** `service_role key` Supabase, file `.env`, atau kunci enkripsi kredensial (`app.settings.credential_key`) — ketiganya cukup disimpan di Supabase Dashboard, tidak pernah masuk kode.

## Langkah Setup

### 1. Buat project Supabase
1. Buat project baru di [supabase.com](https://supabase.com)
2. Buka **SQL Editor**, jalankan seluruh isi `schema.sql`
3. Di baris paling bawah `schema.sql`, ganti `'ganti-dengan-kunci-rahasia-anda'` dengan kunci acak sungguhan sebelum dijalankan — ini kunci enkripsi sandi PPPoE & kode voucher

### 2. Buat user admin pertama
1. Di Supabase Dashboard → **Authentication** → **Add user** → buat 1 akun (email + password)
2. Di **SQL Editor**, jalankan (ganti `<uuid-user>` dengan ID user yang baru dibuat, dan `<uuid-site>` dengan salah satu `id` dari tabel `sites`):
   ```sql
   insert into profiles (id, full_name, role, site_ids)
   values ('<uuid-user>', 'Nama Admin', 'admin',
     (select array_agg(id) from sites)); -- admin akses semua server
   ```

### 3. Isi `config.js`
Ambil dari Supabase Dashboard → **Project Settings** → **API**:
- `Project URL` → `supabaseUrl`
- `anon public` key → `supabaseAnonKey`

### 4. Deploy ke Cloudflare Pages
1. Push folder ini ke repo GitHub
2. Di Cloudflare Dashboard → **Workers & Pages** → **Create** → **Pages** → **Connect to Git**
3. Pilih repo ini. Build settings: **kosongkan build command**, set **Build output directory** ke `/` (root)
4. Deploy — situs langsung bisa diakses dari domain `*.pages.dev` (bisa custom domain nanti)

### 5. Login
Buka situs, masuk pakai akun admin yang dibuat di langkah 2.

## Yang Masih Perlu Dikerjakan (di luar scope frontend ini)

- **Agent lokal** (Node.js/Python) yang polling tabel `mikrotik_commands` dan mengeksekusi ke MikroTik lewat RouterOS API — lihat diskusi arsitektur sebelumnya (Cloudflare Tunnel + agent).
- **Peta**: koordinat pelanggan (`lat`, `lng`) saat ini dipakai sebagai posisi persentase pada peta abstrak. Untuk peta asli, ganti dengan Leaflet/Mapbox dan simpan koordinat GPS sungguhan.
- **Grafik dashboard**: saat ini masih ilustratif dari rasio status pelanggan. Untuk data histori sungguhan, buat query agregat per jam dari tabel `connection_logs`.
- **Data invoice/revenue**: tabel `invoices` sudah ada di skema, tapi belum ditarik ke dashboard — tinggal tambah query `sum(amount) where status='paid' and period=...`.

## Struktur Keamanan Kredensial

Sandi PPPoE dan kode voucher **tidak pernah** dikirim mentah dari tabel ke browser. Semua akses lewat fungsi database (`reveal_pppoe_password`, `set_pppoe_password`, `reveal_voucher_code`, `create_vouchers`) yang:
- Memverifikasi user punya akses ke server (site) terkait
- Mendekripsi/mengenkripsi di sisi database, memakai kunci yang tidak pernah ada di kode frontend
- Mencatat setiap akses ke tabel `credential_audit_log`
