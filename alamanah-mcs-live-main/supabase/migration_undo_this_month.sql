-- =========================================================
-- AL-AMANAH MCS — "Undo This Month" for savings and loan
-- deductions.
--
-- Lets an admin fully reverse a member's most recent savings
-- contribution, or a loan's most recent monthly deduction — but
-- ONLY if it happened in the CURRENT calendar month (this is not
-- a general-purpose "delete a transaction" tool; it's specifically
-- for "this member changed their mind about this month"). After
-- undoing, the member/loan becomes eligible again to be processed
-- for that same month — by the admin manually, or by the next
-- automatic run.
--
-- Nothing is ever deleted from the transactions ledger — every
-- undo is recorded as a clearly-labelled REVERSAL entry, so the
-- full history (original + reversal) always stays visible. Every
-- undo also requires a typed reason and is logged to a new
-- undo_log table for audit.
--
-- REQUIRES: migration_admin_deduction_controls.sql and
-- migration_auto_monthly_processing.sql to already be in place.
--
-- Run ONCE in Supabase SQL Editor. Safe to re-run.
-- =========================================================

begin;

-- ---------------------------------------------------------
-- 1. Track exactly what a loan's most recent deduction actually
--    took (split between principal and admin-charge portions),
--    so an undo can reverse it precisely rather than guessing.
-- ---------------------------------------------------------
alter table loans
  add column if not exists last_deduction_loan_cut  numeric,
  add column if not exists last_deduction_admin_cut numeric;

-- Re-declares admin_record_loan_deduction() with the addition of
-- recording that breakdown — everything else is unchanged.
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
    last_deduction_date = current_date,
    last_deduction_loan_cut = v_loan_cut,
    last_deduction_admin_cut = v_admin_cut,
    status = case when balance - v_loan_cut <= 0 and admin_charge_balance - v_admin_cut <= 0 then 'completed' else status end
  where id = p_loan_id;
  -- Savings balance is intentionally left untouched: a loan
  -- repayment reduces the loan only.
  insert into transactions (member_id, description, amount, type)
  values (v_loan.member_id, 'Monthly loan deduction — ' || p_loan_id, -v_total, 'loan');
end;
$$;

-- Same addition inside the automatic job's own inline copy of
-- this logic (it can't call the function above directly — see
-- migration_auto_monthly_processing.sql for why).
create or replace function public.run_monthly_auto_processing()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_today date := current_date;
  v_month_start date := date_trunc('month', v_today)::date;
  v_member record;
  v_loan record;
  v_paused boolean;
  v_charge numeric;
  v_loan_cut numeric;
  v_admin_cut numeric;
  v_total numeric;
  v_savings_processed int := 0;
  v_savings_skipped jsonb := '[]'::jsonb;
  v_loans_processed int := 0;
  v_loans_skipped jsonb := '[]'::jsonb;
begin
  if v_today < (v_month_start + 4) then
    return;
  end if;

  for v_member in
    select * from profiles
    where status = 'active'
      and (last_savings_date is null or last_savings_date < v_month_start)
  loop
    if v_member.savings_paused then
      v_savings_skipped := v_savings_skipped || jsonb_build_object('member_id', v_member.id, 'reason', 'Savings paused.');
    elsif v_member.monthly_savings_amount <= 0 then
      v_savings_skipped := v_savings_skipped || jsonb_build_object('member_id', v_member.id, 'reason', 'No monthly savings amount set.');
    else
      v_charge := round(v_member.monthly_savings_amount * 0.075);
      update profiles set
        savings_balance      = savings_balance + v_member.monthly_savings_amount,
        total_admin_charges  = total_admin_charges + v_charge,
        last_savings_date    = current_date,
        last_savings_amount  = v_member.monthly_savings_amount,
        next_savings_date    = public.fifth_of_next_month(current_date),
        next_savings_amount  = v_member.monthly_savings_amount
      where id = v_member.id;

      insert into transactions (member_id, description, amount, type)
      values (v_member.id, 'Monthly savings contribution (automatic)', v_member.monthly_savings_amount, 'savings');
      insert into transactions (member_id, description, amount, type)
      values (v_member.id, 'Administrative charge (7.5%) — deducted from salary, separate from savings (automatic)', -v_charge, 'admin_charge');

      v_savings_processed := v_savings_processed + 1;
    end if;
  end loop;

  for v_loan in
    select * from loans
    where status = 'approved'
      and (last_deduction_date is null or last_deduction_date < v_month_start)
  loop
    select deductions_paused into v_paused from profiles where id = v_loan.member_id;
    if v_paused then
      v_loans_skipped := v_loans_skipped || jsonb_build_object('loan_id', v_loan.id, 'reason', 'Deductions paused for this member.');
      continue;
    end if;

    v_loan_cut  := least(v_loan.monthly_deduction, v_loan.balance);
    v_admin_cut := least(v_loan.admin_monthly_deduction, v_loan.admin_charge_balance);
    v_total     := v_loan_cut + v_admin_cut;

    update loans set
      balance = greatest(0, balance - v_loan_cut),
      admin_charge_balance = greatest(0, admin_charge_balance - v_admin_cut),
      months_paid = months_paid + 1,
      last_deduction_date = current_date,
      last_deduction_loan_cut = v_loan_cut,
      last_deduction_admin_cut = v_admin_cut,
      status = case when balance - v_loan_cut <= 0 and admin_charge_balance - v_admin_cut <= 0 then 'completed' else status end
    where id = v_loan.id;

    insert into transactions (member_id, description, amount, type)
    values (v_loan.member_id, 'Monthly loan deduction (automatic) — ' || v_loan.id, -v_total, 'loan');

    v_loans_processed := v_loans_processed + 1;
  end loop;

  insert into auto_processing_runs (run_date, savings_processed, savings_skipped, loans_processed, loans_skipped)
  values (v_today, v_savings_processed, v_savings_skipped, v_loans_processed, v_loans_skipped);
