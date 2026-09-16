-- =========================================================
-- Migration: editable "Total admin charges" figure
-- Run once (after schema.sql / migration_admin_deduction_controls.sql)
-- if you already have a live project. Safe to run more than once.
-- =========================================================

create table if not exists admin_charge_adjustments (
  id              uuid primary key default gen_random_uuid(),
  member_id       uuid not null references profiles(id) on delete cascade,
  previous_amount numeric not null,
  new_amount      numeric not null,
  reason          text not null,
  adjusted_by     uuid not null references profiles(id),
  created_at      timestamptz not null default now()
);

alter table admin_charge_adjustments enable row level security;

drop policy if exists "self read charge adjustments" on admin_charge_adjustments;
create policy "self read charge adjustments" on admin_charge_adjustments
  for select using (member_id = auth.uid() or public.is_admin());

drop policy if exists "admin insert charge adjustments" on admin_charge_adjustments;
create policy "admin insert charge adjustments" on admin_charge_adjustments
  for insert with check (public.is_admin());

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

-- Done. Redeploy the updated site files (dashboard/admin HTML+JS) alongside this.
