-- =========================================================
-- MIGRATION: Fix the "Super Admin" role option being a dead end,
-- and make sure `profiles.role` actually exists
--
-- BUG 1 — profiles.role was never created by any shipped migration.
-- migration_role_management_ui.sql's admin_set_role() reads and
-- writes profiles.role as if it already existed. On a database built
-- from scratch using only the SQL files in this repo, every call to
-- admin_set_role (i.e. the whole "Management Team" role-assignment
-- UI) would fail with "column role does not exist". This adds the
-- column with `if not exists`, so it's safe whether or not you
-- already have it on your live database.
--
-- BUG 2 — choosing "Super Admin" from the "Change to" dropdown in
-- Management Team silently did nothing useful. admin_set_role() only
-- ever updated the `role` text column; every actual admin-access
-- check across the whole site (admin.html's login gate, the route
-- guard, is_admin()) checks the SEPARATE `is_admin` boolean column,
-- which admin_set_role() never touched. Someone "promoted" to
-- Super Admin this way would show the right badge in the table but
-- still be bounced straight back to the admin login screen forever.
-- This replaces admin_set_role() so the two stay in sync: granting
-- the super_admin role turns is_admin on, and moving someone OFF
-- super_admin turns it back off — with a safety check so you can
-- never demote yourself or remove the last remaining Super Admin
-- (which would lock everyone out of admin.html for good).
--
-- Run this ONCE in Supabase SQL Editor. Safe to re-run. REQUIRES
-- migration_activity_log_and_issues.sql already run (uses
-- log_activity()).
-- =========================================================

begin;

-- Bug 1: create the column if it's genuinely missing, without
-- disturbing it if it already exists (e.g. you added it manually
-- before this migration existed).
alter table profiles add column if not exists role text;
alter table profiles alter column role set default 'member';
update profiles set role = 'member' where role is null and coalesce(is_admin, false) = false;
update profiles set role = 'super_admin' where coalesce(is_admin, false) = true and (role is null or role = 'member');
alter table profiles alter column role set not null;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'profiles_role_check'
  ) then
    alter table profiles add constraint profiles_role_check
      check (role in ('member','treasurer','president','secretary','super_admin'));
  end if;
end $$;

-- Bug 2: keep is_admin in sync with role from now on.
create or replace function public.admin_set_role(p_profile_id uuid, p_role text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old_role text;
  v_other_admins int;
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

  -- Don't allow the last Super Admin to be moved off the role — that
  -- would lock everyone out of admin.html with no way back in short
  -- of manual SQL. Also don't allow demoting yourself, even if
  -- another Super Admin exists, to avoid an accidental self-lockout
  -- mid-session.
  if v_old_role = 'super_admin' and p_role <> 'super_admin' then
    if p_profile_id = auth.uid() then
      raise exception 'You cannot remove your own Super Admin access. Ask another Super Admin to do this for you.';
    end if;
    select count(*) into v_other_admins from profiles where role = 'super_admin' and id <> p_profile_id;
    if v_other_admins = 0 then
      raise exception 'Cannot remove the last Super Admin — promote someone else first.';
    end if;
  end if;

  update profiles set role = p_role, is_admin = (p_role = 'super_admin') where id = p_profile_id;

  perform public.log_activity('role_changed', 'profile', p_profile_id::text, p_profile_id, v_old_role, p_role, null);
end;
$$;

commit;
