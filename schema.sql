-- =====================================================================
-- NEXUSNOC / SIMPUL — SCHEMA.SQL (KONSOLIDASI PENUH — SATU-SATUNYA SUMBER KEBENARAN)
-- =====================================================================
-- Menggantikan seluruh file schema per-modul yang sebelumnya terpisah
-- (finance_schema.sql, work_order_schema.sql, device_manager_schema_notes.sql).
-- MULAI SEKARANG: setiap perubahan skema WAJIB ditambahkan di sini, bukan
-- file baru — sesuai Aturan Konstitusi §10.6 ("schema.sql adalah satu-
-- satunya sumber kebenaran skema").
--
-- ⚠️ CATATAN PENTING SOAL ASAL DATA FILE INI:
-- File schema.sql ASLI proyek ini tidak pernah diunggah ke sesi kerja ini.
-- Isi di bawah adalah REKONSTRUKSI yang disusun dari dua sumber:
--   1) docs/MASTER_PROJECT_CONSTITUTION.md §4–§5 (daftar tabel, kolom kunci,
--      fungsi security definer, aturan RLS)
--   2) Audit langsung pemakaian kolom di index.html (setiap sb.from(...),
--      sb.rpc(...), payload insert/update) untuk modul yang ditambahkan
--      belakangan (Inventory, Work Order, Finance, Notification).
--
-- UPDATE: tabel `ai_insights` (§17, modul AI Automation) digabungkan ke sini
-- dari migration terpisah — schema.sql tetap satu-satunya sumber kebenaran,
-- tidak ada lagi file migration AI Automation yang berdiri sendiri.
--
-- ✅ AMAN DIJALANKAN BERULANG KALI (idempoten), termasuk di database yang
-- SUDAH berisi data dari run sebelumnya — tidak akan menumpuk tabel
-- maupun baris data:
--   • Semua CREATE TABLE  → pakai IF NOT EXISTS (tabel yang sudah ada dilewati, TIDAK ditimpa/dikosongkan)
--   • Semua ALTER TABLE ... ADD COLUMN → pakai IF NOT EXISTS
--   • Semua CREATE INDEX → pakai IF NOT EXISTS
--   • Semua CREATE POLICY → didahului DROP POLICY IF EXISTS (definisi diganti, bukan digandakan)
--   • Semua CREATE TRIGGER → didahului DROP TRIGGER IF EXISTS
--   • Semua fungsi pakai CREATE OR REPLACE FUNCTION
--   • TIDAK ADA satu pun statement INSERT data contoh/seed di file ini —
--     jadi menjalankan ulang file ini tidak pernah menambah baris data baru
--     yang tidak diminta. Baris yang sudah ada di tabel Anda tidak disentuh.
-- Skrip ini tetap disarankan di-diff manual terhadap schema Supabase Anda
-- (Database → Schema Visualizer atau `pg_dump --schema-only`) sebelum
-- dijalankan di produksi, khususnya untuk tipe kolom/constraint yang tidak
-- terbukti langsung dari kode frontend.
-- =====================================================================

create extension if not exists pgcrypto;

-- =====================================================================
-- 1. PROFILES — perluasan auth.users
-- =====================================================================
create table if not exists profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text,
  role text not null default 'teknisi' check (role in ('admin','finance','teknisi','sales')),
  site_ids uuid[] not null default '{}',
  created_at timestamptz not null default now()
);

-- =====================================================================
-- 2. SITES — server / lokasi (MikroTik + OLT)
-- =====================================================================
create table if not exists sites (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  agent_status text not null default 'terputus' check (agent_status in ('terhubung','terputus')),
  last_sync timestamptz,
  connection_method text,
  router_summary text,
  created_at timestamptz not null default now()
);

-- =====================================================================
-- 3. NETWORK_NODES — topologi jaringan (Device Manager + Network Topology)
-- =====================================================================
create table if not exists network_nodes (
  id uuid primary key default gen_random_uuid(),
  site_id uuid not null references sites(id) on delete cascade,
  type text not null check (type in ('router','hub','olt','splitter')),
  parent_id uuid references network_nodes(id) on delete set null,
  name text,
  ip_address text,
  created_at timestamptz not null default now()
);
-- Ditambahkan saat implementasi modul Device Manager — aman di-re-run:
alter table network_nodes add column if not exists name text;
alter table network_nodes add column if not exists ip_address text;

