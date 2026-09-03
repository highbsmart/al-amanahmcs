-- =========================================================
-- AL-AMANAH MCS — Role management UI (backend half)
-- Adds one function so the Super Admin can change anyone's role
-- from inside admin.html, instead of needing manual SQL.
--
-- REQUIRES step 12's migration (migration_activity_log_and_issues.sql)
-- already run — this uses log_activity().
--
-- Run this once in Supabase: SQL Editor -> New query -> paste ->
-- Run. Safe to re-run.
-- =========================================================

begin;

create or replace function public.admin_set_role(p_profile_id uuid, p_role text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old_role text;
begin
  if not public.is_admin() then
    raise exception 'Only a Super Admin may change roles.';
  end if;

  if p_role not in ('member','treasurer','president','secretary','super_admin') then
    raise exception 'Invalid role.';
  end if;

  select role into v_old_role from profiles where id = p_profile_id;
  if not found then raise exception 'Profile not found.'; end if;

  if v_old_role = p_role then
    return; -- no-op, nothing to change or log
  end if;

  update profiles set role = p_role where id = p_profile_id;

  perform public.log_activity('role_changed', 'profile', p_profile_id::text, p_profile_id, v_old_role, p_role, null);
end;
$$;

commit;
