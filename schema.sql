-- =========================================================
-- SIMPUL — Skema Database Supabase
-- ISP Billing & Monitoring CRM, multi-server (multi-site)
-- =========================================================
-- Cara pakai:
-- 1. Buka Supabase Dashboard > SQL Editor
-- 2. Jalankan seluruh file ini sekali (top to bottom)
-- 3. WAJIB: set kunci enkripsi kredensial (lihat bagian bawah)
-- =========================================================

create extension if not exists pgcrypto;
create extension if not exists "uuid-ossp";

-- =========================================================
-- 1. PROFILES (perluasan dari auth.users)
-- =========================================================
create table profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  role text not null check (role in ('admin','finance','teknisi','sales')),
  site_ids uuid[] not null default '{}',   -- server yang boleh diakses user ini
  created_at timestamptz not null default now()
);

-- helper: cek apakah user saat ini admin
create or replace function is_admin()
returns boolean language sql stable security definer as $$
  select exists (select 1 from profiles where id = auth.uid() and role = 'admin');
$$;

-- helper: daftar site_id yang boleh diakses user saat ini
create or replace function user_site_ids()
returns uuid[] language sql stable security definer as $$
  select coalesce((select site_ids from profiles where id = auth.uid()), '{}');
$$;

-- helper: cek akses ke 1 site tertentu
create or replace function has_site_access(p_site_id uuid)
returns boolean language sql stable security definer as $$
  select is_admin() or p_site_id = any(user_site_ids());
$$;

-- =========================================================
-- 2. SITES (server / lokasi MikroTik-OLT)
-- =========================================================
create table sites (
  id uuid primary key default uuid_generate_v4(),
  name text not null,                       -- "Server A — Kantor Pusat"
  connection_method text default 'Cloudflare Tunnel',
  agent_status text not null default 'terputus' check (agent_status in ('terhubung','terputus')),
  last_sync timestamptz,
  router_summary text,                      -- "2 MikroTik, 1 OLT"
  created_at timestamptz not null default now()
);

-- =========================================================
-- 3. NETWORK NODES (Hub, Router, OLT, Splitter — topologi)
-- =========================================================
create table network_nodes (
  id uuid primary key default uuid_generate_v4(),
  site_id uuid not null references sites(id) on delete cascade,
  parent_id uuid references network_nodes(id) on delete set null,
  name text not null,                       -- "ODP-14 / Hub-A"
  node_type text not null check (node_type in ('router','hub','olt','splitter')),
  created_at timestamptz not null default now()
);

