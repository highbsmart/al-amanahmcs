-- =========================================================
-- AL-AMANAH MCS — Steps 12 & 13
-- Step 12: automatic activity/audit logging for every officer
--          action (Treasurer assessments, President decisions,
--          Secretary records).
-- Step 13: problem reporting — officers can flag an issue,
--          Super Admin tracks and resolves it.
--
-- REQUIRES steps 5, 6, 7, and the financial-summary migration to
-- already be run.
--
-- Run this once in Supabase: SQL Editor -> New query -> paste ->
-- Run. Safe to re-run if something fails partway.
--
-- IMPORTANT: this does NOT change what any existing function does
-- for a member, a loan, savings, or a payslip. It only (a) adds two
-- new tables, and (b) adds one extra line to four existing officer
-- functions so each one also writes a log entry. The financial/
-- workflow logic inside those four functions is unchanged.
-- =========================================================

begin;

-- ---------------------------------------------------------
-- PART A (Step 12) — activity_logs
-- ---------------------------------------------------------
create table if not exists activity_logs (
  id              uuid primary key default gen_random_uuid(),
  actor_id        uuid not null references profiles(id),
  actor_role      text not null,
  action_type     text not null,
  entity_type     text not null,
  entity_id       text not null,
  member_id       uuid references profiles(id),
  previous_value  text,
  new_value       text,
  metadata        jsonb,
  created_at      timestamptz not null default now()
);

alter table activity_logs enable row level security;

drop policy if exists "officers read own activity" on activity_logs;
create policy "officers read own activity" on activity_logs
  for select using (actor_id = auth.uid());

drop policy if exists "super admin reads all activity" on activity_logs;
create policy "super admin reads all activity" on activity_logs
  for select using (public.is_admin());

