-- =========================================================
-- FIX: set_monthly_savings_amount() was incorrectly stamping
-- BOTH last_savings_date and next_savings_date to today's date
-- every time an admin set/updated a member's recurring monthly
-- savings amount — even though setting that amount is not the
-- same event as an actual contribution happening.
--
-- This made "Last month savings" and "Next month savings" show
-- the exact same date on the member's dashboard (both stamped to
-- whatever day an admin last touched the monthly amount), instead
-- of "Next month savings" correctly showing the 5th of the
-- following month.
--
-- This file:
--   1. Fixes the function so it only ever updates the AMOUNT
--      going forward — it no longer touches any date fields at
--      all. Dates are only ever set by an actual contribution
--      (record_savings_contribution, or the automatic monthly
--      job), which is the only place they should come from.
--   2. Repairs every member record already corrupted by the bug
--      (identified as: next_savings_date equal to
--      last_savings_date — a state that could only exist because
--      of this bug, since a genuine contribution always sets
--      next_savings_date to the 5th of the FOLLOWING month, which
--      can never equal the contribution date itself).
--
-- Run ONCE in Supabase SQL Editor. Safe to re-run.
-- =========================================================

begin;

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

  -- Only the recurring amount changes here. last_savings_date,
  -- last_savings_amount, and next_savings_date are left untouched
  -- — they only ever get set by an actual contribution event.
  update public.profiles set
    monthly_savings_amount = p_amount,
    next_savings_amount = p_amount
  where id = p_member_id;
end;
$$;

-- Repair every member record corrupted by the old buggy version
-- of this function.
update profiles
set next_savings_date = public.fifth_of_next_month(last_savings_date)
where last_savings_date is not null
  and next_savings_date = last_savings_date;

commit;
