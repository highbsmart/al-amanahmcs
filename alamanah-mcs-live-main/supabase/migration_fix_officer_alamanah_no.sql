-- =========================================================
-- MIGRATION: Fix officer accounts carrying a placeholder
-- Al-Amanah No. (e.g. "TREAS-001") instead of their real one,
-- and make sure Member Login still works for them once they're
-- no longer an officer.
--
-- PART A — admin_update_alamanah_no()
-- Lets a Super Admin correct a profile's Al-Amanah No. This is for
-- fixing officer profiles that were set up under SETUP.md's old
-- placeholder pattern (see ADMIN-GUIDE-officer-accounts.md) — the
-- officer's real savings/loans are already on this profile, they
-- were just tagged with the wrong number.
--
-- PART B — email_for_alamanah_no()
-- Member Login (login.html) currently guesses a member's sign-in
-- email purely by formatting their Al-Amanah No. That guess is
-- right for anyone who self-registered normally, but WRONG for a
-- former officer: their account's real sign-in email is whatever
-- was set via "Set Sign-in Email" (a real address), not the
-- generated placeholder. This function looks up whatever email is
-- ACTUALLY on file for a given Al-Amanah No., so Member Login keeps
-- working correctly even after someone stops being an officer and
-- goes back to logging in with just their Al-Amanah No. + password.
--
-- Run this ONCE in Supabase SQL Editor. Safe to re-run. REQUIRES
-- migration_activity_log_and_issues.sql already run (uses
-- log_activity()).
-- =========================================================

begin;

create or replace function public.admin_update_alamanah_no(p_profile_id uuid, p_new_alamanah_no text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old_no text;
  v_clean_no text := upper(trim(p_new_alamanah_no));
  v_conflict int;
begin
  if not public.is_admin() then
    raise exception 'Only a Super Admin may correct a member''s Al-Amanah No.';
  end if;

  v_clean_no := regexp_replace(v_clean_no, '^AL/?', '');
  if v_clean_no = '' then
    raise exception 'Enter a valid Al-Amanah No.';
  end if;
  v_clean_no := 'AL/' || v_clean_no;

  if not exists (select 1 from profiles where id = p_profile_id) then
    raise exception 'Member profile not found.';
  end if;

  select count(*) into v_conflict from profiles where alamanah_no = v_clean_no and id <> p_profile_id;
  if v_conflict > 0 then
    raise exception 'That Al-Amanah No. is already in use by another member.';
  end if;

  select alamanah_no into v_old_no from profiles where id = p_profile_id;

  update profiles set alamanah_no = v_clean_no where id = p_profile_id;

  perform public.log_activity('alamanah_no_corrected', 'profile', p_profile_id::text, p_profile_id, v_old_no, v_clean_no, null);
end;
$$;

-- Pre-login lookup: given an Al-Amanah No., return whichever email
-- is actually the account's real sign-in email. Only returns an
-- email — no other profile data — and only for accounts that exist,
-- so this adds no meaningful new information beyond what the
-- existing deterministic email format already implies for ordinary
-- members. Must be callable by a signed-OUT visitor, since this
-- runs as part of logging in.
create or replace function public.email_for_alamanah_no(p_alamanah_no text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_email text;
begin
  select id into v_id from profiles where lower(alamanah_no) = lower(trim(p_alamanah_no)) limit 1;
  if v_id is null then
    return null;
  end if;
  select email into v_email from auth.users where id = v_id;
  return v_email;
end;
$$;

grant execute on function public.email_for_alamanah_no(text) to anon, authenticated;

commit;
