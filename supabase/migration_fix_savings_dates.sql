-- =========================================================
-- Migration: bulk "mark savings review" + fix blank
-- last/next savings date fields on the member dashboard.
-- Run once in Supabase SQL Editor. Safe to run more than once.
-- =========================================================

-- 1. Bulk review RPC (used by the new "Mark Savings Review
--    (Selected)" button in the admin Members tab).
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

-- 2. Backfill: if a member already has savings contributions
--    recorded in transactions but their profile's
--    last_savings_date/last_savings_amount were never set
--    (e.g. contributions recorded before this feature existed,
--    or before this fix), fill them in from their most recent
--    savings transaction.
update profiles p
set last_savings_date   = t.date,
    last_savings_amount = t.amount
from (
  select distinct on (member_id) member_id, date, amount
  from transactions
  where type = 'savings'
  order by member_id, date desc, created_at desc
) t
where p.id = t.member_id
  and p.last_savings_date is null;

-- 3. Backfill next_savings_date/next_savings_amount from the
--    now-known last_savings_date, so "Next month savings"
--    also stops showing blank for these members.
update profiles
set next_savings_date   = public.fifth_of_next_month(last_savings_date),
    next_savings_amount = case when monthly_savings_amount > 0 then monthly_savings_amount else last_savings_amount end
where last_savings_date is not null
  and next_savings_date is null;

-- Done. New contributions recorded from now on (via "Record
-- savings" or "Process Monthly Savings for Selected") already
-- set these fields correctly going forward.
