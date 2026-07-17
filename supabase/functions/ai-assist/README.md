# ai-assist — Edge Function untuk modul AI Automation

Menjalankan diagnosis tiket & prediksi churn dengan model AI, tanpa API key
pernah menyentuh browser.

## Kenapa lewat Edge Function, bukan langsung dari `index.html`?

`index.html` adalah kode client — apa pun yang tertulis di sana (termasuk API
key) bisa dibaca siapa pun lewat "View Source". Ini pola yang sama dengan
larangan menyimpan API key/token di tabel `integrations`. Edge Function
berjalan di server Supabase; secret `ANTHROPIC_API_KEY` hanya bisa dibaca
oleh function itu sendiri.

## Deploy

Butuh [Supabase CLI](https://supabase.com/docs/guides/cli) sudah login dan
project sudah di-link (`supabase link --project-ref <ref>`).

```bash
# dari root project, tempat folder supabase/ berada
supabase functions deploy ai-assist

# set API key sebagai secret — WAJIB, function akan menolak request tanpa ini
supabase secrets set ANTHROPIC_API_KEY=sk-ant-xxxxxxxx

# opsional — default sudah claude-sonnet-5 kalau tidak diset
supabase secrets set ANTHROPIC_MODEL=claude-sonnet-5
```

Tidak perlu `SUPABASE_URL` / `SUPABASE_ANON_KEY` manual — keduanya otomatis
tersedia sebagai env var bawaan di setiap Edge Function.

## Cara kerja singkat

1. Client (`index.html`) mengumpulkan context dari data yang sudah di-fetch
   lewat Supabase (tunduk RLS) — misalnya isi tiket + histori koneksi
   pelanggan, atau daftar pelanggan + tagihan + tiket per server.
2. Client memanggil `sb.functions.invoke('ai-assist', { body: { action, payload } })`
   dengan JWT user (otomatis disertakan oleh supabase-js).
3. Function memverifikasi JWT (`auth.getUser`), lalu mengirim prompt ke
   Anthropic API pakai `ANTHROPIC_API_KEY` dari secret.
4. Function mem-parse balasan model (diminta strict JSON) dan
   mengembalikannya ke client.
5. Client menyimpan hasilnya ke tabel `ai_insights` (lihat `schema.sql` §17)
   — insert ini tunduk RLS per-site yang sama seperti tabel operasional lain,
   jadi audit trail "siapa minta analisis apa" tetap terjaga tanpa function
   perlu akses database sama sekali.

## Action yang didukung

- `ticket_diagnosis` — payload: context satu tiket + histori koneksi
  pelanggan terkait. Balasan: `{ summary, risk_score, detail: { probable_cause, suggested_steps[] } }`.
- `churn_prediction` — payload: daftar pelanggan (tagihan + tiket) di server
  terpilih. Balasan: `{ summary, detail: { top_risk: [{customer_id, name, risk_score, reason}] } }`.

## Uji coba lokal

```bash
supabase functions serve ai-assist --env-file supabase/.env.local
```

Isi `supabase/.env.local` dengan `ANTHROPIC_API_KEY=sk-ant-...` untuk testing
lokal (jangan commit file ini ke repo).
