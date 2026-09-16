-- =========================================================
-- MIGRATION: Admin-editable payslips
-- Run this once in Supabase: Dashboard -> SQL Editor -> New
-- query -> paste -> Run. Safe to run on the existing live
-- database — it only adds a new table + two new functions,
-- it does not touch any existing table or data.
--
-- Why this exists: the member payslip used to be 100%
-- calculated on the fly from raw transactions, so if a
-- transaction was recorded with the wrong description/date,
-- or an amount needed a one-off correction, there was no way
-- to fix what the member saw without editing the underlying
-- ledger. This adds an optional per-member/per-month override
-- that the admin can set from the admin panel; when one
-- exists for a given month, the member's payslip shows the
-- admin's figures instead of the computed ones.
-- =========================================================

create table if not exists payslip_overrides (
  id                    uuid primary key default gen_random_uuid(),
  member_id             uuid not null references profiles(id) on delete cascade,
  month                 text not null check (month ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'), -- 'YYYY-MM'
  savings_contribution  numeric not null default 0,
  admin_charge          numeric not null default 0,
  loan_rows             jsonb not null default '[]'::jsonb, -- [{ "label": "Real Loan (LN-1234)", "amount": 5000 }, ...]
  note                  text,
  updated_by            uuid references profiles(id),
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  unique (member_id, month)
);

alter table payslip_overrides enable row level security;

drop policy if exists "self read own payslip override" on payslip_overrides;
create policy "self read own payslip override" on payslip_overrides
  for select using (member_id = auth.uid() or public.is_admin());

drop policy if exists "admin insert payslip overrides" on payslip_overrides;
create policy "admin insert payslip overrides" on payslip_overrides
  for insert with check (public.is_admin());

drop policy if exists "admin update payslip overrides" on payslip_overrides;
create policy "admin update payslip overrides" on payslip_overrides
  for update using (public.is_admin()) with check (public.is_admin());

drop policy if exists "admin delete payslip overrides" on payslip_overrides;
create policy "admin delete payslip overrides" on payslip_overrides
  for delete using (public.is_admin());

-- ---------------------------------------------------------
-- RPC: admin creates/updates the payslip override for one
--      member + one month. Re-running with the same member +
--      month updates the existing override (upsert).
-- ---------------------------------------------------------
create or replace function public.admin_save_payslip_override(
  p_member_id uuid,
  p_month text,
  p_savings numeric,
  p_admin_charge numeric,
  p_loan_rows jsonb,
  p_note text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Only admins may edit a payslip.';
  end if;
  if p_month is null or p_month !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then
    raise exception 'Month must be in YYYY-MM format.';
  end if;
  if p_savings < 0 or p_admin_charge < 0 then
    raise exception 'Amounts cannot be negative.';
  end if;
  if not exists (select 1 from profiles where id = p_member_id) then
    raise exception 'Member not found.';
  end if;

  insert into payslip_overrides
    (member_id, month, savings_contribution, admin_charge, loan_rows, note, updated_by, updated_at)
  values
    (p_member_id, p_month, p_savings, p_admin_charge, coalesce(p_loan_rows, '[]'::jsonb), nullif(trim(p_note), ''), auth.uid(), now())
  on conflict (member_id, month) do update set
    savings_contribution = excluded.savings_contribution,
    admin_charge          = excluded.admin_charge,
    loan_rows              = excluded.loan_rows,
    note                    = excluded.note,
    updated_by              = excluded.updated_by,
    updated_at              = now();
end;
$$;

-- ---------------------------------------------------------
-- RPC: admin removes an override so the member's payslip goes
--      back to being calculated live from transactions.
-- ---------------------------------------------------------
create or replace function public.admin_delete_payslip_override(p_member_id uuid, p_month text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Only admins may edit a payslip.';
  end if;
  delete from payslip_overrides where member_id = p_member_id and month = p_month;
end;
$$;
