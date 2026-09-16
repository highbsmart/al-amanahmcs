-- =========================================================
-- AL-AMANAH MULTI-PURPOSE CO-OPERATIVE SOCIETY
-- Supabase / Postgres schema
-- Run this once in Supabase: Dashboard -> SQL Editor -> New query -> paste -> Run
-- =========================================================

-- ---------------------------------------------------------
-- 1. MEMBER DIRECTORY (pre-loaded by admin, before any member
--    has created a password). This is the "who is allowed to
--    register" list. It holds NO login credentials.
-- ---------------------------------------------------------
create table if not exists member_directory (
  alamanah_no      text primary key,
  surname          text not null,
  first_name       text not null,
  department       text,
  phone            text,
  contact_email    text,
  savings_balance  numeric not null default 0,
  monthly_savings_amount numeric not null default 0,
  joined           date not null default current_date,
  claimed          boolean not null default false,
  created_at       timestamptz not null default now()
);

-- ---------------------------------------------------------
-- 2. PROFILES (one row per real login account, created
--    automatically the moment a member sets their password)
-- ---------------------------------------------------------
create table if not exists profiles (
  id               uuid primary key references auth.users(id) on delete cascade,
  alamanah_no      text unique not null,
  surname          text not null,
  first_name       text not null,
  department       text,
  phone            text,
  contact_email    text,
  savings_balance  numeric not null default 0,
  total_admin_charges numeric not null default 0,
  joined           date not null default current_date,
  is_admin         boolean not null default false,
  status           text not null default 'active' check (status in ('active','retired','dismissed')),
  savings_last_reviewed date not null default current_date,
  -- deduction management (admin-only) — see migration_admin_deduction_controls.sql
  monthly_savings_amount numeric not null default 0,
  savings_paused      boolean not null default false,
  deductions_paused   boolean not null default false,
  last_savings_date   date,
  last_savings_amount numeric not null default 0,
  next_savings_date   date,
  next_savings_amount numeric not null default 0,
  created_at       timestamptz not null default now()
);

-- ---------------------------------------------------------
-- 3. LOANS
-- ---------------------------------------------------------
create table if not exists loans (
  id                     text primary key,
  member_id              uuid not null references profiles(id) on delete cascade,
  type                   text not null check (type in ('real','commodity','humanitarian')),
  amount                 numeric not null check (amount > 0),
  purpose                text not null,
  duration               int not null,
  date_applied           date not null default current_date,
  status                 text not null default 'pending' check (status in ('pending','approved','declined','completed')),
  date_decision          date,
  decline_reason         text,
  admin_charge           numeric not null default 0,
  balance                numeric,
  admin_charge_balance   numeric,
  monthly_deduction      numeric not null default 0,
  admin_monthly_deduction numeric not null default 0,
  months_paid            int not null default 0,
  created_at             timestamptz not null default now()
);

-- ---------------------------------------------------------
-- 4. TRANSACTIONS
-- ---------------------------------------------------------
create table if not exists transactions (
  id           uuid primary key default gen_random_uuid(),
  member_id    uuid not null references profiles(id) on delete cascade,
  date         date not null default current_date,
  description  text not null,
  amount       numeric not null,
  type         text not null check (type in ('savings','loan','admin_charge')),
  created_at   timestamptz not null default now()
);

