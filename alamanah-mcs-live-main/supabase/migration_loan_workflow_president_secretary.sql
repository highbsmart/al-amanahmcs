-- =========================================================
-- RECONSTRUCTED FILE — migration_loan_workflow_president_secretary.sql
--
-- This file is not the original. The original was referenced by name
-- in a comment inside supabase/schema.sql ("...or the live database
-- will be missing the role/workflow objects — see
-- supabase/migration_loan_workflow_president_secretary.sql") but was
-- never actually present in the exported codebase, even though its
-- effects clearly ARE live on the Supabase project (treasurer.html,
-- president.html, and secretary.html all depend on objects only this
-- file could have created).
--
-- This reconstruction was built by reverse-engineering every object
-- it must define from how later, still-present migrations call it:
--   - migration_loan_financial_summary.sql refactors
--     submit_treasurer_assessment(), implying it already existed.
--   - migration_activity_log_and_issues.sql reproduces
--     submit_treasurer_assessment(), submit_president_decision(),
--     create_official_record(), and mark_official_record_complete()
--     "in full" while only adding a logging call — meaning their
--     pre-logging bodies (and the tables they write to) already
--     existed before that migration ran.
--   - migration_manual_offset_workflow.sql's RLS pattern
--     (admin/treasurer/president/secretary) was reused here for
--     consistency.
--   - js/treasurer.js, js/president.js, js/secretary.js, and
--     js/data-live.js were read column-by-column to recover the
--     exact table/column names actually queried in production.
--
-- Because of that, submit_treasurer_assessment(), submit_president_
-- decision(), create_official_record(), mark_official_record_complete(),
-- and get_loan_financial_summary() are intentionally NOT redefined
-- here — your existing migration_loan_financial_summary.sql and
-- migration_activity_log_and_issues.sql already define the current,
-- correct versions of those, and re-declaring them here risked
-- drifting from what's actually live. This file only rebuilds the
-- layer underneath them that no remaining file defines.
--
-- Everything below is written defensively (IF NOT EXISTS / CREATE OR
-- REPLACE / dynamic constraint lookups) so it is safe to run even
-- though this system is already live and working — it will not
-- overwrite data, and on tables/columns/functions that already exist
-- it is a no-op. Its real purpose is so a from-scratch rebuild (new
-- Supabase project, disaster recovery) has everything it needs,
-- and so this piece of your schema is no longer missing from source
-- control.
--
-- Run AFTER schema.sql and migration_admin_deduction_controls.sql.
-- Run BEFORE migration_loan_financial_summary.sql,
-- migration_activity_log_and_issues.sql, migration_manual_offset_
-- workflow.sql, and migration_bursary_officer_role.sql (those all
-- assume the objects created here already exist) — though since
-- everything here is idempotent, running it in any order is safe.
-- =========================================================

begin;

-- ---------------------------------------------------------
-- 1. profiles.role — the Management Committee seat a profile
--    holds. ('member' is the default: an ordinary member with no
--    officer seat.) migration_fix_role_sync.sql already patches
--    this defensively too; this is the original intent, kept here
--    so this file is self-contained.
-- ---------------------------------------------------------
alter table profiles add column if not exists role text not null default 'member';

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
  -- 'bursary' is included here (not just added later by
  -- migration_bursary_officer_role.sql) so this file is safe to
  -- run even after a Bursary Officer has already been assigned —
  -- re-running it will not lock that role out again.

-- ---------------------------------------------------------
-- 2. Role-check helper functions — same one-line pattern as
--    is_admin() in schema.sql. Every officer page and RPC in this
--    codebase calls these, never the raw column, so if your actual
--    live definition differs from this simple pattern, this is the
--    one place to correct it.
-- ---------------------------------------------------------
create or replace function public.is_treasurer()
returns boolean language sql security definer set search_path = public stable as $$
  select coalesce((select role = 'treasurer' from profiles where id = auth.uid()), false);
$$;

create or replace function public.is_president()
returns boolean language sql security definer set search_path = public stable as $$
  select coalesce((select role = 'president' from profiles where id = auth.uid()), false);
$$;

create or replace function public.is_secretary()
returns boolean language sql security definer set search_path = public stable as $$
  select coalesce((select role = 'secretary' from profiles where id = auth.uid()), false);
$$;

-- ---------------------------------------------------------
-- 3. loans.workflow_status — tracks which desk an application is
--    currently on, separately from loans.status (which stays
--    'pending' throughout and only becomes 'approved'/'declined'
--    once decide_loan() below is called).
-- ---------------------------------------------------------
alter table loans add column if not exists workflow_status text not null default 'awaiting_treasurer';

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
    'on_hold','awaiting_president','approved','declined'
  ));
  -- Bursary-stage values are included here directly (not left for
  -- migration_bursary_officer_role.sql to add later) so this file
  -- is safe to run even after Bursary vetting has already been
  -- used — re-running it will not lock those states out again.

-- ---------------------------------------------------------
-- 4. loan_assessments — the Treasurer's eligibility assessment for
--    an application. One row per assessment (an application can be
--    assessed more than once if put on hold and revisited).
-- ---------------------------------------------------------
create table if not exists loan_assessments (
  id                 uuid primary key default gen_random_uuid(),
  loan_id            text not null references loans(id) on delete cascade,
  treasurer_id       uuid not null references profiles(id),
  eligibility_status text not null check (eligibility_status in ('eligible','not_eligible','needs_more_information','on_hold')),
  recommendation     text,
  assessment_note    text not null,
  financial_snapshot jsonb,
  created_at         timestamptz not null default now()
);

