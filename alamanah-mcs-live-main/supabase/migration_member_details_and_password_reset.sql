-- =========================================================
-- MIGRATION: Forgot Password for members + admin-editable
-- member details
--
-- PART A — Use a member's real email as their account's actual
-- sign-in email when one was provided, instead of ALWAYS using the
-- generated placeholder (al014@members.alamanahmcs.local). The
-- placeholder domain doesn't exist, so Supabase's built-in
-- "reset password" email can never actually be delivered to it —
-- this is why the reset flow needs a real email on the account to
-- work at all. contact_email_for_pending_member() lets the signup
-- flow look this up before creating the account. Existing accounts
-- created before this migration are unaffected; use "Set Member
-- Email" (Part B) to add a real email to them after the fact.
--
-- PART B — admin_update_member_details()
-- Lets a Super Admin correct any member's name/department/phone —
-- the fields the old "Create New Member" form allowed to be entered
-- incorrectly or left blank (e.g. no email, so the member can never
-- use "Forgot password" until an admin fixes it). Email itself is
-- still handled by admin_set_profile_email() from
-- migration_set_officer_email.sql, since changing it must also
-- update the Supabase Auth account, not just the profiles row.
--
-- Run this ONCE in Supabase SQL Editor. Safe to re-run. REQUIRES
-- migration_activity_log_and_issues.sql and
-- migration_set_officer_email.sql already run.
-- =========================================================

begin;

-- Part A: pre-signup lookup, callable by a signed-out visitor
-- (setup-password.html runs before any session exists).
create or replace function public.contact_email_for_pending_member(p_alamanah_no text, p_surname text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email text;
begin
  select contact_email into v_email
  from member_directory
  where lower(alamanah_no) = lower(trim(p_alamanah_no))
    and lower(surname) = lower(trim(p_surname))
    and claimed = false
  limit 1;
  return v_email;
end;
$$;

grant execute on function public.contact_email_for_pending_member(text, text) to anon, authenticated;

-- Part B: admin-only correction of the non-email profile fields.
create or replace function public.admin_update_member_details(
  p_profile_id uuid,
  p_first_name text,
  p_surname text,
  p_department text,
  p_phone text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Only a Super Admin may edit member details.';
  end if;

  if not exists (select 1 from profiles where id = p_profile_id) then
    raise exception 'Member profile not found.';
  end if;

  if p_first_name is null or trim(p_first_name) = '' then
    raise exception 'First name cannot be empty.';
  end if;
  if p_surname is null or trim(p_surname) = '' then
    raise exception 'Surname cannot be empty.';
  end if;

  update profiles set
    first_name = trim(p_first_name),
    surname    = trim(p_surname),
    department = nullif(trim(coalesce(p_department, '')), ''),
    phone      = nullif(trim(coalesce(p_phone, '')), '')
  where id = p_profile_id;

  perform public.log_activity(
    'member_details_updated', 'profile', p_profile_id::text, p_profile_id, null, null,
    jsonb_build_object('first_name', p_first_name, 'surname', p_surname, 'department', p_department, 'phone', p_phone)
  );
end;
$$;

commit;