-- ---------------------------------------------------------
-- 4b. SAVINGS ADJUSTMENTS (audit trail for manual admin edits
--     to a member's savings balance)
-- ---------------------------------------------------------
create table if not exists savings_adjustments (
  id              uuid primary key default gen_random_uuid(),
  member_id       uuid not null references profiles(id) on delete cascade,
  previous_amount numeric not null,
  new_amount      numeric not null,
  reason          text not null,
  adjusted_by     uuid not null references profiles(id),
  created_at      timestamptz not null default now()
);

-- ---------------------------------------------------------
-- 4c. ADMIN CHARGE ADJUSTMENTS (audit trail for manual admin
--     corrections to a member's total admin charges figure)
-- ---------------------------------------------------------
create table if not exists admin_charge_adjustments (
  id              uuid primary key default gen_random_uuid(),
  member_id       uuid not null references profiles(id) on delete cascade,
  previous_amount numeric not null,
  new_amount      numeric not null,
  reason          text not null,
  adjusted_by     uuid not null references profiles(id),
  created_at      timestamptz not null default now()
);

-- ---------------------------------------------------------
-- 5. SECURE SIGN-UP: link a new auth.users row to an existing
--    member_directory entry. Runs server-side, so the client
--    can never fabricate a member record for itself.
-- ---------------------------------------------------------
create or replace function public.handle_new_member()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_alamanah_no text := new.raw_user_meta_data ->> 'alamanah_no';
  v_surname     text := new.raw_user_meta_data ->> 'surname';
  v_directory   member_directory%rowtype;
begin
  -- Admin accounts are created directly via the Supabase dashboard and
  -- carry no alamanah_no/surname metadata. Skip the member check for
  -- those and let the admin's profile row be inserted manually (see
  -- SETUP.md step 5) instead of failing the whole user creation.
  if v_alamanah_no is null or v_surname is null then
    return new;
  end if;

  select * into v_directory
  from member_directory
  where lower(alamanah_no) = lower(v_alamanah_no)
    and lower(surname) = lower(v_surname)
    and claimed = false
  limit 1;

  if not found then
    raise exception 'No unclaimed member record matches that Al-Amanah number and surname.';
  end if;

  insert into profiles (id, alamanah_no, surname, first_name, department, phone, contact_email,
                         savings_balance, monthly_savings_amount, joined)
  values (new.id, v_directory.alamanah_no, v_directory.surname, v_directory.first_name,
          v_directory.department, v_directory.phone, v_directory.contact_email,
          v_directory.savings_balance, v_directory.monthly_savings_amount, v_directory.joined);

  update member_directory set claimed = true where alamanah_no = v_directory.alamanah_no;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_member();

-- ---------------------------------------------------------
-- 6. Helper: is the currently logged-in user an admin?
--    (security definer avoids recursive RLS lookups)
-- ---------------------------------------------------------
create or replace function public.is_admin()
returns boolean
language sql
security definer
set search_path = public
as $$
  select coalesce((select is_admin from profiles where id = auth.uid()), false);
$$;

-- ---------------------------------------------------------
-- 7. ROW LEVEL SECURITY
-- ---------------------------------------------------------
alter table member_directory enable row level security;
alter table profiles enable row level security;
alter table loans enable row level security;
alter table transactions enable row level security;
alter table savings_adjustments enable row level security;
alter table admin_charge_adjustments enable row level security;

-- member_directory: only admins can browse it directly.
-- (The signup trigger itself runs as security definer, so
-- ordinary members never need direct access to this table.)
create policy "admins manage directory" on member_directory
  for all using (public.is_admin()) with check (public.is_admin());

-- profiles: a member can see/update their own row; admins see/update all.
create policy "self read profile" on profiles
  for select using (id = auth.uid() or public.is_admin());
create policy "self update profile" on profiles
  for update using (id = auth.uid() or public.is_admin());

-- loans: a member can see and create their own; only admins can update (approve/decline).
create policy "self read loans" on loans
  for select using (member_id = auth.uid() or public.is_admin());
create policy "self create loans" on loans
  for insert with check (member_id = auth.uid());
create policy "admin update loans" on loans
  for update using (public.is_admin());

-- transactions: a member can see their own; admins see all.
-- Inserts happen via the admin-only deduction/savings RPCs (below).
create policy "self read transactions" on transactions
  for select using (member_id = auth.uid() or public.is_admin());
create policy "admin insert transactions" on transactions
  for insert with check (public.is_admin());

-- savings_adjustments: a member can see their own adjustment
-- history; only admins can create an adjustment (via the
-- edit_member_savings RPC below).
create policy "self read adjustments" on savings_adjustments
  for select using (member_id = auth.uid() or public.is_admin());
create policy "admin insert adjustments" on savings_adjustments
  for insert with check (public.is_admin());

-- admin_charge_adjustments: a member can see their own adjustment
-- history; only admins can create an adjustment (via the
-- edit_total_admin_charges RPC below).
create policy "self read charge adjustments" on admin_charge_adjustments
  for select using (member_id = auth.uid() or public.is_admin());
create policy "admin insert charge adjustments" on admin_charge_adjustments
  for insert with check (public.is_admin());

-- ---------------------------------------------------------
-- 8. RPC: admin records a monthly loan deduction safely on the
--    server. Members can NEVER record their own deduction —
--    only an admin may call this. A loan repayment reduces the
--    outstanding loan balance (and admin-charge balance) ONLY;
--    it never touches the member's savings balance.
-- ---------------------------------------------------------
create or replace function public.admin_record_loan_deduction(p_loan_id text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_loan loans%rowtype;
  v_paused boolean;
  v_loan_cut numeric;
  v_admin_cut numeric;
  v_total numeric;
begin
  if not public.is_admin() then
    raise exception 'Only admins may record loan deductions.';
  end if;

  select * into v_loan from loans where id = p_loan_id;
  if not found or v_loan.status <> 'approved' then
    raise exception 'Loan not found or not active.';
  end if;

  select deductions_paused into v_paused from profiles where id = v_loan.member_id;
  if v_paused then
    raise exception 'Deductions are paused for this member.';
  end if;

  v_loan_cut  := least(v_loan.monthly_deduction, v_loan.balance);
  v_admin_cut := least(v_loan.admin_monthly_deduction, v_loan.admin_charge_balance);
  v_total     := v_loan_cut + v_admin_cut;

  update loans set
    balance = greatest(0, balance - v_loan_cut),
    admin_charge_balance = greatest(0, admin_charge_balance - v_admin_cut),
    months_paid = months_paid + 1,
    status = case when balance - v_loan_cut <= 0 and admin_charge_balance - v_admin_cut <= 0 then 'completed' else status end
  where id = p_loan_id;

  -- Savings balance is intentionally left untouched here — a
  -- loan repayment reduces the loan only.
  insert into transactions (member_id, description, amount, type)
  values (v_loan.member_id, 'Monthly loan deduction — ' || p_loan_id, -v_total, 'loan');
end;
$$;

-- ---------------------------------------------------------
-- 8b. RPC: admin processes loan deductions for MANY loans at
--     once — each loan uses its own stored monthly amount.
-- ---------------------------------------------------------
create or replace function public.record_loan_deductions_bulk(p_loan_ids text[])
returns table(loan_id text, processed boolean, message text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id text;
begin
  if not public.is_admin() then
    raise exception 'Only admins may process deductions.';
  end if;

  foreach v_id in array p_loan_ids loop
    begin
      perform public.admin_record_loan_deduction(v_id);
      loan_id := v_id; processed := true; message := 'OK';
    exception when others then
      loan_id := v_id; processed := false; message := sqlerrm;
    end;
    return next;
  end loop;
end;
$$;

-- Note: an earlier duplicate definition of decide_loan() used to
-- live here (a simpler admin-only version, superseded by the real
-- one further down in this file, "10. RPC: admin approves or
-- declines a loan safely"). Removed for clarity — Postgres was
-- always silently using the later definition anyway, so this
-- cleanup changes nothing about how the live database behaves.

-- ---------------------------------------------------------
-- 9b. Helper: the 5th of the month following a given date —
--     used to schedule the next savings contribution.
-- ---------------------------------------------------------
create or replace function public.fifth_of_next_month(p_from date default current_date)
returns date
language sql
immutable
as $$
  select (date_trunc('month', p_from) + interval '1 month' + interval '4 days')::date;
$$;

-- ---------------------------------------------------------
-- 10. RPC: admin records a member's monthly savings
--     contribution. The FULL amount is credited to savings —
--     the 7.5% administrative charge is a separate deduction
--     taken from the member's salary, tracked in its own
--     running total, and never subtracted from savings.
--     Also stamps last/next savings date + amount so the
--     schedule (due the 5th of next month) stays accurate.
-- ---------------------------------------------------------
create or replace function public.record_savings_contribution(p_member_id uuid, p_gross_amount numeric)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_charge numeric;
  v_paused boolean;
begin
  if not public.is_admin() then
    raise exception 'Only admins may record savings contributions.';
  end if;
  if p_gross_amount <= 0 then
    raise exception 'Contribution amount must be positive.';
  end if;

  select savings_paused into v_paused from profiles where id = p_member_id;
  if v_paused then
    raise exception 'Savings deductions are paused for this member.';
  end if;

  v_charge := round(p_gross_amount * 0.075);

  update profiles set
    savings_balance      = savings_balance + p_gross_amount,
    total_admin_charges  = total_admin_charges + v_charge,
    last_savings_date    = current_date,
    last_savings_amount  = p_gross_amount,
    next_savings_date    = public.fifth_of_next_month(current_date),
    next_savings_amount  = case when monthly_savings_amount > 0 then monthly_savings_amount else p_gross_amount end
  where id = p_member_id;

  insert into transactions (member_id, description, amount, type)
  values (p_member_id, 'Monthly savings contribution', p_gross_amount, 'savings');

  insert into transactions (member_id, description, amount, type)
  values (p_member_id, 'Administrative charge (7.5%) — deducted from salary, separate from savings', -v_charge, 'admin_charge');
end;
$$;

-- ---------------------------------------------------------
-- 10b. RPC: admin processes savings for MANY members at once,
--      each using their own stored monthly_savings_amount.
--      Members who are paused, inactive, or have no monthly
--      amount set are skipped (reported back, not errored).
-- ---------------------------------------------------------
create or replace function public.record_savings_bulk(p_member_ids uuid[])
returns table(member_id uuid, processed boolean, message text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_profile profiles%rowtype;
begin
  if not public.is_admin() then
    raise exception 'Only admins may process deductions.';
  end if;

  foreach v_id in array p_member_ids loop
    select * into v_profile from profiles where id = v_id;

    if not found then
      member_id := v_id; processed := false; message := 'Member not found.';
    elsif v_profile.savings_paused then
      member_id := v_id; processed := false; message := 'Savings paused.';
    elsif v_profile.status <> 'active' then
      member_id := v_id; processed := false; message := 'Member is not active.';
    elsif v_profile.monthly_savings_amount <= 0 then
      member_id := v_id; processed := false; message := 'No monthly savings amount set.';
    else
      perform public.record_savings_contribution(v_id, v_profile.monthly_savings_amount);
      member_id := v_id; processed := true; message := 'OK';
    end if;

    return next;
  end loop;
end;
$$;

-- ---------------------------------------------------------
-- 10c. RPC: admin sets a member's recurring monthly savings
--      amount (used by the bulk action above and shown to the
--      member as their next scheduled amount).
-- ---------------------------------------------------------
create or replace function public.set_monthly_savings_amount(p_member_id uuid, p_amount numeric)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Only admins may set a monthly savings amount.';
  end if;
  if p_amount < 0 then
    raise exception 'Amount cannot be negative.';
  end if;
  update profiles set
    monthly_savings_amount = p_amount,
    next_savings_amount = p_amount
  where id = p_member_id;
end;
$$;

-- ---------------------------------------------------------
-- 10d. RPC: pause / resume savings — individual and bulk
-- ---------------------------------------------------------
create or replace function public.set_savings_paused(p_member_id uuid, p_paused boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Only admins may pause or resume savings.';
  end if;
  update profiles set savings_paused = p_paused where id = p_member_id;
end;
$$;

create or replace function public.set_savings_paused_bulk(p_member_ids uuid[], p_paused boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Only admins may pause or resume savings.';
  end if;
  update profiles set savings_paused = p_paused where id = any(p_member_ids);
end;
$$;

-- ---------------------------------------------------------
-- 10e. RPC: pause / resume a member's loan deductions —
--      individual and bulk
-- ---------------------------------------------------------
create or replace function public.set_deductions_paused(p_member_id uuid, p_paused boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Only admins may pause or resume deductions.';
  end if;
  update profiles set deductions_paused = p_paused where id = p_member_id;
end;
$$;

create or replace function public.set_deductions_paused_bulk(p_member_ids uuid[], p_paused boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Only admins may pause or resume deductions.';
  end if;
  update profiles set deductions_paused = p_paused where id = any(p_member_ids);
end;
$$;

-- ---------------------------------------------------------
-- 10f. RPC: admin manually edits a member's savings balance,
--      with a required reason. Every change is logged to
--      savings_adjustments.
-- ---------------------------------------------------------
create or replace function public.edit_member_savings(p_member_id uuid, p_new_amount numeric, p_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_previous numeric;
begin
  if not public.is_admin() then
    raise exception 'Only admins may edit a member''s savings.';
  end if;
  if p_new_amount < 0 then
    raise exception 'Savings balance cannot be negative.';
  end if;
  if p_reason is null or trim(p_reason) = '' then
    raise exception 'A reason is required for a manual savings adjustment.';
  end if;

  select savings_balance into v_previous from profiles where id = p_member_id;
  if not found then
    raise exception 'Member not found.';
  end if;

  update profiles set savings_balance = p_new_amount where id = p_member_id;

  insert into savings_adjustments (member_id, previous_amount, new_amount, reason, adjusted_by)
  values (p_member_id, v_previous, p_new_amount, p_reason, auth.uid());

  insert into transactions (member_id, description, amount, type)
  values (p_member_id, 'Manual savings adjustment — ' || p_reason, p_new_amount - v_previous, 'savings');
end;
$$;

-- ---------------------------------------------------------
-- 10g. RPC: admin manually edits/corrects a member's total
--      admin charges (deducted from salary) figure, with a
--      required reason. Every change is logged to
--      admin_charge_adjustments. This does NOT touch savings
--      or loan balances.
-- ---------------------------------------------------------
create or replace function public.edit_total_admin_charges(p_member_id uuid, p_new_amount numeric, p_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_previous numeric;
begin
  if not public.is_admin() then
    raise exception 'Only admins may edit a member''s admin charges.';
  end if;
  if p_new_amount < 0 then
    raise exception 'Admin charges figure cannot be negative.';
  end if;
  if p_reason is null or trim(p_reason) = '' then
    raise exception 'A reason is required for an admin charges correction.';
  end if;

  select total_admin_charges into v_previous from profiles where id = p_member_id;
  if not found then
    raise exception 'Member not found.';
  end if;

  update profiles set total_admin_charges = p_new_amount where id = p_member_id;

  insert into admin_charge_adjustments (member_id, previous_amount, new_amount, reason, adjusted_by)
  values (p_member_id, v_previous, p_new_amount, p_reason, auth.uid());
end;
$$;

-- ---------------------------------------------------------
-- 11. RPC: admin marks a member's savings as reviewed today
--     (the twice-yearly review cycle: Jan-Jun and Jul-Dec)
-- ---------------------------------------------------------
create or replace function public.mark_savings_reviewed(p_member_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Only admins may record a savings review.';
  end if;
  update profiles set savings_last_reviewed = current_date where id = p_member_id;
end;
$$;

-- ---------------------------------------------------------
-- 11b. RPC: admin marks savings reviewed today for several
--      members at once (bulk version of the above).
-- ---------------------------------------------------------
create or replace function public.mark_savings_reviewed_bulk(p_member_ids uuid[])
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Only admins may record a savings review.';
  end if;
  update profiles set savings_last_reviewed = current_date where id = any(p_member_ids);
end;
$$;

-- =========================================================
-- 12. REALTIME: let the admin dashboard and member dashboard
--     hear about changes to loans/profiles instantly (new
--     applications, decisions, savings updates) instead of
--     only finding out on next page load.
-- =========================================================
do $$
begin
  begin
    alter publication supabase_realtime add table loans;
  exception when others then null;
  end;
  begin
    alter publication supabase_realtime add table profiles;
  exception when others then null;
  end;
end $$;

-- =========================================================
-- Done. Next: run seed_member_directory.sql to add your
-- real member list (or the demo rows for testing), then
-- create at least one admin account manually (see SETUP.md).
-- =========================================================

-- =========================================================
-- 13. FRESH-PROJECT LOAN CONTROLS AND LOAN LIFECYCLE
--    These statements are safe in this complete schema and
--    are intended to be run once on a brand-new project.
-- =========================================================

-- Extend the loan lifecycle with offset/closed.
alter table loans drop constraint if exists loans_status_check;
alter table loans add constraint loans_status_check
  check (status in ('pending','approved','declined','completed','offset'));

-- Prevent more than one pending or active loan of the same type
-- for the same member. Completed, declined and offset loans remain
-- in history and do not block a new application.
create unique index if not exists one_open_loan_per_type
  on loans (member_id, type)
  where status in ('pending','approved');

-- Approvals may happen only once and only from pending.
--
-- NOTE for anyone setting up a fresh copy of this project: this
-- schema.sql is the original starting point only. This function
-- has since been updated by later migrations (it now also accepts
-- the President as a caller, not just Super Admin — see
-- supabase/migration_loan_workflow_president_secretary.sql). Run
-- every file in supabase/migration_*.sql, in date order, after
-- this one, or the live database will be missing the role/
-- workflow system entirely.
create or replace function public.decide_loan(p_loan_id text, p_decision text, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_loan loans%rowtype;
  v_total numeric;
begin
  if not public.is_admin() then raise exception 'Only admins may decide loans.'; end if;
  select * into v_loan from loans where id = p_loan_id for update;
  if not found then raise exception 'Loan not found.'; end if;
  if v_loan.status <> 'pending' then
    raise exception 'This loan has already been processed and cannot be reviewed again.';
  end if;

  if p_decision = 'approved' then
    v_total := v_loan.amount + coalesce(v_loan.admin_charge, 0);
    update loans set
      status = 'approved',
      date_decision = current_date,
      balance = v_total,
      admin_charge_balance = 0,
      monthly_deduction = case when v_loan.duration > 0 then round(v_total / v_loan.duration) else v_total end,
      admin_monthly_deduction = 0
    where id = p_loan_id;

    insert into transactions (member_id, description, amount, type)
    values (v_loan.member_id,
      'Loan approved/disbursed — ' || p_loan_id || ' (total obligation includes applicable 10% commodity charge)',
      v_loan.amount, 'loan');
  elsif p_decision = 'declined' then
    update loans set status = 'declined', date_decision = current_date,
      decline_reason = coalesce(p_reason, 'Not specified.') where id = p_loan_id;
  else
    raise exception 'Invalid decision.';
  end if;
end;
$$;

-- A repayment reduces only the loan balance. Savings are never touched.
create or replace function public.admin_record_loan_deduction(p_loan_id text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_loan loans%rowtype;
  v_paused boolean;
  v_cut numeric;
begin
  if not public.is_admin() then raise exception 'Only admins may record loan deductions.'; end if;
  select * into v_loan from loans where id = p_loan_id for update;
  if not found or v_loan.status <> 'approved' then raise exception 'Loan not found or not active.'; end if;
  select deductions_paused into v_paused from profiles where id = v_loan.member_id;
  if v_paused then raise exception 'Deductions are paused for this member.'; end if;
  v_cut := least(coalesce(v_loan.monthly_deduction,0), coalesce(v_loan.balance,0));
  if v_cut <= 0 then raise exception 'No deductible loan balance remains.'; end if;
  update loans set
    balance = greatest(0, balance - v_cut),
    months_paid = months_paid + 1,
    status = case when balance - v_cut <= 0 then 'completed' else 'approved' end
  where id = p_loan_id;
  insert into transactions (member_id, description, amount, type)
  values (v_loan.member_id, 'Monthly loan deduction — ' || p_loan_id, -v_cut, 'loan');
end;
$$;

-- Offset closes an active loan and preserves it in history.
create or replace function public.offset_loan(p_loan_id text, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_loan loans%rowtype;
begin
  if not public.is_admin() then raise exception 'Only admins may offset loans.'; end if;
  select * into v_loan from loans where id = p_loan_id for update;
  if not found or v_loan.status <> 'approved' then raise exception 'Only an active loan can be offset.'; end if;
  update loans set status='offset', balance=0, admin_charge_balance=0, date_decision=current_date,
    decline_reason=coalesce(p_reason, 'Loan offset by administrator.') where id=p_loan_id;
  insert into transactions (member_id, description, amount, type)
  values (v_loan.member_id, 'Loan offset/closed — ' || p_loan_id || case when p_reason is null then '' else ': '||p_reason end, 0, 'loan');
end;
$$;

-- Reset restores an active loan to its original full obligation. It is admin-only and keeps the record.
create or replace function public.reset_loan(p_loan_id text, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_loan loans%rowtype; v_total numeric;
begin
  if not public.is_admin() then raise exception 'Only admins may reset loans.'; end if;
  select * into v_loan from loans where id=p_loan_id for update;
  if not found or v_loan.status not in ('approved','completed') then raise exception 'Only active or completed loans can be reset.'; end if;
  v_total := v_loan.amount + coalesce(v_loan.admin_charge,0);
  update loans set status='approved', balance=v_total, admin_charge_balance=0, months_paid=0,
    monthly_deduction=case when duration>0 then round(v_total/duration) else v_total end,
    admin_monthly_deduction=0 where id=p_loan_id;
  insert into transactions (member_id, description, amount, type)
  values (v_loan.member_id, 'Loan reset by administrator — ' || p_loan_id || case when p_reason is null then '' else ': '||p_reason end, 0, 'loan');
end;
$$;
