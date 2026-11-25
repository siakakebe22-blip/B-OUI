-- B-OUI / Migration 0001 : fondations du modèle de données
-- Cible : PostgreSQL / Supabase. À exécuter uniquement dans un environnement de test isolé.
-- Cette migration crée le modèle et active RLS. Les écritures sensibles restent réservées au backend de confiance.
-- Aucun secret, webhook Orange Money ou service-role key ne doit être placé dans le frontend.

begin;

create extension if not exists pgcrypto;

create type public.school_status as enum ('pending', 'verified', 'rejected', 'suspended');
create type public.event_status as enum ('draft', 'pending_review', 'approved', 'published', 'suspended', 'completed', 'cancelled');
create type public.reservation_status as enum ('pending_payment', 'paid', 'expired', 'cancelled', 'refunded');
create type public.payment_status as enum ('pending', 'confirmed', 'failed', 'expired', 'refunded', 'partially_refunded');
create type public.ticket_status as enum ('valid', 'used', 'cancelled', 'refunded');
create type public.refund_status as enum ('requested', 'under_review', 'approved', 'rejected', 'executed');
create type public.membership_role as enum ('owner', 'school_admin', 'finance', 'event_manager', 'checkin_agent', 'viewer');
create type public.approval_decision as enum ('pending', 'approved', 'rejected');

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null default '' check (char_length(full_name) <= 160),
  phone_e164 text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.schools (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(trim(name)) between 2 and 180),
  slug text not null unique check (slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
  city text not null,
  contact_email text,
  contact_phone text,
  status public.school_status not null default 'pending',
  verified_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.school_members (
  school_id uuid not null references public.schools(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  role public.membership_role not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  primary key (school_id, user_id)
);

create table public.events (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references public.schools(id) on delete restrict,
  title text not null check (char_length(trim(title)) between 3 and 180),
  slug text not null,
  description text not null default '',
  city text not null,
  venue text not null,
  starts_at timestamptz not null,
  ends_at timestamptz,
  status public.event_status not null default 'draft',
  submitted_at timestamptz,
  approved_at timestamptz,
  published_at timestamptz,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (school_id, slug),
  unique (id, school_id),
  check (ends_at is null or ends_at > starts_at)
);

create table public.event_approvals (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete restrict,
  decision public.approval_decision not null default 'pending',
  reviewer_user_id uuid references public.profiles(id) on delete set null,
  note text,
  decided_at timestamptz,
  created_at timestamptz not null default now()
);

create table public.organizers (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references public.schools(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  display_name text not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (school_id, user_id),
  unique (id, school_id)
);

create table public.event_organizers (
  event_id uuid not null,
  organizer_id uuid not null,
  school_id uuid not null,
  created_at timestamptz not null default now(),
  primary key (event_id, organizer_id),
  foreign key (event_id, school_id) references public.events(id, school_id) on delete cascade,
  foreign key (organizer_id, school_id) references public.organizers(id, school_id) on delete cascade
);

create table public.ticket_types (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete restrict,
  name text not null,
  description text not null default '',
  price_gnf bigint not null check (price_gnf >= 0),
  quantity_total integer not null check (quantity_total >= 0),
  quantity_reserved integer not null default 0 check (quantity_reserved >= 0),
  quantity_sold integer not null default 0 check (quantity_sold >= 0),
  sales_start_at timestamptz,
  sales_end_at timestamptz,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, event_id),
  check (quantity_reserved + quantity_sold <= quantity_total),
  check (sales_end_at is null or sales_start_at is null or sales_end_at > sales_start_at)
);

create table public.reservations (
  id uuid primary key default gen_random_uuid(),
  reference text not null unique,
  buyer_user_id uuid references public.profiles(id) on delete set null,
  buyer_name text not null,
  buyer_email text,
  buyer_phone text,
  event_id uuid not null references public.events(id) on delete restrict,
  status public.reservation_status not null default 'pending_payment',
  currency char(3) not null default 'GNF' check (currency = 'GNF'),
  total_amount_gnf bigint not null check (total_amount_gnf >= 0),
  idempotency_key uuid not null unique,
  expires_at timestamptz not null,
  paid_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, event_id)
);

create table public.reservation_items (
  id uuid primary key default gen_random_uuid(),
  reservation_id uuid not null,
  event_id uuid not null,
  ticket_type_id uuid not null,
  quantity integer not null check (quantity > 0),
  unit_price_gnf bigint not null check (unit_price_gnf >= 0),
  line_total_gnf bigint generated always as (quantity::bigint * unit_price_gnf) stored,
  created_at timestamptz not null default now(),
  foreign key (reservation_id, event_id) references public.reservations(id, event_id) on delete restrict,
  foreign key (ticket_type_id, event_id) references public.ticket_types(id, event_id) on delete restrict,
  unique (id, reservation_id)
);

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  reservation_id uuid not null references public.reservations(id) on delete restrict,
  provider text not null check (provider in ('orange_money_gn', 'mtn_momo_gn')),
  provider_transaction_id text,
  idempotency_key uuid not null unique,
  status public.payment_status not null default 'pending',
  amount_gnf bigint not null check (amount_gnf >= 0),
  currency char(3) not null default 'GNF' check (currency = 'GNF'),
  provider_payload_redacted jsonb not null default '{}'::jsonb,
  confirmed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, reservation_id)
);
create unique index payments_provider_transaction_unique
  on public.payments(provider, provider_transaction_id)
  where provider_transaction_id is not null;