-- =====================================================================
-- 4. CUSTOMERS — data pelanggan
-- =====================================================================
create table if not exists customers (
  id uuid primary key default gen_random_uuid(),
  site_id uuid not null references sites(id) on delete cascade,
  customer_code text not null unique,
  name text not null,
  address text,
  lat numeric,
  lng numeric,
  access_type text not null default 'LAN_HUB' check (access_type in ('OLT_GPON','LAN_HUB')),
  node_id uuid references network_nodes(id) on delete set null,
  package text,
  pppoe_username text,
  pppoe_password_encrypted bytea,
  status text not null default 'Aktif' check (status in ('Aktif','Offline','Isolir','PendingMigrasi','Berhenti')),
  created_at timestamptz not null default now()
);

-- =====================================================================
-- 5. TECHNICIANS — teknisi per site
-- =====================================================================
create table if not exists technicians (
  id uuid primary key default gen_random_uuid(),
  site_id uuid not null references sites(id) on delete cascade,
  profile_id uuid references profiles(id) on delete set null,
  name text not null,
  status text not null default 'Tersedia' check (status in ('Tersedia','Bertugas','Offline')),
  active_tickets integer not null default 0,
  created_at timestamptz not null default now()
);

-- =====================================================================
-- 6. VOUCHERS — voucher hotspot prabayar
-- =====================================================================
create table if not exists vouchers (
  id uuid primary key default gen_random_uuid(),
  site_id uuid not null references sites(id) on delete cascade,
  package text not null,
  profile text,
  code_encrypted bytea not null,
  status text not null default 'unused' check (status in ('unused','used')),
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);

-- =====================================================================
-- 7. MIKROTIK_COMMANDS — antrean perintah agent lokal (belum dibuat)
-- =====================================================================
create table if not exists mikrotik_commands (
  id uuid primary key default gen_random_uuid(),
  site_id uuid not null references sites(id) on delete cascade,
  payload jsonb not null default '{}'::jsonb,
  status text not null default 'pending' check (status in ('pending','success','failed')),
  created_at timestamptz not null default now()
);

-- =====================================================================
-- 8. CONNECTION_LOGS — histori status koneksi pelanggan
-- =====================================================================
create table if not exists connection_logs (
  id uuid primary key default gen_random_uuid(),
  site_id uuid not null references sites(id) on delete cascade,
  customer_id uuid not null references customers(id) on delete cascade,
  status text not null,
  signal_dbm numeric,
  logged_at timestamptz not null default now()
);
create index if not exists idx_connection_logs_customer_time on connection_logs(customer_id, logged_at desc);

-- =====================================================================
-- 9. TICKETS — modul Ticketing / CRM
-- =====================================================================
create table if not exists tickets (
  id uuid primary key default gen_random_uuid(),
  site_id uuid not null references sites(id) on delete cascade,
  customer_id uuid references customers(id) on delete set null,
  node_id uuid references network_nodes(id) on delete set null,
  technician_id uuid references technicians(id) on delete set null,
  ticket_type text not null default 'individu' check (ticket_type in ('individu','massal')),
  status text not null default 'open' check (status in ('open','in_progress','resolved','closed')),
  description text,
  created_at timestamptz not null default now()
);
alter table tickets add column if not exists description text;