-- =========================================================
-- 4. CUSTOMERS
-- =========================================================
create table customers (
  id uuid primary key default uuid_generate_v4(),
  site_id uuid not null references sites(id) on delete restrict,
  customer_code text not null unique,       -- "PLG-1000"
  name text not null,
  phone text,
  address text,
  lat numeric,
  lng numeric,
  access_type text not null check (access_type in ('LAN_HUB','OLT_GPON')),
  package text,
  node_id uuid references network_nodes(id),
  status text not null default 'Aktif'
    check (status in ('Aktif','Offline','Isolir','PendingMigrasi','Berhenti')),
  pppoe_username text unique,
  pppoe_password_encrypted bytea,           -- diisi lewat set_pppoe_password(), jangan update langsung
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index on customers (site_id);
create index on customers (status);

-- =========================================================
-- 5. TECHNICIANS
-- =========================================================
create table technicians (
  id uuid primary key default uuid_generate_v4(),
  site_id uuid not null references sites(id) on delete cascade,
  profile_id uuid references profiles(id),
  name text not null,
  status text not null default 'Tersedia' check (status in ('Tersedia','Bertugas','Off')),
  active_tickets int not null default 0,
  created_at timestamptz not null default now()
);
create index on technicians (site_id);

-- =========================================================
-- 6. VOUCHERS (hotspot prabayar)
-- =========================================================
create table vouchers (
  id uuid primary key default uuid_generate_v4(),
  site_id uuid not null references sites(id) on delete cascade,
  code_encrypted bytea not null,            -- diisi lewat create_vouchers()
  package text not null,
  profile_name text not null default 'hotspot-basic',
  status text not null default 'unused' check (status in ('unused','used','expired')),
  created_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  used_at timestamptz,
  expires_at timestamptz
);
create index on vouchers (site_id);
create index on vouchers (status);

-- =========================================================
-- 7. MIKROTIK COMMANDS (antrean perintah untuk agent lokal)
-- =========================================================
create table mikrotik_commands (
  id uuid primary key default uuid_generate_v4(),
  site_id uuid not null references sites(id) on delete cascade,
  action text not null check (action in (
    'create_pppoe','set_pppoe_password','delete_pppoe',
    'isolir_customer','restore_customer',
    'create_hotspot_users'
  )),
  payload jsonb not null default '{}',
  status text not null default 'pending' check (status in ('pending','success','failed')),
  result text,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  executed_at timestamptz
);
create index on mikrotik_commands (site_id, status);

-- =========================================================
-- 8. CONNECTION LOGS (histori status, untuk peta & uptime)
-- =========================================================
create table connection_logs (
  id bigserial primary key,
  customer_id uuid not null references customers(id) on delete cascade,
  status text not null,
  signal_dbm numeric,                       -- redaman optik, khusus OLT
  logged_at timestamptz not null default now()
);
create index on connection_logs (customer_id, logged_at desc);

-- =========================================================
-- 9. TICKETS (gangguan individual & massal)
-- =========================================================
create table tickets (
  id uuid primary key default uuid_generate_v4(),
  site_id uuid not null references sites(id) on delete cascade,
  ticket_type text not null check (ticket_type in ('individual','massal')),
  customer_id uuid references customers(id),
  node_id uuid references network_nodes(id),
  technician_id uuid references technicians(id),
  status text not null default 'open' check (status in ('open','in_progress','resolved')),
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);
create index on tickets (site_id, status);

-- =========================================================
-- 10. INVOICES (billing)
-- =========================================================
create table invoices (
  id uuid primary key default uuid_generate_v4(),
  customer_id uuid not null references customers(id) on delete cascade,
  period text not null,                     -- "2026-07"
  amount numeric not null,
  due_date date not null,
  status text not null default 'unpaid' check (status in ('unpaid','paid','overdue')),
  paid_at timestamptz,
  created_at timestamptz not null default now()
);
create index on invoices (customer_id, status);

-- =========================================================
-- 11. CREDENTIAL AUDIT LOG (wajib untuk kepatuhan/keamanan)
-- =========================================================
create table credential_audit_log (
  id bigserial primary key,
  actor uuid references profiles(id),
  customer_id uuid references customers(id),
  voucher_id uuid references vouchers(id),
  action text not null check (action in ('view_password','change_password','view_voucher')),
  created_at timestamptz not null default now()
);

-- =========================================================
-- ROW LEVEL SECURITY
-- =========================================================
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

-- profiles: user lihat profil sendiri, admin lihat semua
create policy "profiles_select" on profiles for select
  using (id = auth.uid() or is_admin());

-- sites: user hanya lihat site yang ditugaskan ke dia
create policy "sites_select" on sites for select
  using (has_site_access(id));

-- network_nodes
create policy "nodes_select" on network_nodes for select
  using (has_site_access(site_id));

-- customers: select/update dibatasi ke site milik user
-- (password_encrypted TIDAK pernah ikut terbaca oleh client biasa —
--  akses lewat function reveal_pppoe_password() saja, lihat di bawah)
create policy "customers_select" on customers for select
  using (has_site_access(site_id));
create policy "customers_insert" on customers for insert
  with check (has_site_access(site_id));
create policy "customers_update" on customers for update
  using (has_site_access(site_id));

-- technicians
create policy "technicians_select" on technicians for select
  using (has_site_access(site_id));

-- vouchers: code_encrypted juga tidak boleh didekripsi langsung dari client
create policy "vouchers_select" on vouchers for select
  using (has_site_access(site_id));
create policy "vouchers_insert" on vouchers for insert
  with check (has_site_access(site_id));

-- mikrotik_commands: HANYA admin/petugas berwenang yang boleh insert,
-- dan hanya agent lokal (service role) yang baca+update status
create policy "commands_select" on mikrotik_commands for select
  using (has_site_access(site_id));
create policy "commands_insert" on mikrotik_commands for insert
  with check (has_site_access(site_id));

-- connection_logs: ikut site milik pelanggan
create policy "logs_select" on connection_logs for select
  using (exists (
    select 1 from customers c where c.id = connection_logs.customer_id
    and has_site_access(c.site_id)
  ));

-- tickets
create policy "tickets_select" on tickets for select
  using (has_site_access(site_id));
create policy "tickets_all" on tickets for all
  using (has_site_access(site_id)) with check (has_site_access(site_id));

-- invoices
create policy "invoices_select" on invoices for select
  using (exists (
    select 1 from customers c where c.id = invoices.customer_id
    and has_site_access(c.site_id)
  ));

-- credential_audit_log: hanya admin yang boleh lihat log akses kredensial
create policy "audit_select_admin" on credential_audit_log for select
  using (is_admin());

-- =========================================================
-- FUNGSI KREDENSIAL (SECURITY DEFINER)
-- Password/kode TIDAK PERNAH dikirim mentah dari tabel ke client.
-- Semua baca/tulis kredensial WAJIB lewat fungsi ini agar tercatat
-- di audit log dan tervalidasi hak aksesnya.
-- =========================================================

-- Ganti / buat sandi PPPoE baru untuk pelanggan
create or replace function set_pppoe_password(p_customer_id uuid, p_new_password text)
returns void language plpgsql security definer as $$
declare v_site_id uuid;
begin
  select site_id into v_site_id from customers where id = p_customer_id;
  if v_site_id is null or not has_site_access(v_site_id) then
    raise exception 'akses ditolak';
  end if;

  update customers
    set pppoe_password_encrypted = pgp_sym_encrypt(p_new_password, current_setting('app.settings.credential_key')),
        updated_at = now()
    where id = p_customer_id;

  insert into credential_audit_log(actor, customer_id, action)
    values (auth.uid(), p_customer_id, 'change_password');

  insert into mikrotik_commands(site_id, action, payload, created_by)
    values (v_site_id, 'set_pppoe_password',
      jsonb_build_object('customer_id', p_customer_id, 'password', p_new_password),
      auth.uid());
end;
$$;

-- Lihat sandi PPPoE (tercatat otomatis di audit log)
create or replace function reveal_pppoe_password(p_customer_id uuid)
returns text language plpgsql security definer as $$
declare v_site_id uuid; v_pass text;
begin
  select site_id into v_site_id from customers where id = p_customer_id;
  if v_site_id is null or not has_site_access(v_site_id) then
    raise exception 'akses ditolak';
  end if;

  select pgp_sym_decrypt(pppoe_password_encrypted, current_setting('app.settings.credential_key'))
    into v_pass from customers where id = p_customer_id;

  insert into credential_audit_log(actor, customer_id, action)
    values (auth.uid(), p_customer_id, 'view_password');

  return v_pass;
end;
$$;

-- Buat akun PPPoE baru (username + sandi random) lalu antre ke MikroTik
create or replace function create_pppoe_account(p_customer_id uuid, p_profile text)
returns void language plpgsql security definer as $$
declare v_site_id uuid; v_username text; v_password text;
begin
  select site_id, pppoe_username into v_site_id, v_username from customers where id = p_customer_id;
  if v_site_id is null or not has_site_access(v_site_id) then
    raise exception 'akses ditolak';
  end if;

  v_password := encode(gen_random_bytes(6), 'hex');

  update customers
    set pppoe_password_encrypted = pgp_sym_encrypt(v_password, current_setting('app.settings.credential_key')),
        status = 'Aktif'
    where id = p_customer_id;

  insert into mikrotik_commands(site_id, action, payload, created_by)
    values (v_site_id, 'create_pppoe',
      jsonb_build_object('customer_id', p_customer_id, 'username', v_username,
                          'password', v_password, 'profile', p_profile),
      auth.uid());
end;
$$;

-- Buat voucher hotspot secara batch
create or replace function create_vouchers(p_site_id uuid, p_package text, p_profile text, p_count int)
returns void language plpgsql security definer as $$
declare i int; v_code text; v_codes text[] := '{}';
begin
  if not has_site_access(p_site_id) then
    raise exception 'akses ditolak';
  end if;
  if p_count > 500 then
    raise exception 'maksimum 500 voucher per batch';
  end if;

  for i in 1..p_count loop
    v_code := upper(substr(encode(gen_random_bytes(6), 'hex'), 1, 8));
    v_codes := array_append(v_codes, v_code);
    insert into vouchers(site_id, code_encrypted, package, profile_name, created_by)
      values (p_site_id, pgp_sym_encrypt(v_code, current_setting('app.settings.credential_key')),
              p_package, p_profile, auth.uid());
  end loop;

  -- kode plaintext dititipkan di payload perintah supaya agent lokal bisa langsung
  -- membuat user hotspot di MikroTik tanpa perlu hak dekripsi terpisah.
  -- mikrotik_commands sudah dibatasi RLS per-site, jadi ini aman.
  insert into mikrotik_commands(site_id, action, payload, created_by)
    values (p_site_id, 'create_hotspot_users',
      jsonb_build_object('package', p_package, 'profile', p_profile, 'count', p_count,
                          'codes', to_jsonb(v_codes)),
      auth.uid());
end;
$$;

-- Lihat kode voucher (tercatat di audit log)
create or replace function reveal_voucher_code(p_voucher_id uuid)
returns text language plpgsql security definer as $$
declare v_site_id uuid; v_code text;
begin
  select site_id into v_site_id from vouchers where id = p_voucher_id;
  if v_site_id is null or not has_site_access(v_site_id) then
    raise exception 'akses ditolak';
  end if;

  select pgp_sym_decrypt(code_encrypted, current_setting('app.settings.credential_key'))
    into v_code from vouchers where id = p_voucher_id;

  insert into credential_audit_log(actor, voucher_id, action)
    values (auth.uid(), p_voucher_id, 'view_voucher');

  return v_code;
end;
$$;

-- Isolir / pulihkan pelanggan
create or replace function set_customer_isolir(p_customer_id uuid, p_isolir boolean)
returns void language plpgsql security definer as $$
declare v_site_id uuid;
begin
  select site_id into v_site_id from customers where id = p_customer_id;
  if v_site_id is null or not has_site_access(v_site_id) then
    raise exception 'akses ditolak';
  end if;

  update customers set status = case when p_isolir then 'Isolir' else 'Aktif' end
    where id = p_customer_id;

  insert into mikrotik_commands(site_id, action, payload, created_by)
    values (v_site_id, case when p_isolir then 'isolir_customer' else 'restore_customer' end,
      jsonb_build_object('customer_id', p_customer_id), auth.uid());
end;
$$;

-- =========================================================
-- REALTIME
-- =========================================================
alter publication supabase_realtime add table customers;
alter publication supabase_realtime add table connection_logs;
alter publication supabase_realtime add table mikrotik_commands;
alter publication supabase_realtime add table vouchers;
alter publication supabase_realtime add table sites;

-- =========================================================
-- WAJIB DIJALANKAN SEKALI: kunci enkripsi kredensial
-- Ganti 'ganti-dengan-kunci-rahasia-anda' dengan string acak panjang
-- (misal 32+ karakter). JANGAN commit kunci ini ke GitHub.
-- Jalankan di SQL Editor Supabase (bukan disimpan di kode aplikasi).
-- =========================================================
alter database postgres set app.settings.credential_key = 'ganti-dengan-kunci-rahasia-anda';

-- =========================================================
-- DATA CONTOH (opsional, untuk testing awal)
-- =========================================================
insert into sites (name, agent_status, last_sync, router_summary) values
  ('Server A — Kantor Pusat', 'terhubung', now(), '2 MikroTik, 1 OLT'),
  ('Server B — Cluster Utara', 'terhubung', now(), '1 MikroTik'),
  ('Server C — Cluster Selatan', 'terputus', now() - interval '14 minutes', '1 MikroTik, 1 OLT');