-- The only way a row gets written. Ordinary officers cannot
-- edit or delete log entries at all — there is no update/delete
-- policy or function for this table.
create or replace function public.log_activity(
  p_action_type text,
  p_entity_type text,
  p_entity_id text,
  p_member_id uuid default null,
  p_previous_value text default null,
  p_new_value text default null,
  p_metadata jsonb default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role text;
begin
  select role into v_role from profiles where id = auth.uid();
  insert into activity_logs (actor_id, actor_role, action_type, entity_type, entity_id, member_id, previous_value, new_value, metadata)
  values (auth.uid(), coalesce(v_role, 'unknown'), p_action_type, p_entity_type, p_entity_id, p_member_id, p_previous_value, p_new_value, p_metadata);
end;
$$;

-- Add logging to the four existing officer functions. Each one is
-- reproduced in full below (create or replace), with exactly one
-- new line added near the end — the rest of the function body is
-- identical to the version from the earlier migrations.

create or replace function public.submit_treasurer_assessment(
  p_loan_id text,
  p_eligibility_status text,
  p_recommendation text,
  p_assessment_note text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_loan loans%rowtype;
  v_snapshot jsonb;
  v_new_workflow_status text;
begin
  if not public.is_treasurer() then
    raise exception 'Only the Treasurer may submit a loan assessment.';
  end if;

  select * into v_loan from loans where id = p_loan_id for update;
  if not found then raise exception 'Loan not found.'; end if;

  if v_loan.workflow_status not in ('awaiting_treasurer', 'returned_to_treasurer', 'on_hold') then
    raise exception 'This application is not currently awaiting Treasurer assessment.';
  end if;

  if p_eligibility_status not in ('eligible','not_eligible','needs_more_information','on_hold') then
    raise exception 'Invalid eligibility status.';
  end if;

  if coalesce(trim(p_assessment_note), '') = '' then
    raise exception 'An assessment note is required.';
  end if;

  v_snapshot := public.get_loan_financial_summary(p_loan_id);

  insert into loan_assessments (loan_id, treasurer_id, eligibility_status, recommendation, assessment_note, financial_snapshot)
  values (p_loan_id, auth.uid(), p_eligibility_status, p_recommendation, p_assessment_note, v_snapshot);

  if p_eligibility_status in ('eligible', 'not_eligible') then
    v_new_workflow_status := 'awaiting_president';
  else
    v_new_workflow_status := 'on_hold';
  end if;

  update loans set workflow_status = v_new_workflow_status where id = p_loan_id;

  perform public.log_activity(
    'loan_assessment_submitted', 'loan', p_loan_id, v_loan.member_id,
    v_loan.workflow_status, v_new_workflow_status,
    jsonb_build_object('eligibility_status', p_eligibility_status, 'recommendation', p_recommendation)
  );
end;
$$;

create or replace function public.submit_president_decision(
  p_loan_id text,
  p_decision text,
  p_decision_note text default null,
  p_returned_reason text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_loan loans%rowtype;
begin
  if not public.is_president() then
    raise exception 'Only the President may record a loan decision.';
  end if;

  select * into v_loan from loans where id = p_loan_id for update;
  if not found then raise exception 'Loan not found.'; end if;

  if v_loan.workflow_status <> 'awaiting_president' then
    raise exception 'This application is not currently awaiting a President decision.';
  end if;

  if p_decision not in ('approved','declined','returned_to_treasurer','on_hold') then
    raise exception 'Invalid decision.';
  end if;

  if p_decision = 'returned_to_treasurer' and coalesce(trim(p_returned_reason), '') = '' then
    raise exception 'A reason is required when returning an application to the Treasurer.';
  end if;

  insert into loan_decisions (loan_id, president_id, decision, decision_note, returned_reason)
  values (p_loan_id, auth.uid(), p_decision, p_decision_note, p_returned_reason);

  if p_decision in ('approved','declined') then
    perform public.decide_loan(p_loan_id, p_decision, p_decision_note);
    update loans set workflow_status = p_decision where id = p_loan_id;
  elsif p_decision = 'returned_to_treasurer' then
    update loans set workflow_status = 'returned_to_treasurer' where id = p_loan_id;
  else
    update loans set workflow_status = 'on_hold' where id = p_loan_id;
  end if;

  perform public.log_activity(
    'loan_decision_recorded', 'loan', p_loan_id, v_loan.member_id,
    v_loan.workflow_status, p_decision,
    jsonb_build_object('decision', p_decision, 'note', p_decision_note, 'returned_reason', p_returned_reason)
  );
end;
$$;

create or replace function public.create_official_record(
  p_related_entity_type text,
  p_related_entity_id uuid,
  p_loan_id text,
  p_official_note text,
  p_reference_number text default null,
  p_meeting_reference text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_member_id uuid;
  v_new_id uuid;
begin
  if not public.is_secretary() then
    raise exception 'Only the Secretary may create an official record.';
  end if;

  if p_related_entity_type not in ('loan_assessment','loan_decision') then
    raise exception 'Invalid record type.';
  end if;

  if coalesce(trim(p_official_note), '') = '' then
    raise exception 'An official note is required.';
  end if;

  select member_id into v_member_id from loans where id = p_loan_id;

  insert into official_records (
    related_entity_type, related_entity_id, loan_id, member_id,
    recorded_by, reference_number, meeting_reference, official_note
  )
  values (
    p_related_entity_type, p_related_entity_id, p_loan_id, v_member_id,
    auth.uid(), p_reference_number, p_meeting_reference, p_official_note
  )
  returning id into v_new_id;

  perform public.log_activity(
    'official_record_created', 'official_record', v_new_id::text, v_member_id,
    null, 'pending',
    jsonb_build_object('loan_id', p_loan_id, 'reference_number', p_reference_number)
  );

  return v_new_id;
end;
$$;

create or replace function public.mark_official_record_complete(p_record_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_member_id uuid;
begin
  if not public.is_secretary() then
    raise exception 'Only the Secretary may update an official record.';
  end if;

  update official_records
  set documentation_status = 'complete', updated_at = now()
  where id = p_record_id
  returning member_id into v_member_id;

  if not found then raise exception 'Record not found.'; end if;

  perform public.log_activity(
    'official_record_completed', 'official_record', p_record_id::text, v_member_id,
    'pending', 'complete', null
  );
end;
$$;

-- ---------------------------------------------------------
-- PART B (Step 13) — management_issues
-- ---------------------------------------------------------
create table if not exists management_issues (
  id                  uuid primary key default gen_random_uuid(),
  reported_by         uuid not null references profiles(id),
  reporter_role       text not null,
  assigned_to         uuid references profiles(id),
  title               text not null,
  description         text not null,
  related_member_id   uuid references profiles(id),
  related_loan_id     text references loans(id),
  severity            text not null default 'normal' check (severity in ('low','normal','high')),
  status              text not null default 'open' check (status in ('open','in_progress','resolved','closed')),
  resolution_note     text,
  created_at          timestamptz not null default now(),
  resolved_at         timestamptz
);

alter table management_issues enable row level security;

drop policy if exists "officers read own issues" on management_issues;
create policy "officers read own issues" on management_issues
  for select using (reported_by = auth.uid());

drop policy if exists "super admin reads all issues" on management_issues;
create policy "super admin reads all issues" on management_issues
  for select using (public.is_admin());

-- Reachable by any of the three officer roles (not members, not
-- Super Admin — Super Admin doesn't report issues to themself).
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
  if v_role not in ('treasurer','president','secretary') then
    raise exception 'Only a Treasurer, President, or Secretary may report a management issue.';
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

-- Super Admin only. Also used to just move an issue to
-- "in_progress" (resolution_note can be left blank for that).
create or replace function public.resolve_management_issue(
  p_issue_id uuid,
  p_status text,
  p_resolution_note text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old_status text;
begin
  if not public.is_admin() then
    raise exception 'Only a Super Admin may update a management issue.';
  end if;

  if p_status not in ('in_progress','resolved','closed') then
    raise exception 'Invalid status.';
  end if;

  select status into v_old_status from management_issues where id = p_issue_id;
  if not found then raise exception 'Issue not found.'; end if;

  update management_issues
  set status = p_status,
      resolution_note = coalesce(p_resolution_note, resolution_note),
      resolved_at = case when p_status in ('resolved','closed') then now() else resolved_at end
  where id = p_issue_id;

  perform public.log_activity('management_issue_updated', 'management_issue', p_issue_id::text, null, v_old_status, p_status, jsonb_build_object('resolution_note', p_resolution_note));
end;
$$;

commit;

-- ---------------------------------------------------------
-- Verify after running:
--   select * from activity_logs order by created_at desc limit 20;
--   select * from management_issues order by created_at desc;
-- ---------------------------------------------------------
