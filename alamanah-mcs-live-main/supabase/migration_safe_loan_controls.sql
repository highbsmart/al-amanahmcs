-- =========================================================
-- SAFE MIGRATION: Loan controls and commodity-loan correction
-- Run this file ONLY on an existing Supabase database.
-- It does not recreate existing tables or RLS policies.
-- Safe to run more than once.
-- =========================================================

begin;

-- 1. Support the "offset" loan status.
alter table public.loans drop constraint if exists loans_status_check;
alter table public.loans
  add constraint loans_status_check
  check (status in ('pending','approved','declined','completed','offset'));

-- 2. Optional audit fields for loan offsets.
alter table public.loans
  add column if not exists offset_reason text,
  add column if not exists offset_at timestamptz,
  add column if not exists offset_by uuid references public.profiles(id);

-- 3. The Commodity Loan charge is 10% of the amount collected.
-- Correct pending applications only. Existing approved/completed loans
-- are left untouched to preserve already-recorded financial history.
update public.loans
set admin_charge = round(amount * 0.10),
    admin_monthly_deduction = round((amount * 0.10) / greatest(duration, 1))
where type = 'commodity'
  and status = 'pending';

-- 4. Prevent a member from having two open loans of the same type.
-- This trigger is safer than a unique index because it gives a clear
-- error message and does not fail the migration if old duplicate data exists.
create or replace function public.prevent_duplicate_open_loan()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.status in ('pending','approved') and exists (
    select 1
    from public.loans l
    where l.member_id = new.member_id
      and l.type = new.type
      and l.status in ('pending','approved')
      and l.id <> new.id
  ) then
    raise exception 'A pending or active loan of this type already exists for this member.';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_prevent_duplicate_open_loan on public.loans;
create trigger trg_prevent_duplicate_open_loan
before insert or update of member_id, type, status on public.loans
for each row execute function public.prevent_duplicate_open_loan();

-- 5. Approve/decline only a pending loan once.
-- On approval, the TOTAL LOAN OBLIGATION is:
-- loan amount + 10% commodity charge (commodity loans only).
create or replace function public.decide_loan(
  p_loan_id text,
  p_decision text,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_loan public.loans%rowtype;
  v_charge numeric;
  v_total numeric;
begin
  if not public.is_admin() then
    raise exception 'Only admins may decide loans.';
  end if;

  select * into v_loan
  from public.loans
  where id = p_loan_id
  for update;

  if not found then
    raise exception 'Loan not found.';
  end if;

  if v_loan.status <> 'pending' then
    raise exception 'This loan has already been processed and cannot be reviewed or approved again.';
  end if;

  if p_decision = 'approved' then
    v_charge := case
      when v_loan.type = 'commodity' then round(v_loan.amount * 0.10)
      else coalesce(v_loan.admin_charge, 0)
    end;
    v_total := v_loan.amount + v_charge;

    update public.loans
    set status = 'approved',
        date_decision = current_date,
        admin_charge = v_charge,
        balance = v_total,
        admin_charge_balance = 0,
        monthly_deduction = round(v_total / greatest(duration, 1)),
        admin_monthly_deduction = 0
    where id = p_loan_id;

  elsif p_decision = 'declined' then
    update public.loans
    set status = 'declined',
        date_decision = current_date,
        decline_reason = coalesce(nullif(trim(p_reason), ''), 'Not specified.')
    where id = p_loan_id;
  else
    raise exception 'Invalid decision. Use approved or declined.';
  end if;
end;
$$;

-- 6. Offset an active loan. The original loan record remains for history.
create or replace function public.offset_loan(
  p_loan_id text,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_loan public.loans%rowtype;
begin
  if not public.is_admin() then
    raise exception 'Only admins may offset loans.';
  end if;

  select * into v_loan
  from public.loans
  where id = p_loan_id
  for update;

  if not found then
    raise exception 'Loan not found.';
  end if;

  if v_loan.status <> 'approved' then
    raise exception 'Only an active approved loan can be offset.';
  end if;

  update public.loans
  set status = 'offset',
      balance = 0,
      admin_charge_balance = 0,
      offset_reason = coalesce(nullif(trim(p_reason), ''), 'Loan offset by administrator.'),
      offset_at = now(),
      offset_by = auth.uid()
  where id = p_loan_id;
end;
$$;

-- 7. A controlled reset option. This does NOT delete history.
-- It can only reset an approved active loan back to its original obligation.
create or replace function public.reset_active_loan(
  p_loan_id text,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_loan public.loans%rowtype;
  v_total numeric;
begin
  if not public.is_admin() then
    raise exception 'Only admins may reset an active loan.';
  end if;

  select * into v_loan
  from public.loans
  where id = p_loan_id
  for update;

  if not found then
    raise exception 'Loan not found.';
  end if;

  if v_loan.status <> 'approved' then
    raise exception 'Only an active approved loan can be reset.';
  end if;

  v_total := v_loan.amount + coalesce(v_loan.admin_charge, 0);

  update public.loans
  set balance = v_total,
      admin_charge_balance = 0,
      monthly_deduction = round(v_total / greatest(duration, 1)),
      admin_monthly_deduction = 0,
      months_paid = 0,
      decline_reason = coalesce(nullif(trim(p_reason), ''), decline_reason)
  where id = p_loan_id;
end;
$$;

commit;

-- After running this migration successfully, refresh the Supabase schema cache
-- or wait briefly before testing the RPC functions from the application.