-- =====================================================================
-- 10. INVOICES — modul Billing
-- =====================================================================
create table if not exists invoices (
  id uuid primary key default gen_random_uuid(),
  site_id uuid not null references sites(id) on delete cascade,
  customer_id uuid not null references customers(id) on delete cascade,
  period text not null,              -- format 'YYYY-MM'
  amount numeric not null,
  status text not null default 'unpaid' check (status in ('unpaid','paid','overdue')),
  paid_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists idx_invoices_customer_period on invoices(customer_id, period);

-- =====================================================================
-- 11. CREDENTIAL_AUDIT_LOG — wajib dicatat setiap akses kredensial
-- =====================================================================
create table if not exists credential_audit_log (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid references auth.users(id),
  action text not null,              -- mis. 'reveal_pppoe_password','reveal_voucher_code','set_pppoe_password','set_customer_isolir'
  target_table text not null,
  target_id uuid not null,
  site_id uuid references sites(id),
  created_at timestamptz not null default now()
);

-- =====================================================================
-- 12. INVENTORY_ITEMS — modul Inventory
-- =====================================================================
create table if not exists inventory_items (
  id uuid primary key default gen_random_uuid(),
  site_id uuid not null references sites(id) on delete cascade,
  name text not null,
  category text not null default 'lainnya' check (category in ('ont','router','kabel','konektor','aksesoris','lainnya')),
  sku text,
  unit text not null default 'pcs',
  quantity numeric not null default 0 check (quantity >= 0),
  min_stock numeric not null default 0 check (min_stock >= 0),
  notes text,
  created_at timestamptz not null default now()
);

-- =====================================================================
-- 13. WORK_ORDERS — modul Work Order
-- =====================================================================
create table if not exists work_orders (
  id uuid primary key default gen_random_uuid(),
  site_id uuid not null references sites(id) on delete cascade,
  customer_id uuid not null references customers(id) on delete cascade,
  wo_type text not null default 'instalasi' check (wo_type in ('instalasi','perbaikan','pemeliharaan','pencabutan')),
  technician_id uuid references technicians(id) on delete set null,
  scheduled_date date,
  status text not null default 'scheduled' check (status in ('scheduled','in_progress','completed','cancelled')),
  description text,
  completed_at timestamptz,
  created_at timestamptz not null default now()
);

-- =====================================================================
-- 14. EXPENSES — modul Finance
-- =====================================================================
create table if not exists expenses (
  id uuid primary key default gen_random_uuid(),
  site_id uuid not null references sites(id) on delete cascade,
  category text not null default 'lainnya' check (category in ('operasional','gaji','perangkat','sewa','lainnya')),
  description text,
  amount numeric not null check (amount > 0),
  expense_date date not null default current_date,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);

-- =====================================================================
-- 15. NOTIFICATIONS — modul Notification (#14 dari 18 modul tetap)
-- =====================================================================
-- Notifikasi bersifat per-site (broadcast ke semua user yang punya akses
-- site tsb), mengikuti pola has_site_access() yang sama seperti tabel
-- lain. Status "sudah dibaca" bersifat PER USER (bukan kolom is_read
-- tunggal di tabel ini) karena satu notifikasi bisa dilihat banyak user
-- berbeda — lihat tabel notification_reads di bawah.
create table if not exists notifications (
  id uuid primary key default gen_random_uuid(),
  site_id uuid not null references sites(id) on delete cascade,
  type text not null default 'info' check (type in ('info','warning','critical','success')),
  title text not null,
  message text,
  source text not null default 'manual' check (source in ('manual','ticket','customer','inventory','mikrotik','workorder','invoice')),
  related_table text,
  related_id uuid,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);
create index if not exists idx_notifications_site_time on notifications(site_id, created_at desc);

-- =====================================================================
-- 16. NOTIFICATION_READS — status "sudah dibaca" per user (modul Notification)
-- =====================================================================
create table if not exists notification_reads (
  notification_id uuid not null references notifications(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  read_at timestamptz not null default now(),
  primary key (notification_id, user_id)
);

-- =====================================================================
-- 17. AI_INSIGHTS — modul AI Automation (diagnosis tiket + prediksi churn)
-- =====================================================================
-- Tabel ini HANYA menyimpan hasil/riwayat analisis AI (audit trail: siapa
-- meminta analisis apa, kapan, dan apa hasilnya) — bukan tempat menyimpan
-- API key model AI. API key (ANTHROPIC_API_KEY) hidup sebagai secret di
-- Supabase Edge Function `ai-assist`, tidak pernah masuk ke database atau
-- ke index.html, sama seperti larangan menyimpan secret di tabel
-- integrations (lihat catatan larangan API key di modul Integration).
-- Baris di sini bersifat immutable (tidak ada UPDATE) — analisis baru =
-- baris baru, riwayat lama tetap utuh.
create table if not exists ai_insights (
  id            uuid primary key default gen_random_uuid(),
  site_id       uuid references sites(id) on delete cascade,
  type          text not null check (type in ('ticket_diagnosis', 'churn_prediction', 'ticket_summary')),
  subject_id    uuid,                 -- id tiket untuk ticket_diagnosis; null untuk churn_prediction (level server)
  subject_label text,                 -- label ringkas untuk riwayat (nama pelanggan / nama server)
  summary       text not null,        -- ringkasan hasil analisis dalam bahasa manusia
  detail        jsonb,                -- payload terstruktur (mis. { top_risk: [...] } untuk churn)
  risk_score    int,                  -- skor 0-100, opsional (severity tiket / risiko churn)
  model         text,                 -- nama model AI yang menghasilkan analisis ini, untuk audit
  requested_by  uuid references profiles(id) on delete set null,
  created_at    timestamptz not null default now()
);
create index if not exists idx_ai_insights_site_time on ai_insights(site_id, created_at desc);
create index if not exists idx_ai_insights_type on ai_insights(type);
create index if not exists idx_ai_insights_subject on ai_insights(subject_id);

-- =====================================================================
-- FUNGSI HELPER MULTI-TENANT
-- =====================================================================
create or replace function is_admin()
returns boolean language sql stable security definer as $$
  select exists (select 1 from profiles where id = auth.uid() and role = 'admin');
$$;

create or replace function user_site_ids()
returns uuid[] language sql stable security definer as $$
  select coalesce((select site_ids from profiles where id = auth.uid()), '{}');
$$;

create or replace function has_site_access(p_site_id uuid)
returns boolean language sql stable security definer as $$
  select is_admin() or p_site_id = any(user_site_ids());
$$;

-- =====================================================================
-- FUNGSI SECURITY DEFINER — SATU-SATUNYA JALUR BACA/TULIS KREDENSIAL
-- (Aturan Konstitusi §5 & §10.1–§10.2 — jangan pernah dilewati)
-- =====================================================================

create or replace function reveal_pppoe_password(p_customer_id uuid)
returns text language plpgsql security definer as $$
declare
  v_site_id uuid;
  v_password text;
begin
  select site_id into v_site_id from customers where id = p_customer_id;
  if v_site_id is null or not has_site_access(v_site_id) then
    raise exception 'Akses ditolak';
  end if;

  select pgp_sym_decrypt(pppoe_password_encrypted, current_setting('app.settings.credential_key'))
    into v_password from customers where id = p_customer_id;

  insert into credential_audit_log(actor_id, action, target_table, target_id, site_id)
    values (auth.uid(), 'reveal_pppoe_password', 'customers', p_customer_id, v_site_id);

  return v_password;
end;
$$;

create or replace function reveal_voucher_code(p_voucher_id uuid)
returns text language plpgsql security definer as $$
declare
  v_site_id uuid;
  v_code text;
begin
  select site_id into v_site_id from vouchers where id = p_voucher_id;
  if v_site_id is null or not has_site_access(v_site_id) then
    raise exception 'Akses ditolak';
  end if;

  select pgp_sym_decrypt(code_encrypted, current_setting('app.settings.credential_key'))
    into v_code from vouchers where id = p_voucher_id;

  insert into credential_audit_log(actor_id, action, target_table, target_id, site_id)
    values (auth.uid(), 'reveal_voucher_code', 'vouchers', p_voucher_id, v_site_id);

  return v_code;
end;
$$;

create or replace function set_pppoe_password(p_customer_id uuid, p_new_password text)
returns void language plpgsql security definer as $$
declare
  v_site_id uuid;
  v_username text;
begin
  select site_id, pppoe_username into v_site_id, v_username from customers where id = p_customer_id;
  if v_site_id is null or not has_site_access(v_site_id) then
    raise exception 'Akses ditolak';
  end if;

  update customers
    set pppoe_password_encrypted = pgp_sym_encrypt(p_new_password, current_setting('app.settings.credential_key'))
    where id = p_customer_id;

  insert into mikrotik_commands(site_id, payload, status)
    values (v_site_id, jsonb_build_object('command','set_pppoe_password','customer_id',p_customer_id,'username',v_username), 'pending');

  insert into credential_audit_log(actor_id, action, target_table, target_id, site_id)
    values (auth.uid(), 'set_pppoe_password', 'customers', p_customer_id, v_site_id);
end;
$$;

create or replace function create_pppoe_account(p_customer_id uuid, p_username text, p_password text)
returns void language plpgsql security definer as $$
declare
  v_site_id uuid;
begin
  select site_id into v_site_id from customers where id = p_customer_id;
  if v_site_id is null or not has_site_access(v_site_id) then
    raise exception 'Akses ditolak';
  end if;

  update customers
    set pppoe_username = p_username,
        pppoe_password_encrypted = pgp_sym_encrypt(p_password, current_setting('app.settings.credential_key'))
    where id = p_customer_id;

  insert into mikrotik_commands(site_id, payload, status)
    values (v_site_id, jsonb_build_object('command','create_pppoe_account','customer_id',p_customer_id,'username',p_username), 'pending');

  insert into credential_audit_log(actor_id, action, target_table, target_id, site_id)
    values (auth.uid(), 'create_pppoe_account', 'customers', p_customer_id, v_site_id);
end;
$$;

create or replace function set_customer_isolir(p_customer_id uuid, p_isolir boolean)
returns void language plpgsql security definer as $$
declare
  v_site_id uuid;
begin
  select site_id into v_site_id from customers where id = p_customer_id;
  if v_site_id is null or not has_site_access(v_site_id) then
    raise exception 'Akses ditolak';
  end if;

  update customers set status = case when p_isolir then 'Isolir' else 'Aktif' end where id = p_customer_id;

  insert into mikrotik_commands(site_id, payload, status)
    values (v_site_id, jsonb_build_object('command', case when p_isolir then 'isolir' else 'restore' end, 'customer_id', p_customer_id), 'pending');

  insert into credential_audit_log(actor_id, action, target_table, target_id, site_id)
    values (auth.uid(), 'set_customer_isolir', 'customers', p_customer_id, v_site_id);
end;
$$;

-- create_vouchers: satu-satunya jalur pembuatan voucher. Kode plaintext
-- sengaja dititipkan ke mikrotik_commands.payload (lihat Aturan Konstitusi
-- §5.6) supaya agent lokal bisa langsung membuat user hotspot.
create or replace function create_vouchers(p_site_id uuid, p_package text, p_profile text, p_count integer)
returns void language plpgsql security definer as $$
declare
  i integer;
  v_code text;
  v_voucher_id uuid;
begin
  if not has_site_access(p_site_id) then
    raise exception 'Akses ditolak';
  end if;
  if p_count < 1 or p_count > 500 then
    raise exception 'Jumlah voucher harus 1-500';
  end if;

  for i in 1..p_count loop
    v_code := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 4) || '-' ||
                     substr(md5(random()::text || clock_timestamp()::text), 1, 4));

    insert into vouchers(site_id, package, profile, code_encrypted, status, created_by)
      values (p_site_id, p_package, p_profile,
              pgp_sym_encrypt(v_code, current_setting('app.settings.credential_key')),
              'unused', auth.uid())
      returning id into v_voucher_id;

    insert into mikrotik_commands(site_id, payload, status)
      values (p_site_id, jsonb_build_object('command','create_voucher','voucher_id',v_voucher_id,'code',v_code,'profile',p_profile), 'pending');
  end loop;
end;
$$;

-- =====================================================================
-- FUNGSI & TRIGGER NOTIFIKASI OTOMATIS (modul Notification, #14)
-- =====================================================================
-- create_notification() adalah satu-satunya jalur INSERT ke tabel
-- notifications dari sisi trigger (security definer, jadi tetap bisa
-- menulis walau pemanggil aslinya tidak punya izin INSERT langsung).
-- Broadcast MANUAL dari UI (mis. admin mengumumkan sesuatu) tetap lewat
-- insert biasa dari frontend, bukan lewat fungsi ini — lihat kebijakan
-- notifications_insert di bagian RLS.
create or replace function create_notification(
  p_site_id uuid, p_type text, p_title text, p_message text,
  p_source text, p_related_table text, p_related_id uuid
) returns uuid language plpgsql security definer as $$
declare v_id uuid;
begin
  insert into notifications(site_id, type, title, message, source, related_table, related_id, created_by)
    values (p_site_id, p_type, p_title, p_message, p_source, p_related_table, p_related_id, auth.uid())
    returning id into v_id;
  return v_id;
end;
$$;

-- Tiket baru dibuka → notifikasi warning
create or replace function notify_new_ticket()
returns trigger language plpgsql security definer as $$
begin
  perform create_notification(
    new.site_id, 'warning', 'Tiket baru dibuka',
    coalesce(new.description, 'Tiket ' || new.ticket_type || ' tanpa deskripsi'),
    'ticket', 'tickets', new.id
  );
  return new;
end;
$$;
drop trigger if exists trg_notify_new_ticket on tickets;
create trigger trg_notify_new_ticket
after insert on tickets
for each row execute function notify_new_ticket();

-- Pelanggan diisolir / dipulihkan → notifikasi critical / success
create or replace function notify_customer_status()
returns trigger language plpgsql security definer as $$
begin
  if new.status is distinct from old.status then
    if new.status = 'Isolir' then
      perform create_notification(new.site_id, 'critical', 'Pelanggan diisolir',
        new.name || ' telah diisolir.', 'customer', 'customers', new.id);
    elsif old.status = 'Isolir' and new.status = 'Aktif' then
      perform create_notification(new.site_id, 'success', 'Pelanggan dipulihkan',
        new.name || ' telah dipulihkan dari status isolir.', 'customer', 'customers', new.id);
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists trg_notify_customer_status on customers;
create trigger trg_notify_customer_status
after update on customers
for each row execute function notify_customer_status();

-- Stok inventory menipis (quantity turun ke bawah/setara min_stock) → notifikasi warning
create or replace function notify_low_stock()
returns trigger language plpgsql security definer as $$
begin
  if new.quantity <= new.min_stock
     and (TG_OP = 'INSERT' or old.quantity is distinct from new.quantity) then
    perform create_notification(new.site_id, 'warning', 'Stok menipis: ' || new.name,
      'Sisa ' || new.quantity || ' ' || new.unit || ' (batas minimum ' || new.min_stock || ').',
      'inventory', 'inventory_items', new.id);
  end if;
  return new;
end;
$$;
drop trigger if exists trg_notify_low_stock on inventory_items;
create trigger trg_notify_low_stock
after insert or update on inventory_items
for each row execute function notify_low_stock();

-- Perintah MikroTik gagal dieksekusi agent → notifikasi critical
create or replace function notify_command_failed()
returns trigger language plpgsql security definer as $$
begin
  if new.status = 'failed' and old.status is distinct from new.status then
    perform create_notification(new.site_id, 'critical', 'Perintah MikroTik gagal',
      coalesce(new.payload->>'command', 'Perintah') || ' gagal dieksekusi oleh agent.',
      'mikrotik', 'mikrotik_commands', new.id);
  end if;
  return new;
end;
$$;
drop trigger if exists trg_notify_command_failed on mikrotik_commands;
create trigger trg_notify_command_failed
after update on mikrotik_commands
for each row execute function notify_command_failed();

-- Work order selesai → notifikasi success
create or replace function notify_wo_completed()
returns trigger language plpgsql security definer as $$
begin
  if new.status = 'completed' and old.status is distinct from new.status then
    perform create_notification(new.site_id, 'success', 'Work Order selesai',
      'Work order ' || new.wo_type || ' telah selesai dikerjakan.',
      'workorder', 'work_orders', new.id);
  end if;
  return new;
end;
$$;
drop trigger if exists trg_notify_wo_completed on work_orders;
create trigger trg_notify_wo_completed
after update on work_orders
for each row execute function notify_wo_completed();

-- Invoice ditandai overdue → notifikasi warning
create or replace function notify_invoice_overdue()
returns trigger language plpgsql security definer as $$
declare v_cust_name text; v_site_id uuid;
begin
  if new.status = 'overdue' and old.status is distinct from new.status then
    select name, site_id into v_cust_name, v_site_id from customers where id = new.customer_id;
    if v_site_id is not null then
      perform create_notification(v_site_id, 'warning', 'Invoice jatuh tempo',
        'Invoice periode ' || new.period || ' milik ' || coalesce(v_cust_name,'pelanggan') || ' belum dibayar.',
        'invoice', 'invoices', new.id);
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists trg_notify_invoice_overdue on invoices;
create trigger trg_notify_invoice_overdue
after update on invoices
for each row execute function notify_invoice_overdue();

-- =====================================================================
-- ROW LEVEL SECURITY — aktif di seluruh tabel (Aturan Konstitusi §5.1)
-- =====================================================================
alter table profiles enable row level security;
alter table sites enable row level security;
alter table network_nodes enable row level security;
alter table customers enable row level security;
alter table technicians enable row level security;
alter table vouchers enable row level security;
alter table mikrotik_commands enable row level security;
alter table connection_logs enable row level security;
alter table tickets enable row level security;
alter table invoices enable row level security;
alter table credential_audit_log enable row level security;
alter table inventory_items enable row level security;
alter table work_orders enable row level security;
alter table expenses enable row level security;
alter table notifications enable row level security;
alter table notification_reads enable row level security;
alter table ai_insights enable row level security;

-- profiles: user lihat baris sendiri; admin lihat semua
drop policy if exists profiles_select on profiles;
create policy profiles_select on profiles for select using (id = auth.uid() or is_admin());
drop policy if exists profiles_update_self on profiles;
create policy profiles_update_self on profiles for update using (id = auth.uid()) with check (id = auth.uid());
-- Ditambahkan untuk modul User & Role: admin mengelola profil user LAIN
-- (ganti role/site_ids, menambahkan baris profil untuk akun yang UUID-nya
-- sudah dibuat manual di Supabase Auth). Tanpa ini, admin cuma bisa edit
-- profilnya sendiri lewat profiles_update_self.
drop policy if exists profiles_admin_insert on profiles;
create policy profiles_admin_insert on profiles for insert with check (is_admin());
drop policy if exists profiles_admin_update on profiles;
create policy profiles_admin_update on profiles for update using (is_admin()) with check (is_admin());

-- sites: dibaca siapa pun yang punya akses site tsb; hanya admin yang tulis
drop policy if exists sites_select on sites;
create policy sites_select on sites for select using (has_site_access(id));
drop policy if exists sites_admin_write on sites;
create policy sites_admin_write on sites for all using (is_admin()) with check (is_admin());

-- Pola RLS seragam per-site untuk seluruh tabel operasional:
-- helper generik dijalankan via DO block supaya tidak menulis ulang 14x.
do $$
declare
  t text;
  tables text[] := array[
    'network_nodes','customers','technicians','vouchers','mikrotik_commands',
    'connection_logs','tickets','invoices','inventory_items','work_orders','expenses',
    'notifications'
  ];
begin
  foreach t in array tables loop
    execute format('drop policy if exists %I_select on %I', t, t);
    execute format('create policy %I_select on %I for select using (has_site_access(site_id))', t, t);

    execute format('drop policy if exists %I_insert on %I', t, t);
    execute format('create policy %I_insert on %I for insert with check (has_site_access(site_id))', t, t);

    execute format('drop policy if exists %I_update on %I', t, t);
    execute format('create policy %I_update on %I for update using (has_site_access(site_id)) with check (has_site_access(site_id))', t, t);

    execute format('drop policy if exists %I_delete on %I', t, t);
    execute format('create policy %I_delete on %I for delete using (has_site_access(site_id))', t, t);
  end loop;
end $$;

-- credential_audit_log: hanya bisa dibaca admin, hanya bisa ditulis lewat fungsi security definer di atas
drop policy if exists audit_log_select on credential_audit_log;
create policy audit_log_select on credential_audit_log for select using (is_admin());
-- Sengaja TIDAK ada policy insert/update/delete untuk role biasa — hanya
-- fungsi security definer (yang berjalan sebagai owner tabel) yang bisa menulis.

-- notification_reads: bukan tabel per-site seperti yang lain — kepemilikan
-- baris ditentukan oleh user_id (siapa yang menandai baca), bukan site_id.
-- Setiap user hanya boleh melihat/menulis/menghapus penanda baca miliknya
-- sendiri (dipakai untuk hitung badge "belum dibaca" & tombol "tandai dibaca").
drop policy if exists notification_reads_own on notification_reads;
create policy notification_reads_own on notification_reads for all
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ai_insights: SELECT/INSERT mengikuti akses server (has_site_access), sama
-- seperti tabel operasional lain — user hanya melihat/menambah riwayat
-- analisis AI untuk server yang mereka punya akses. DELETE khusus admin
-- (riwayat AI adalah audit trail, bukan data kerja harian). Sengaja TIDAK
-- ada policy UPDATE — hasil analisis immutable, riwayat baru = baris baru.
drop policy if exists ai_insights_select on ai_insights;
create policy ai_insights_select on ai_insights
  for select using (is_admin() or site_id is null or has_site_access(site_id));

drop policy if exists ai_insights_insert on ai_insights;
create policy ai_insights_insert on ai_insights
  for insert with check (is_admin() or site_id is null or has_site_access(site_id));

drop policy if exists ai_insights_delete on ai_insights;
create policy ai_insights_delete on ai_insights
  for delete using (is_admin());

-- =====================================================================
-- SELESAI. Jalankan file ini secara utuh & manual di Supabase SQL Editor.
-- Tidak dijalankan otomatis oleh index.html atau pipeline apa pun.
-- =====================================================================
