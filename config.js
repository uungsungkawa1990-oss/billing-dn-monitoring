// =========================================================
// SIMPUL — Konfigurasi koneksi Supabase
// =========================================================
// Isi dua nilai di bawah dari Supabase Dashboard:
// Project Settings > API > Project URL & anon public key
//
// AMAN untuk di-commit ke GitHub: anon key memang didesain
// untuk dipakai di browser. Keamanan data tetap dijaga oleh
// Row Level Security (RLS) di schema.sql — BUKAN oleh
// kerahasiaan anon key ini.
//
// JANGAN PERNAH taruh "service_role key" di file ini atau di
// mana pun pada kode frontend.
// =========================================================
window.SIMPUL_CONFIG = {
  supabaseUrl: "https://xxxxxxxxxxxxx.supabase.co",
  supabaseAnonKey: "eyJhbGciOi....(anon-public-key-anda)"
};
