-- =========================================================
-- MIGRATION: Expunge Member
--
-- Adds an admin-only, permanent "expunge" action: deletes a
-- member's login, profile, and every record tied to them
-- (loans, transactions, savings/admin-charge adjustments,
-- payslip overrides, activity log entries, management issues,
-- loan assessments/decisions, official records, offset
-- requests) and frees up their Al-Amanah No. to be reused.
--
-- This is IRREVERSIBLE. Unlike "Clear History" elsewhere in
-- the admin panel (which just hides records from view and can
-- be restored), expunging permanently deletes the rows. A
-- lightweight audit trail of WHO was expunged, WHEN, and WHY
-- is kept in expunged_members_log — that table does not
-- reference profiles, so it survives the deletion.
--
-- Run this ONCE in Supabase: Dashboard -> SQL Editor -> New
-- query -> paste -> Run. Safe to run on an existing live
-- project.
--
-- NOTE: this function deletes directly from auth.users via
-- SQL (not the Auth admin API), which is what lets it run
-- under the ordinary anon/authenticated client with no service-
-- role key exposed to the browser. If your project has revoked
-- the default owner privileges on the auth schema and the last
-- step of the function errors, everything else (profile, loans,
-- transactions, etc.) will already be gone — just delete the
-- leftover row from Authentication -> Users in the dashboard to
-- finish.
-- =========================================================

-- 1. Permanent audit trail — deliberately has NO foreign key to
--    profiles, so it is not affected when the profile is deleted.
create table if not exists expunged_members_log (
  id           uuid primary key default gen_random_uuid(),
  member_id    uuid not null,
  alamanah_no  text not null,
  first_name   text not null,
  surname      text not null,
  reason       text not null,
  expunged_by  uuid not null references profiles(id),
  created_at   timestamptz not null default now()
);

alter table expunged_members_log enable row level security;

drop policy if exists "admins read expunge log" on expunged_members_log;
create policy "admins read expunge log" on expunged_members_log
  for select using (public.is_admin());

-- 2. The expunge function itself.
create or replace function public.admin_expunge_member(p_member_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile     profiles%rowtype;
  v_admin_count int;
begin
  if not public.is_admin() then
    raise exception 'Only an admin may expunge a member.';
  end if;
  if p_member_id = auth.uid() then
    raise exception 'You cannot expunge your own account.';
  end if;
  if coalesce(trim(p_reason), '') = '' then
    raise exception 'A reason is required to expunge a member.';
  end if;

  select * into v_profile from profiles where id = p_member_id;
  if not found then
    raise exception 'Member not found.';
  end if;

  -- Safety net: never leave the co-operative with zero Super Admins.
  if v_profile.is_admin then
    select count(*) into v_admin_count from profiles where is_admin = true;
    if v_admin_count <= 1 then
      raise exception 'Cannot expunge the only remaining Super Admin account.';
    end if;
  end if;

  insert into expunged_members_log (member_id, alamanah_no, first_name, surname, reason, expunged_by)
  values (p_member_id, v_profile.alamanah_no, v_profile.first_name, v_profile.surname, p_reason, auth.uid());

  -- Tables added by later migrations may not exist on every
  -- deployment — each block below is skipped if its table is
  -- missing, so this function works whether or not the activity
  -- log / management issues / role-workflow migrations were run.

  if to_regclass('public.activity_logs') is not null then
    delete from activity_logs where actor_id = p_member_id or member_id = p_member_id;
  end if;

  if to_regclass('public.management_issues') is not null then
    delete from management_issues
      where reported_by = p_member_id or assigned_to = p_member_id or related_member_id = p_member_id;
  end if;

  if to_regclass('public.loan_offset_requests') is not null then
    delete from loan_offset_requests where member_id = p_member_id;
  end if;

  -- These three are keyed off this member's own loans, plus (best
  -- effort) any rows where this member acted as the Treasurer/
  -- President/Secretary on someone ELSE's loan — those are nulled
  -- out rather than deleted, so other members' loan history stays
  -- intact. Wrapped defensively in case a column differs from what
  -- the officer-workflow migration defines on this project.
  if to_regclass('public.official_records') is not null then
    delete from official_records
      where member_id = p_member_id or loan_id in (select id from loans where member_id = p_member_id);
    begin
      update official_records set recorded_by = null where recorded_by = p_member_id;
    exception when others then null;
    end;
  end if;

  if to_regclass('public.loan_decisions') is not null then
    delete from loan_decisions where loan_id in (select id from loans where member_id = p_member_id);
    begin
      update loan_decisions set president_id = null where president_id = p_member_id;
    exception when others then null;
    end;
  end if;

  if to_regclass('public.loan_assessments') is not null then
    delete from loan_assessments where loan_id in (select id from loans where member_id = p_member_id);
    begin
      update loan_assessments set treasurer_id = null where treasurer_id = p_member_id;
    exception when others then null;
    end;
  end if;

  -- Free up the Al-Amanah No. so it can be reissued to someone else.
  delete from member_directory where alamanah_no = v_profile.alamanah_no;

  -- Deleting the auth user cascades to profiles (on delete cascade),
  -- which in turn cascades to loans, transactions,
  -- savings_adjustments, admin_charge_adjustments, and
  -- payslip_overrides — all declared "on delete cascade" already.
  delete from auth.users where id = p_member_id;
end;
$$;

-- Done. Redeploy admin.html/js/admin.js/js/data-live.js alongside this.