end;
$$;

revoke execute on function public.run_monthly_auto_processing() from public, anon, authenticated;

-- ---------------------------------------------------------
-- 2. Audit log for every undo, whichever kind.
-- ---------------------------------------------------------
create table if not exists undo_log (
  id             uuid primary key default gen_random_uuid(),
  entity_type    text not null check (entity_type in ('savings','loan_deduction')),
  entity_id      text not null,          -- member id (savings) or loan id (loan_deduction)
  member_id      uuid not null references profiles(id),
  amount_reversed numeric not null,
  reason         text not null,
  undone_by      uuid not null references profiles(id),
  created_at     timestamptz not null default now()
);

alter table undo_log enable row level security;

drop policy if exists "admin read undo log" on undo_log;
create policy "admin read undo log" on undo_log
  for select using (public.is_admin());

drop policy if exists "admin insert undo log" on undo_log;
create policy "admin insert undo log" on undo_log
  for insert with check (public.is_admin());

-- ---------------------------------------------------------
-- 3. Undo a member's savings contribution for the CURRENT month
--    only. Reverses the balance, the admin charge, and inserts
--    matching reversal transactions — then clears
--    last_savings_date so the member becomes eligible to be
--    processed again this same month.
-- ---------------------------------------------------------
create or replace function public.admin_undo_savings_contribution(p_member_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile profiles%rowtype;
  v_month_start date := date_trunc('month', current_date)::date;
  v_charge numeric;
begin
  if not public.is_admin() then
    raise exception 'Only admins may undo a savings contribution.';
  end if;
  if coalesce(trim(p_reason), '') = '' then
    raise exception 'A reason is required to undo a contribution.';
  end if;

  select * into v_profile from profiles where id = p_member_id;
  if not found then raise exception 'Member not found.'; end if;

  if v_profile.last_savings_date is null or v_profile.last_savings_date < v_month_start then
    raise exception 'This member has no savings contribution recorded this month to undo.';
  end if;

  v_charge := round(v_profile.last_savings_amount * 0.075);

  update profiles set
    savings_balance     = greatest(0, savings_balance - v_profile.last_savings_amount),
    total_admin_charges = greatest(0, total_admin_charges - v_charge),
    last_savings_date   = null,
    last_savings_amount = 0
  where id = p_member_id;

  insert into transactions (member_id, description, amount, type)
  values (p_member_id, 'Reversal of this month''s savings contribution — ' || p_reason, -v_profile.last_savings_amount, 'savings');
  insert into transactions (member_id, description, amount, type)
  values (p_member_id, 'Reversal of this month''s administrative charge — ' || p_reason, v_charge, 'admin_charge');

  insert into undo_log (entity_type, entity_id, member_id, amount_reversed, reason, undone_by)
  values ('savings', p_member_id::text, p_member_id, v_profile.last_savings_amount, p_reason, auth.uid());
end;
$$;

-- ---------------------------------------------------------
-- 4. Undo a loan's monthly deduction for the CURRENT month
--    only. Reverses the loan balance and admin-charge balance by
--    exactly what was last taken, un-does a 'completed' status if
--    this deduction was what completed it, and clears
--    last_deduction_date so the loan becomes eligible again this
--    same month.
-- ---------------------------------------------------------
create or replace function public.admin_undo_loan_deduction(p_loan_id text, p_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_loan loans%rowtype;
  v_month_start date := date_trunc('month', current_date)::date;
  v_total numeric;
begin
  if not public.is_admin() then
    raise exception 'Only admins may undo a loan deduction.';
  end if;
  if coalesce(trim(p_reason), '') = '' then
    raise exception 'A reason is required to undo a deduction.';
  end if;

  select * into v_loan from loans where id = p_loan_id;
  if not found then raise exception 'Loan not found.'; end if;

  if v_loan.last_deduction_date is null or v_loan.last_deduction_date < v_month_start then
    raise exception 'This loan has no deduction recorded this month to undo.';
  end if;

  v_total := coalesce(v_loan.last_deduction_loan_cut, 0) + coalesce(v_loan.last_deduction_admin_cut, 0);

  update loans set
    balance = balance + coalesce(last_deduction_loan_cut, 0),
    admin_charge_balance = admin_charge_balance + coalesce(last_deduction_admin_cut, 0),
    months_paid = greatest(0, months_paid - 1),
    last_deduction_date = null,
    last_deduction_loan_cut = null,
    last_deduction_admin_cut = null,
    status = case when status = 'completed' then 'approved' else status end
  where id = p_loan_id;

  insert into transactions (member_id, description, amount, type)
  values (v_loan.member_id, 'Reversal of this month''s loan deduction — ' || p_loan_id || ' — ' || p_reason, v_total, 'loan');

  insert into undo_log (entity_type, entity_id, member_id, amount_reversed, reason, undone_by)
  values ('loan_deduction', p_loan_id, v_loan.member_id, v_total, p_reason, auth.uid());
end;
$$;

commit;
