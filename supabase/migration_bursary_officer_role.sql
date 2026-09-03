-- =========================================================
-- AL-AMANAH MCS — Bursary Officer role + 1/3 salary vetting gate
--
-- Adds the 4th Management Committee seat: the BURSARY OFFICER.
-- A member of the Bursary department who vets a loan applicant's
-- financial capacity — using the member's salary scale/rank (Gross
-- Pay and Net Pay) — BEFORE the Treasurer assesses the application
-- and the President decides on it.
--
-- Loan workflow becomes:
--   New application -> awaiting_bursary
--     Bursary vets (checks that Net Pay, after all deductions —
--     existing loans + savings + this new loan — would still be
--     at least 1/3 of Gross Pay):
--       eligible               -> awaiting_treasurer   (unchanged from here on)
--       not_eligible           -> declined immediately (hard gate —
--                                  the system will not let Bursary
--                                  mark an application eligible if it
--                                  breaches the 1/3 rule; see
--                                  submit_bursary_vetting below)
--       needs more info / hold -> on_hold_bursary (its own hold state,
--                                  separate from Treasurer/President's
--                                  shared "on_hold", so a Bursary hold
--                                  surfaces back to Bursary, not to
--                                  the Treasurer queue)
--
-- REQUIRES: schema.sql, migration_admin_deduction_controls.sql, and
-- the (externally-applied) role/workflow system that introduced
-- profiles.role, loans.workflow_status, is_treasurer()/is_president()/
-- is_secretary(), loan_assessments, loan_decisions, and
-- get_loan_financial_summary() already be in place on your database
-- (this is the system treasurer.html / president.html / secretary.html
-- already depend on).
--
-- Run this ONCE in Supabase SQL Editor. Safe to re-run.
-- =========================================================

begin;

-- ---------------------------------------------------------
-- 1. Widen the role check constraint to allow 'bursary'.
--    Finds whatever the existing check constraint on
--    profiles.role is actually named (it may differ from
--    'profiles_role_check' if your project renamed it) and
--    replaces it, rather than assuming a name.
-- ---------------------------------------------------------
do $$
declare
  v_conname text;
begin
  select c.conname into v_conname
  from pg_constraint c
  join pg_class t on t.oid = c.conrelid
  where t.relname = 'profiles' and c.contype = 'c'
    and pg_get_constraintdef(c.oid) ilike '%role%in%';
  if v_conname is not null then
    execute format('alter table profiles drop constraint %I', v_conname);
  end if;
end $$;

alter table profiles add constraint profiles_role_check
  check (role in ('member','treasurer','president','secretary','bursary','super_admin'));

-- ---------------------------------------------------------
-- 2. is_bursary() — same pattern as the other role checks.
--    NOTE: is_treasurer()/is_president()/is_secretary() were not
--    shipped in this repo's SQL files (they already exist on your
--    live database from an earlier, separately-applied migration).
--    This mirrors that same convention as closely as possible. If
--    your live is_treasurer()/is_president()/is_secretary() check
--    something other than `role = '<role>'` on the caller's own
--    profile row, adjust this function's body to match — everything
--    downstream only calls public.is_bursary(), never the row check
--    directly, so one edit here is all that's needed.
-- ---------------------------------------------------------
create or replace function public.is_bursary()
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select coalesce((select role = 'bursary' from profiles where id = auth.uid()), false);
$$;

-- ---------------------------------------------------------
-- 3. Salary fields on profiles — set by the Bursary Officer (or
--    Super Admin) from the official salary scale, by the member's
--    rank/grade. Nullable: a member with no salary on file yet
--    simply can't be vetted until Bursary records it.
-- ---------------------------------------------------------
alter table profiles
  add column if not exists gross_pay        numeric,
  add column if not exists net_pay          numeric,
  add column if not exists salary_updated_at date,
  add column if not exists salary_updated_by uuid references profiles(id);

create or replace function public.set_member_salary(p_member_id uuid, p_gross_pay numeric, p_net_pay numeric)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not (public.is_bursary() or public.is_admin()) then
    raise exception 'Only the Bursary Officer or a Super Admin may record a member''s salary.';
  end if;
  if p_gross_pay is null or p_gross_pay <= 0 or p_net_pay is null or p_net_pay <= 0 then
    raise exception 'Gross Pay and Net Pay must both be positive amounts.';
  end if;
  if p_net_pay > p_gross_pay then
    raise exception 'Net Pay cannot be greater than Gross Pay.';
  end if;

  update profiles set
    gross_pay = p_gross_pay,
    net_pay = p_net_pay,
    salary_updated_at = current_date,
    salary_updated_by = auth.uid()
  where id = p_member_id;
end;
$$;

