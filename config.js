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
  supabaseUrl: "https://hrxprochykrbzbvuauyy.supabase.co",
  supabaseAnonKey: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImhyeHByb2NoeWtyYnpidnVhdXl5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQyMzIyNDEsImV4cCI6MjA5OTgwODI0MX0.I4I_G_YG1ZrmIZ-lNnEgVPQTKkfpxiE17cvhryR97UU"
};
