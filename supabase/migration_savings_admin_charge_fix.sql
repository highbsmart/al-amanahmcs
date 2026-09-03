-- =========================================================
-- MIGRATION: separate savings from administrative charges,
-- and enable realtime sync between the admin and member
-- dashboards.
-- Run this ONCE in Supabase SQL Editor on your EXISTING
-- live database (you already ran schema.sql before — do
-- NOT re-run the whole schema.sql, just this file).
--
-- What changes:
--  - Adds a new `total_admin_charges` running total to
--    profiles, tracked separately from savings_balance.
--  - Updates record_savings_contribution() so the FULL
--    monthly amount an admin enters goes into savings,
--    and the 7.5% charge is only added to the new
--    total_admin_charges column — it no longer reduces
--    savings_balance.
--  - Adds loans and profiles to the realtime publication,
--    so a member's new application appears on the admin
--    dashboard instantly, and an admin's decision (approved/
--    declined) appears on the member's dashboard instantly.
--
-- Any contributions already recorded under the old logic
-- are not retroactively corrected (that money is already
-- posted); this only fixes contributions recorded from now on.
-- =========================================================

alter table profiles
  add column if not exists total_admin_charges numeric not null default 0;

create or replace function public.record_savings_contribution(p_member_id uuid, p_gross_amount numeric)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_charge numeric;
begin
  if not public.is_admin() then
    raise exception 'Only admins may record savings contributions.';
  end if;
  if p_gross_amount <= 0 then
    raise exception 'Contribution amount must be positive.';
  end if;

  v_charge := round(p_gross_amount * 0.075);

  update profiles set
    savings_balance = savings_balance + p_gross_amount,
    total_admin_charges = total_admin_charges + v_charge
  where id = p_member_id;

  insert into transactions (member_id, description, amount, type)
  values (p_member_id, 'Monthly savings contribution', p_gross_amount, 'savings');

  insert into transactions (member_id, description, amount, type)
  values (p_member_id, 'Administrative charge (7.5%) — deducted from salary, separate from savings', -v_charge, 'admin_charge');
end;
$$;

-- Also enable realtime on loans/profiles, if not already on,
-- so the admin dashboard and member dashboard hear about
-- changes (new applications, decisions, savings updates)
-- instantly instead of only on next page load.
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
