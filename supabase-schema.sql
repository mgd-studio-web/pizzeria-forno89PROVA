-- ============================================================================
-- Pizzeria Forno 89 — Schema Database Supabase (PostgreSQL)
-- Progetto dimostrativo MGD Studio — Pronto per migrazione da localStorage a cloud
-- ============================================================================

-- Estensione per UUID (già abilitata di default su Supabase)
create extension if not exists pgcrypto;

-- ----------------------------------------------------------------------------
-- 1. Tabella impostazioni sala (`sala_settings`)
--    Singola riga di configurazione (id = 1) gestita dal Pannello Host.
-- ----------------------------------------------------------------------------
create table if not exists public.sala_settings (
  id integer primary key default 1 check (id = 1),
  slot_capacity integer not null default 35 check (slot_capacity between 1 and 300),
  is_online_booking_open boolean not null default true,
  closed_dates date[] not null default '{}',
  demo_full_slot text,
  updated_at timestamptz not null default now()
);

comment on table public.sala_settings is
  'Configurazione operativa della sala: capienza per fascia oraria e stato prenotazioni online.';

-- Configurazione iniziale predefinita
insert into public.sala_settings (id, slot_capacity, is_online_booking_open, closed_dates, demo_full_slot)
values (1, 35, true, '{}', '21:00')
on conflict (id) do nothing;

-- ----------------------------------------------------------------------------
-- 2. Tabella prenotazioni (`bookings`)
-- ----------------------------------------------------------------------------
create table if not exists public.bookings (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (code ~ '^#F89-[0-9]{3,4}$'),
  booking_date date not null,
  booking_time text not null check (
    booking_time in ('19:00', '19:30', '20:00', '20:30', '21:00', '21:30', '22:00', '22:30')
  ),
  guest_count integer not null check (guest_count between 1 and 30),
  guest_label text not null default '2',
  customer_name text not null check (char_length(trim(customer_name)) >= 2),
  customer_phone text not null check (char_length(trim(customer_phone)) >= 6),
  zone text not null default 'Sala principale' check (
    zone in ('Sala principale', 'Vicino al forno a legna', 'Dehors')
  ),
  notes text not null default '',
  status text not null default 'confirmed' check (
    status in ('pending', 'confirmed', 'seated', 'cancelled')
  ),
  source text not null default 'online' check (source in ('online', 'phone')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.bookings is
  'Prenotazioni tavoli di Pizzeria Forno 89 (sia online dal sito che telefoniche da Area Host).';

-- Indici per calcolo rapido capienza per fascia oraria e filtri del pannello host
create index if not exists idx_bookings_date_time_status
  on public.bookings (booking_date, booking_time, status);

create index if not exists idx_bookings_date_created
  on public.bookings (booking_date, created_at desc);

create index if not exists idx_bookings_status
  on public.bookings (status);

-- ----------------------------------------------------------------------------
-- 3. Trigger automatico `updated_at`
-- ----------------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_sala_settings_updated_at on public.sala_settings;
create trigger trg_sala_settings_updated_at
  before update on public.sala_settings
  for each row execute function public.set_updated_at();

drop trigger if exists trg_bookings_updated_at on public.bookings;
create trigger trg_bookings_updated_at
  before update on public.bookings
  for each row execute function public.set_updated_at();

-- ----------------------------------------------------------------------------
-- 4. Funzione RPC sicura per leggere i coperti occupati senza esporre dati PII
--    Chiamabile dal sito pubblico (`index.html`) per calcolare la disponibilità
--    reale di ogni fascia oraria senza esporre nomi/telefoni degli altri clienti.
-- ----------------------------------------------------------------------------
create or replace function public.get_slot_occupancy(target_date date)
returns table (
  booking_time text,
  booked_seats integer,
  active_tables integer
)
language sql
security definer
set search_path = public
as $$
  select
    b.booking_time,
    coalesce(sum(b.guest_count), 0)::integer as booked_seats,
    count(*)::integer as active_tables
  from public.bookings b
  where b.booking_date = target_date
    and b.status in ('pending', 'confirmed', 'seated')
  group by b.booking_time
  order by b.booking_time;
$$;

-- ----------------------------------------------------------------------------
-- 5. Row Level Security (RLS) — Policy consigliate per produzione
-- ----------------------------------------------------------------------------
alter table public.sala_settings enable row level security;
alter table public.bookings enable row level security;

-- Impostazioni sala:
-- - Chiunque (anon/authenticated) può leggere capienza e stato aperture online
-- - Solo utenti autenticati con ruolo host/admin possono modificare le impostazioni
create policy "Public can read sala settings"
  on public.sala_settings
  for select
  to anon, authenticated
  using (true);

create policy "Authenticated host can update sala settings"
  on public.sala_settings
  for update
  to authenticated
  using (auth.role() = 'authenticated')
  with check (auth.role() = 'authenticated');

-- Prenotazioni:
-- - Il sito pubblico (`anon`) può SOLO inserire nuove prenotazioni con source = 'online'
--   (per leggere la disponibilità usa la RPC `get_slot_occupancy`, proteggendo la privacy!)
-- - Solo l'host autenticato (Supabase Auth in `admin.html`) può leggere, aggiornare o gestire tutte le righe
create policy "Public can insert online bookings"
  on public.bookings
  for insert
  to anon, authenticated
  with check (
    source = 'online'
    and status in ('pending', 'confirmed')
  );

create policy "Authenticated host can read all bookings"
  on public.bookings
  for select
  to authenticated
  using (auth.role() = 'authenticated');

create policy "Authenticated host can insert phone bookings"
  on public.bookings
  for insert
  to authenticated
  with check (auth.role() = 'authenticated');

create policy "Authenticated host can update bookings"
  on public.bookings
  for update
  to authenticated
  using (auth.role() = 'authenticated')
  with check (auth.role() = 'authenticated');

-- Nota produzione:
-- 1. Sostituire il controllo PIN demo lato client di `admin.html` con Supabase Auth
--    (email + password o Magic Link riservato allo staff) e verificare opzionalmente
--    un custom claim `auth.jwt() ->> 'role' = 'host'` nelle policy sopra.
-- 2. Abilitare Supabase Realtime su `public.bookings` e `public.sala_settings`:
--    alter publication supabase_realtime add table public.bookings, public.sala_settings;