create unique index payments_one_confirmed_per_reservation
  on public.payments(reservation_id)
  where status = 'confirmed';

create table public.tickets (
  id uuid primary key default gen_random_uuid(),
  reservation_id uuid not null,
  reservation_item_id uuid not null,
  ticket_number text not null unique,
  qr_token_hash bytea not null unique,
  status public.ticket_status not null default 'valid',
  issued_at timestamptz not null default now(),
  used_at timestamptz,
  created_at timestamptz not null default now(),
  foreign key (reservation_item_id, reservation_id)
    references public.reservation_items(id, reservation_id) on delete restrict
);

create table public.ticket_scans (
  id uuid primary key default gen_random_uuid(),
  ticket_id uuid not null references public.tickets(id) on delete restrict,
  event_id uuid not null references public.events(id) on delete restrict,
  scanned_by uuid references public.profiles(id) on delete set null,
  result text not null check (result in ('accepted', 'already_used', 'invalid', 'cancelled', 'wrong_event')),
  scanned_at timestamptz not null default now(),
  device_reference text
);
create unique index ticket_scans_one_accepted_entry
  on public.ticket_scans(ticket_id) where result = 'accepted';

create table public.commission_rules (
  id uuid primary key default gen_random_uuid(),
  school_id uuid references public.schools(id) on delete cascade,
  event_id uuid references public.events(id) on delete cascade,
  rate_basis_points integer not null check (rate_basis_points between 0 and 10000),
  fixed_fee_gnf bigint not null default 0 check (fixed_fee_gnf >= 0),
  active boolean not null default true,
  valid_from timestamptz not null default now(),
  valid_until timestamptz,
  created_at timestamptz not null default now(),
  check (valid_until is null or valid_until > valid_from),
  check (event_id is null or school_id is not null)
);

create table public.refunds (
  id uuid primary key default gen_random_uuid(),
  payment_id uuid not null references public.payments(id) on delete restrict,
  requested_by uuid references public.profiles(id) on delete set null,
  amount_gnf bigint not null check (amount_gnf > 0),
  reason text not null,
  status public.refund_status not null default 'requested',
  reviewed_by uuid references public.profiles(id) on delete set null,
  provider_refund_id text,
  requested_at timestamptz not null default now(),
  reviewed_at timestamptz,
  executed_at timestamptz
);

create table public.ticket_recovery_attempts (
  id uuid primary key default gen_random_uuid(),
  reservation_reference_hash bytea not null,
  destination_hash bytea not null,
  otp_hash bytea,
  attempts integer not null default 0 check (attempts between 0 and 10),
  expires_at timestamptz not null,
  verified_at timestamptz,
  requested_at timestamptz not null default now(),
  request_ip_hash bytea
);

