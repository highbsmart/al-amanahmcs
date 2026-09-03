-- =========================================================
-- MIGRATION: admin-only deduction controls
-- Run this ONCE in Supabase SQL Editor on your EXISTING live
-- database, after schema.sql and migration_savings_admin_charge_fix.sql
-- have already been run. Safe to re-run (uses IF NOT EXISTS /
-- CREATE OR REPLACE / DROP+CREATE throughout).
--
-- What this fixes / adds:
--  1. Monthly deductions (both savings and loan repayments) can
--     now ONLY be recorded by an admin. The old member-facing
--     record_loan_deduction() RPC is removed; members can no
--     longer touch their own balance.
--  2. Admins can process a single member or many members at once
--     ("Process Monthly Deductions" bulk actions), each using
--     that member's own assigned amount.
--  3. Loan repayments now ONLY reduce the outstanding loan
--     balance (and admin-charge balance) — they never reduce
--     savings. Savings only ever grows via a savings
--     contribution.
--  4. Members get a stored monthly_savings_amount, plus
--     last/next savings date + amount, so "next contribution due
--     5th of next month" is tracked automatically.
--  5. Admins can pause/resume savings and pause/resume loan
--     deductions, per member or in bulk for everyone.
--  6. Admins can manually edit a member's savings balance, with
--     a required reason — every change is logged to a new
--     savings_adjustments audit table.
-- =========================================================

-- ---------------------------------------------------------
-- 1. New columns on profiles
-- ---------------------------------------------------------
alter table profiles
  add column if not exists monthly_savings_amount numeric not null default 0,
  add column if not exists savings_paused boolean not null default false,
  add column if not exists deductions_paused boolean not null default false,
  add column if not exists last_savings_date date,
  add column if not exists last_savings_amount numeric not null default 0,
  add column if not exists next_savings_date date,
  add column if not exists next_savings_amount numeric not null default 0;

-- ---------------------------------------------------------
-- 2. Savings adjustment audit trail
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

alter table savings_adjustments enable row level security;

drop policy if exists "self read adjustments" on savings_adjustments;
create policy "self read adjustments" on savings_adjustments
  for select using (member_id = auth.uid() or public.is_admin());

drop policy if exists "admin insert adjustments" on savings_adjustments;
create policy "admin insert adjustments" on savings_adjustments
  for insert with check (public.is_admin());

-- ---------------------------------------------------------
-- 3. Helper: the 5th of the month following a given date
-- ---------------------------------------------------------
create or replace function public.fifth_of_next_month(p_from date default current_date)
returns date
language sql
immutable
as $$
  select (date_trunc('month', p_from) + interval '1 month' + interval '4 days')::date;
$$;

-- ---------------------------------------------------------
-- 4. RPC: admin records ONE member's monthly savings
--    contribution (replaces the old version — adds the
--    paused check and the last/next tracking fields).
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
-- 5. RPC: admin processes savings for MANY members at once,
--    each using their own stored monthly_savings_amount.
--    Members who are paused, inactive, or have no monthly
--    amount set are skipped (reported back, not errored).
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
-- 6. RPC: admin records ONE loan's monthly deduction.
--    Reduces the loan balance / admin-charge balance ONLY —
--    never touches profiles.savings_balance.
--    Replaces the old member-facing record_loan_deduction().
-- ---------------------------------------------------------
drop function if exists public.record_loan_deduction(text);

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

  -- Savings balance is intentionally left untouched: a loan
  -- repayment reduces the loan only.
  insert into transactions (member_id, description, amount, type)
  values (v_loan.member_id, 'Monthly loan deduction — ' || p_loan_id, -v_total, 'loan');
end;
$$;

-- ---------------------------------------------------------
-- 7. RPC: admin processes loan deductions for MANY loans at
--    once. Each loan uses its own monthly_deduction amount.
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

-- ---------------------------------------------------------
-- 8. RPC: admin sets a member's recurring monthly savings
--    amount (used by the bulk "Process Monthly Deductions"
--    action and shown to the member as their next amount).
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
-- 9. RPC: pause / resume savings — individual and bulk
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
-- 10. RPC: pause / resume a member's (loan) deductions —
--     individual and bulk
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
-- 11. RPC: admin manually edits a member's savings balance,
--     with a required reason. Every change is logged.
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

-- =========================================================
-- Done. Existing members will show monthly_savings_amount = 0
-- until an admin sets one (Members tab -> "Set monthly amount")
-- — until then, the bulk "Process Savings" action will skip
-- them and report why.
-- =========================================================
