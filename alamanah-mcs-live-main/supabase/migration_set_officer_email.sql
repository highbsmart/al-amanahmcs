-- =========================================================
-- MIGRATION: Super Admin can set/change an account's sign-in email
--
-- WHY THIS EXISTS
-- Officer accounts (treasurer/president/secretary/super_admin) sign
-- in with a real email address, while ordinary members sign in with
-- their Al-Amanah No. (which maps to a generated placeholder email
-- behind the scenes — see SETUP.md step 3). When an EXISTING member
-- is promoted to an officer role, their account already has that
-- generated placeholder email (e.g. al0234@members.alamanahmcs.local)
-- as its real Supabase Auth sign-in email — which they don't know
-- and can't type into the officer login screen.
--
-- This adds admin_set_profile_email(), letting a Super Admin give
-- that SAME profile (same Al-Amanah No., same savings, same loans)
-- a real email to sign in with — instead of the old workaround of
-- creating a brand-new profile row with a placeholder Al-Amanah No.
-- like "TREAS-001", which orphaned the officer's real membership
-- record. See ADMIN-GUIDE-officer-accounts.md for the full
-- promote-an-existing-member workflow this enables.
--
-- Run this ONCE in Supabase SQL Editor. Safe to re-run.
-- REQUIRES migration_activity_log_and_issues.sql already run
-- (uses log_activity()).
-- =========================================================

begin;

create or replace function public.admin_set_profile_email(p_profile_id uuid, p_new_email text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old_email text;
  v_clean_email text := lower(trim(p_new_email));
  v_conflict int;
begin
  if not public.is_admin() then
    raise exception 'Only a Super Admin may change an account''s sign-in email.';
  end if;

  if v_clean_email is null or v_clean_email = '' or v_clean_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'Enter a valid email address.';
  end if;

  if not exists (select 1 from profiles where id = p_profile_id) then
    raise exception 'Member profile not found.';
  end if;

  select count(*) into v_conflict from auth.users where lower(email) = v_clean_email and id <> p_profile_id;
  if v_conflict > 0 then
    raise exception 'That email is already in use by another account.';
  end if;

  select email into v_old_email from auth.users where id = p_profile_id;
  if v_old_email is null then
    raise exception 'No matching Supabase Auth account for this profile.';
  end if;

  update auth.users
  set email = v_clean_email,
      email_confirmed_at = coalesce(email_confirmed_at, now())
  where id = p_profile_id;

  update profiles set contact_email = v_clean_email where id = p_profile_id;

  perform public.log_activity('officer_email_changed', 'profile', p_profile_id::text, p_profile_id, v_old_email, v_clean_email, null);
end;
$$;

commit;