create table public.platform_settings (
  key text primary key,
  value jsonb not null,
  updated_at timestamptz not null default now()
);

create table public.audit_logs (
  id bigint generated always as identity primary key,
  actor_user_id uuid references public.profiles(id) on delete set null,
  action text not null,
  entity_type text not null,
  entity_id uuid,
  metadata_redacted jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

-- Indexes supporting tenant filtering and common lookups.
create index school_members_user_active_idx on public.school_members(user_id) where active;
create index events_school_status_idx on public.events(school_id, status);
create index events_public_listing_idx on public.events(starts_at) where status = 'published';
create index ticket_types_event_active_idx on public.ticket_types(event_id) where active;
create index reservations_buyer_created_idx on public.reservations(buyer_user_id, created_at desc);
create index reservations_expiry_idx on public.reservations(expires_at) where status = 'pending_payment';
create index reservation_items_reservation_idx on public.reservation_items(reservation_id);
create index payments_reservation_created_idx on public.payments(reservation_id, created_at desc);
create index tickets_reservation_idx on public.tickets(reservation_id);
create index ticket_scans_event_date_idx on public.ticket_scans(event_id, scanned_at desc);
create index refunds_payment_idx on public.refunds(payment_id);
create index audit_logs_entity_idx on public.audit_logs(entity_type, entity_id, created_at desc);

-- RLS is enabled everywhere. This first migration is deliberately closed by default:
-- only the explicitly listed read policies are granted to clients. Sensitive writes
-- (reservation, payment, ticket, quota, refund, scan, commission, approval, audit)
-- must be implemented through audited backend functions in later migrations.
alter table public.profiles enable row level security;
alter table public.schools enable row level security;
alter table public.school_members enable row level security;
alter table public.events enable row level security;
alter table public.event_approvals enable row level security;
alter table public.organizers enable row level security;
alter table public.event_organizers enable row level security;
alter table public.ticket_types enable row level security;
alter table public.reservations enable row level security;
alter table public.reservation_items enable row level security;
alter table public.payments enable row level security;
alter table public.tickets enable row level security;
alter table public.ticket_scans enable row level security;
alter table public.commission_rules enable row level security;
alter table public.refunds enable row level security;
alter table public.ticket_recovery_attempts enable row level security;
alter table public.platform_settings enable row level security;
alter table public.audit_logs enable row level security;

create policy profiles_select_self on public.profiles
  for select to authenticated using (id = (select auth.uid()));
create policy profiles_update_self on public.profiles
  for update to authenticated using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

create policy schools_select_verified on public.schools
  for select to anon, authenticated using (status = 'verified');

create policy events_select_published on public.events
  for select to anon, authenticated using (
    status = 'published'
    and exists (
      select 1 from public.schools s
      where s.id = events.school_id and s.status = 'verified'
    )
  );

create policy school_members_select_self on public.school_members
  for select to authenticated using (user_id = (select auth.uid()));

create policy ticket_types_select_published_event on public.ticket_types
  for select to anon, authenticated using (
    active and exists (
      select 1 from public.events e
      join public.schools s on s.id = e.school_id
      where e.id = ticket_types.event_id
        and e.status = 'published'
        and s.status = 'verified'
    )
  );

create policy reservations_select_buyer on public.reservations
  for select to authenticated using (buyer_user_id = (select auth.uid()));

create policy reservation_items_select_buyer on public.reservation_items
  for select to authenticated using (
    exists (
      select 1 from public.reservations r
      where r.id = reservation_items.reservation_id
        and r.buyer_user_id = (select auth.uid())
    )
  );

create policy payments_select_buyer on public.payments
  for select to authenticated using (
    exists (
      select 1 from public.reservations r
      where r.id = payments.reservation_id
        and r.buyer_user_id = (select auth.uid())
    )
  );

create policy tickets_select_buyer on public.tickets
  for select to authenticated using (
    exists (
      select 1 from public.reservations r
      where r.id = tickets.reservation_id
        and r.buyer_user_id = (select auth.uid())
    )
  );

-- No client policies are intentionally created for approvals, scans, commissions,
-- refunds, recovery attempts, settings or audit logs. Access is backend-only.

commit;