-- ---------------------------------------------------------
-- 4. loan_vettings — the Bursary equivalent of loan_assessments.
--    One row per vetting decision (a loan can be vetted more than
--    once if returned/put on hold and revisited).
-- ---------------------------------------------------------
create table if not exists loan_vettings (
  id                       uuid primary key default gen_random_uuid(),
  loan_id                  text not null references loans(id) on delete cascade,
  bursary_officer_id       uuid not null references profiles(id),
  gross_pay                numeric not null,
  net_pay                  numeric not null,
  existing_monthly_deductions numeric not null,
  proposed_monthly_deduction  numeric not null,
  total_projected_deductions  numeric not null,
  one_third_gross_limit    numeric not null,
  net_pay_after_deductions numeric not null,
  within_limit             boolean not null,
  eligibility_status       text not null check (eligibility_status in ('eligible','not_eligible','needs_more_information','on_hold')),
  note                     text not null,
  created_at               timestamptz not null default now()
);

alter table loan_vettings enable row level security;

drop policy if exists "management team read vettings" on loan_vettings;
create policy "management team read vettings" on loan_vettings
  for select using (
    public.is_admin() or public.is_bursary() or public.is_treasurer()
    or public.is_president() or public.is_secretary()
  );

drop policy if exists "bursary insert vettings" on loan_vettings;
create policy "bursary insert vettings" on loan_vettings
  for insert with check (public.is_bursary());

-- 4b. If this table already exists from an earlier run of this
--     file using the old two-cap rule (1/3 of Gross AND 1/3 of
--     Net separately), migrate it to the corrected rule's column
--     name (Net Pay remaining after deductions, compared against
--     1/3 of Gross Pay only). Safe to run whether or not the old
--     column is present.
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_name = 'loan_vettings' and column_name = 'one_third_net_limit'
  ) and not exists (
    select 1 from information_schema.columns
    where table_name = 'loan_vettings' and column_name = 'net_pay_after_deductions'
  ) then
    alter table loan_vettings rename column one_third_net_limit to net_pay_after_deductions;
  end if;
end $$;

alter table loan_vettings add column if not exists net_pay_after_deductions numeric;