alter table loan_assessments enable row level security;

drop policy if exists "management team read assessments" on loan_assessments;
create policy "management team read assessments" on loan_assessments
  for select using (
    public.is_admin() or public.is_treasurer() or public.is_president() or public.is_secretary()
  );

drop policy if exists "treasurer insert assessments" on loan_assessments;
create policy "treasurer insert assessments" on loan_assessments
  for insert with check (public.is_treasurer());

-- ---------------------------------------------------------
-- 5. loan_decisions — the President's final decision on an
--    application (mirrors what submit_president_decision() in
--    migration_activity_log_and_issues.sql inserts into).
-- ---------------------------------------------------------
create table if not exists loan_decisions (
  id              uuid primary key default gen_random_uuid(),
  loan_id         text not null references loans(id) on delete cascade,
  president_id    uuid not null references profiles(id),
  decision        text not null check (decision in ('approved','declined','on_hold','returned_to_treasurer')),
  decision_note   text,
  returned_reason text,
  created_at      timestamptz not null default now()
);

alter table loan_decisions enable row level security;

drop policy if exists "management team read decisions" on loan_decisions;
create policy "management team read decisions" on loan_decisions
  for select using (
    public.is_admin() or public.is_treasurer() or public.is_president() or public.is_secretary()
  );

drop policy if exists "president insert decisions" on loan_decisions;
create policy "president insert decisions" on loan_decisions
  for insert with check (public.is_president());

-- ---------------------------------------------------------
-- 6. official_records — the Secretary's documentation of a
--    decided application (mirrors what create_official_record()
--    in migration_activity_log_and_issues.sql inserts into, and
--    what mark_official_record_complete() there updates).
-- ---------------------------------------------------------
create table if not exists official_records (
  id                  uuid primary key default gen_random_uuid(),
  related_entity_type text not null check (related_entity_type in ('loan_assessment','loan_decision')),
  related_entity_id   uuid,
  loan_id             text references loans(id) on delete set null,
  member_id           uuid references profiles(id),
  recorded_by         uuid not null references profiles(id),
  reference_number    text,
  meeting_reference   text,
  official_note       text not null,
  documentation_status text not null default 'pending' check (documentation_status in ('pending','complete')),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

alter table official_records enable row level security;

drop policy if exists "management team read records" on official_records;
create policy "management team read records" on official_records
  for select using (
    public.is_admin() or public.is_treasurer() or public.is_president() or public.is_secretary()
  );

drop policy if exists "secretary insert records" on official_records;
create policy "secretary insert records" on official_records
  for insert with check (public.is_secretary());

drop policy if exists "secretary update records" on official_records;
create policy "secretary update records" on official_records
  for update using (public.is_secretary()) with check (public.is_secretary());

-- ---------------------------------------------------------
-- 7. decide_loan() — widened so the President can approve or
--    decline an application too, not only a Super Admin. The
--    approve/decline logic itself is copied verbatim from
--    schema.sql; only the authorization check changes.
-- ---------------------------------------------------------
create or replace function public.decide_loan(p_loan_id text, p_decision text, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_loan loans%rowtype;
  v_total numeric;
begin
  if not (public.is_admin() or public.is_president()) then
    raise exception 'Only a Super Admin or the President may decide loans.';
  end if;

  select * into v_loan from loans where id = p_loan_id for update;
  if not found then
    raise exception 'Loan not found.';
  end if;
  if v_loan.status <> 'pending' then
    raise exception 'This loan has already been processed and cannot be reviewed again.';
  end if;

  if p_decision = 'approved' then
    v_total := v_loan.amount + coalesce(v_loan.admin_charge, 0);
    update loans set
      status = 'approved',
      date_decision = current_date,
      balance = v_total,
      admin_charge_balance = 0,
      monthly_deduction = case when v_loan.duration > 0 then round(v_total / v_loan.duration) else v_total end,
      admin_monthly_deduction = 0,
      workflow_status = 'approved'
    where id = p_loan_id;

    insert into transactions (member_id, description, amount, type)
    values (v_loan.member_id,
      'Loan approved/disbursed — ' || p_loan_id || ' (total obligation includes applicable 10% commodity charge)',
      v_loan.amount, 'loan');
  elsif p_decision = 'declined' then
    update loans set
      status = 'declined',
      date_decision = current_date,
      decline_reason = coalesce(p_reason, 'Not specified.'),
      workflow_status = 'declined'
    where id = p_loan_id;
  else
    raise exception 'Invalid decision.';
  end if;
end;
$$;

commit;

-- ---------------------------------------------------------
-- After running this file (on a from-scratch rebuild):
--   1. Promote members to Treasurer / President / Secretary from
--      admin.html -> Management Team -> "Assign a role to a member".
--   2. Then run, in order: migration_loan_financial_summary.sql,
--      migration_activity_log_and_issues.sql,
--      migration_manual_offset_workflow.sql (if used), and
--      migration_bursary_officer_role.sql.
-- ---------------------------------------------------------