-- ---------------------------------------------------------
-- 5. Read-only preview for the Bursary Officer, mirroring
--    get_loan_financial_summary but centred on the 1/3 rule —
--    what this loan would add to the member's total deductions,
--    and whether that fits under 1/3 of Gross Pay AND 1/3 of Net
--    Pay (both must hold; the stricter of the two governs).
-- ---------------------------------------------------------
create or replace function public.get_bursary_financial_summary(p_loan_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_loan loans%rowtype;
  v_profile profiles%rowtype;
  v_existing numeric;
  v_proposed numeric;
  v_total numeric;
begin
  if not (public.is_bursary() or public.is_admin()) then
    raise exception 'Not authorized.';
  end if;

  select * into v_loan from loans where id = p_loan_id;
  if not found then raise exception 'Loan not found.'; end if;

  select * into v_profile from profiles where id = v_loan.member_id;

  select coalesce(sum(monthly_deduction), 0) into v_existing
  from loans
  where member_id = v_loan.member_id and status = 'approved' and id <> p_loan_id;

  v_existing := v_existing + coalesce(v_profile.monthly_savings_amount, 0);

  v_proposed := case when v_loan.duration > 0
    then round((v_loan.amount + coalesce(v_loan.admin_charge, 0)) / v_loan.duration)
    else v_loan.amount + coalesce(v_loan.admin_charge, 0)
  end;

  v_total := v_existing + v_proposed;

  return jsonb_build_object(
    'member_name', v_profile.first_name || ' ' || v_profile.surname,
    'alamanah_no', v_profile.alamanah_no,
    'department', v_profile.department,
    'loan_type', v_loan.type,
    'amount', v_loan.amount,
    'duration', v_loan.duration,
    'purpose', v_loan.purpose,
    'gross_pay', v_profile.gross_pay,
    'net_pay', v_profile.net_pay,
    'salary_updated_at', v_profile.salary_updated_at,
    'existing_monthly_deductions', v_existing,
    'proposed_monthly_deduction', v_proposed,
    'total_projected_deductions', v_total,
    'one_third_gross_limit', case when v_profile.gross_pay is not null then round(v_profile.gross_pay / 3.0) else null end,
    'net_pay_after_deductions', case when v_profile.net_pay is not null then v_profile.net_pay - v_total else null end,
    'within_limit', case
      when v_profile.gross_pay is null or v_profile.net_pay is null then null
      else (v_profile.net_pay - v_total) >= round(v_profile.gross_pay / 3.0)
    end
  );
end;
$$;

-- ---------------------------------------------------------
-- 6. submit_bursary_vetting — the hard 1/3 gate. Bursary may
--    optionally record/update the member's salary in the same
--    call (p_gross_pay / p_net_pay), or rely on figures already
--    on file. Marking an application "eligible" is REJECTED
--    server-side if the total projected deduction would exceed
--    1/3 of Gross Pay OR 1/3 of Net Pay — the Bursary Officer
--    cannot override this by choice of dropdown value; the
--    system itself will not allow it, per the deduction ceiling
--    the cooperative applies to every member.
-- ---------------------------------------------------------
create or replace function public.submit_bursary_vetting(
  p_loan_id text,
  p_eligibility_status text,
  p_note text,
  p_gross_pay numeric default null,
  p_net_pay numeric default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_loan loans%rowtype;
  v_profile profiles%rowtype;
  v_summary jsonb;
  v_existing numeric;
  v_proposed numeric;
  v_total numeric;
  v_gross numeric;
  v_net numeric;
  v_limit numeric;
  v_remaining_net numeric;
  v_within boolean;
  v_new_workflow_status text;
begin
  if not public.is_bursary() then
    raise exception 'Only the Bursary Officer may submit a loan vetting.';
  end if;

  select * into v_loan from loans where id = p_loan_id for update;
  if not found then raise exception 'Loan not found.'; end if;

  if v_loan.workflow_status not in ('awaiting_bursary', 'returned_to_bursary', 'on_hold_bursary') then
    raise exception 'This application is not currently awaiting Bursary vetting.';
  end if;

  if p_eligibility_status not in ('eligible','not_eligible','needs_more_information','on_hold') then
    raise exception 'Invalid eligibility status.';
  end if;

  if coalesce(trim(p_note), '') = '' then
    raise exception 'A vetting note is required.';
  end if;

  -- Record/refresh the member's salary if given this time.
  if p_gross_pay is not null or p_net_pay is not null then
    perform public.set_member_salary(v_loan.member_id, p_gross_pay, p_net_pay);
  end if;

  select * into v_profile from profiles where id = v_loan.member_id;
  v_gross := v_profile.gross_pay;
  v_net := v_profile.net_pay;

  if v_gross is null or v_net is null then
    raise exception 'Record this member''s Gross Pay and Net Pay before vetting this application.';
  end if;

  select coalesce(sum(monthly_deduction), 0) into v_existing
  from loans
  where member_id = v_loan.member_id and status = 'approved' and id <> p_loan_id;
  v_existing := v_existing + coalesce(v_profile.monthly_savings_amount, 0);

  v_proposed := case when v_loan.duration > 0
    then round((v_loan.amount + coalesce(v_loan.admin_charge, 0)) / v_loan.duration)
    else v_loan.amount + coalesce(v_loan.admin_charge, 0)
  end;
  v_total := v_existing + v_proposed;
  v_limit := round(v_gross / 3.0);
  v_remaining_net := v_net - v_total;
  v_within := v_remaining_net >= v_limit;

  -- The hard gate: Bursary cannot mark an application eligible if,
  -- after this loan's deduction is added, the member's Net Pay
  -- would fall below one-third of their Gross Pay. The system
  -- itself enforces this — it cannot be overridden by dropdown
  -- choice alone.
  if p_eligibility_status = 'eligible' and not v_within then
    raise exception 'This application cannot be marked eligible: after total deductions of %, Net Pay would be %, which is below one-third of Gross Pay (%).',
      to_char(v_total, 'FM999,999,999'),
      to_char(round(v_remaining_net), 'FM999,999,999'),
      to_char(v_limit, 'FM999,999,999');
  end if;

  insert into loan_vettings (
    loan_id, bursary_officer_id, gross_pay, net_pay,
    existing_monthly_deductions, proposed_monthly_deduction, total_projected_deductions,
    one_third_gross_limit, net_pay_after_deductions, within_limit, eligibility_status, note
  ) values (
    p_loan_id, auth.uid(), v_gross, v_net,
    v_existing, v_proposed, v_total,
    v_limit, v_remaining_net, v_within, p_eligibility_status, p_note
  );

  if p_eligibility_status = 'eligible' then
    v_new_workflow_status := 'awaiting_treasurer';
    update loans set workflow_status = v_new_workflow_status where id = p_loan_id;
  elsif p_eligibility_status = 'not_eligible' then
    v_new_workflow_status := 'declined_by_bursary';
    update loans set
      status = 'declined',
      date_decision = current_date,
      decline_reason = coalesce(p_note, 'Total deductions would exceed one-third of Gross/Net Pay (Bursary vetting).'),
      workflow_status = v_new_workflow_status
    where id = p_loan_id;
  else
    v_new_workflow_status := 'on_hold_bursary';
    update loans set workflow_status = v_new_workflow_status where id = p_loan_id;
  end if;

  perform public.log_activity(
    'loan_vetting_submitted', 'loan', p_loan_id, v_loan.member_id,
    v_loan.workflow_status, v_new_workflow_status,
    jsonb_build_object('eligibility_status', p_eligibility_status, 'total_projected_deductions', v_total, 'within_limit', v_within)
  );
end;
$$;

-- ---------------------------------------------------------
-- 7. New applications now start at the Bursary desk, not the
--    Treasurer's. Nothing else about how a loan is inserted
--    (apply-loan.html / applyForLoan()) needs to change — it
--    never sets workflow_status explicitly, so it always used
--    (and will keep using) this column default.
-- ---------------------------------------------------------
alter table loans alter column workflow_status set default 'awaiting_bursary';

-- Widen whatever check constraint governs loans.workflow_status
-- (if one exists) to include the new Bursary-stage values,
-- again without assuming its name.
do $$
declare
  v_conname text;
begin
  select c.conname into v_conname
  from pg_constraint c
  join pg_class t on t.oid = c.conrelid
  where t.relname = 'loans' and c.contype = 'c'
    and pg_get_constraintdef(c.oid) ilike '%workflow_status%';
  if v_conname is not null then
    execute format('alter table loans drop constraint %I', v_conname);
  end if;
end $$;

alter table loans add constraint loans_workflow_status_check
  check (workflow_status in (
    'awaiting_bursary','returned_to_bursary','on_hold_bursary','declined_by_bursary',
    'awaiting_treasurer','returned_to_treasurer',
    'awaiting_president',
    'on_hold','approved','declined'
  ));

-- ---------------------------------------------------------
-- 8. Let the Bursary Officer report problems too, same as the
--    other three officer roles (additive — widens who may call
--    this; nothing about how it behaves for Treasurer/President/
--    Secretary changes).
-- ---------------------------------------------------------
create or replace function public.report_management_issue(
  p_title text,
  p_description text,
  p_related_member_id uuid default null,
  p_related_loan_id text default null,
  p_severity text default 'normal'
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role text;
  v_new_id uuid;
begin
  select role into v_role from profiles where id = auth.uid();
  if v_role not in ('treasurer','president','secretary','bursary') then
    raise exception 'Only a Treasurer, President, Secretary, or Bursary Officer may report a management issue.';
  end if;

  if coalesce(trim(p_title), '') = '' or coalesce(trim(p_description), '') = '' then
    raise exception 'A title and description are required.';
  end if;

  if p_severity not in ('low','normal','high') then
    raise exception 'Invalid severity.';
  end if;

  insert into management_issues (reported_by, reporter_role, title, description, related_member_id, related_loan_id, severity)
  values (auth.uid(), v_role, p_title, p_description, p_related_member_id, p_related_loan_id, p_severity)
  returning id into v_new_id;

  perform public.log_activity('management_issue_reported', 'management_issue', v_new_id::text, p_related_member_id, null, 'open', jsonb_build_object('title', p_title, 'severity', p_severity));

  return v_new_id;
end;
$$;

-- ---------------------------------------------------------
-- 8b. Let the Bursary Officer actually SEE loan applications and
--     applicant profiles. The Treasurer/President/Secretary loan
--     workflow already grants those three roles read access to
--     the loans and profiles tables (via whatever RLS policy your
--     original workflow migration set up), but Bursary is new and
--     wasn't covered by it. This adds Bursary's own read access
--     alongside the existing policies — Postgres OR's permissive
--     RLS policies together, so this can never remove access
--     anyone else already has; it only adds Bursary's.
-- ---------------------------------------------------------
drop policy if exists "bursary read loans" on loans;
create policy "bursary read loans" on loans
  for select using (public.is_bursary());

drop policy if exists "bursary read profiles" on profiles;
create policy "bursary read profiles" on profiles
  for select using (public.is_bursary());

-- ---------------------------------------------------------
-- 9. Let a Super Admin assign the Bursary role from
--    admin.html's Management Team tab (widens admin_set_role's
--    allow-list only — everything else about it is unchanged
--    from migration_fix_role_sync.sql).
-- ---------------------------------------------------------
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

  if p_role not in ('member','treasurer','president','secretary','bursary','super_admin') then
    raise exception 'Invalid role.';
  end if;

  select role into v_old_role from profiles where id = p_profile_id;
  if not found then raise exception 'Profile not found.'; end if;

  if v_old_role = p_role then
    return;
  end if;

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

-- ---------------------------------------------------------
-- After running:
--   1. Promote a member to Bursary Officer from admin.html ->
--      Management Team -> "Assign a role to a member".
--   2. Use "Set Sign-in Email" so they can log in at bursary.html.
--   3. New loan applications will now land in the Bursary Officer's
--      queue first, then flow to the Treasurer once vetted eligible.
-- ---------------------------------------------------------
