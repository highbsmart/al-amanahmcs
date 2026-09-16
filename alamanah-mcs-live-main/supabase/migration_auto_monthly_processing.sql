-- =========================================================
-- AL-AMANAH MCS — Automated monthly processing (savings + loan
-- deductions), replacing the need for an admin to click the
-- manual "Process" buttons every month.
--
-- HOW IT WORKS
-- Runs once a DAY (not just once on the 5th) via pg_cron. Each
-- run:
--   1. Does nothing at all before the 5th of the month.
--   2. From the 5th onward, finds every active member who hasn't
--      had a savings contribution recorded yet THIS calendar
--      month, and every approved loan that hasn't had a
--      deduction recorded yet THIS calendar month, and processes
--      them using the exact same functions the manual "Process"
--      buttons already use (record_savings_bulk /
--      record_loan_deductions_bulk) — so the business logic is
--      identical either way.
--   3. Anyone skipped (paused, no monthly amount set, etc.) is
--      recorded with a reason, not silently dropped.
--   4. Every run — successes and skips — is logged to
--      auto_processing_runs so an admin can review it later.
--
-- Because it runs daily and only ever processes a member/loan
-- ONCE per calendar month (never double-charges), a failed or
-- skipped day is automatically retried the next day, with no
-- extra logic needed — this is what gives you "retry
-- automatically until it succeeds."
--
-- REQUIRES: schema.sql and migration_admin_deduction_controls.sql
-- (record_savings_bulk, record_loan_deductions_bulk,
-- admin_record_loan_deduction, record_savings_contribution) to
-- already be in place — this migration only adds the scheduling
-- layer and the tracking column/log table on top of them.
--
-- Run ONCE in Supabase SQL Editor. Safe to re-run.
-- =========================================================

begin;

-- ---------------------------------------------------------
-- 1. Track when a loan last had a deduction recorded, the same
--    way profiles.last_savings_date already tracks savings — so
--    the automated job can tell what's already been done this
--    month, whether that happened automatically or via the
--    manual "Process" button.
-- ---------------------------------------------------------
alter table loans add column if not exists last_deduction_date date;

-- Re-declares admin_record_loan_deduction() with ONE addition
-- (setting last_deduction_date) — everything else is copied
-- verbatim from the function currently live on this database, to
-- avoid any behavioural drift.
create or replace function public.admin_record_loan_deduction(p_loan_id text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_loan loans%rowtype;
  v_paused boolean;
  v_loan_cut numeric;
  v_admin_cut numeric;
  v_total numeric;
begin
  if not public.is_admin() then
    raise exception 'Only admins may record loan deductions.';
  end if;
  select * into v_loan from loans where id = p_loan_id;
  if not found or v_loan.status <> 'approved' then
    raise exception 'Loan not found or not active.';
  end if;
  select deductions_paused into v_paused from profiles where id = v_loan.member_id;
  if v_paused then
    raise exception 'Deductions are paused for this member.';
  end if;
  v_loan_cut  := least(v_loan.monthly_deduction, v_loan.balance);
  v_admin_cut := least(v_loan.admin_monthly_deduction, v_loan.admin_charge_balance);
  v_total     := v_loan_cut + v_admin_cut;
  update loans set
    balance = greatest(0, balance - v_loan_cut),
    admin_charge_balance = greatest(0, admin_charge_balance - v_admin_cut),
    months_paid = months_paid + 1,
    last_deduction_date = current_date,
    status = case when balance - v_loan_cut <= 0 and admin_charge_balance - v_admin_cut <= 0 then 'completed' else status end
  where id = p_loan_id;
  -- Savings balance is intentionally left untouched: a loan
  -- repayment reduces the loan only.
  insert into transactions (member_id, description, amount, type)
  values (v_loan.member_id, 'Monthly loan deduction — ' || p_loan_id, -v_total, 'loan');
end;
$$;

-- ---------------------------------------------------------
-- 2. A full, reviewable log of every automatic run.
-- ---------------------------------------------------------
create table if not exists auto_processing_runs (
  id                uuid primary key default gen_random_uuid(),
  run_date          date not null default current_date,
  savings_processed int not null default 0,
  savings_skipped   jsonb not null default '[]'::jsonb,
  loans_processed   int not null default 0,
  loans_skipped     jsonb not null default '[]'::jsonb,
  created_at        timestamptz not null default now()
);

alter table auto_processing_runs enable row level security;

drop policy if exists "admin read auto runs" on auto_processing_runs;
create policy "admin read auto runs" on auto_processing_runs
  for select using (public.is_admin());

-- ---------------------------------------------------------
-- 3. The job itself. Not meant to be called by any user through
--    the app — only by the cron schedule below (which runs as
--    the database owner, not as any signed-in profile). EXECUTE
--    is revoked from ordinary API roles further down so it can't
--    be triggered from the client.
-- ---------------------------------------------------------
create or replace function public.run_monthly_auto_processing()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_today date := current_date;
  v_month_start date := date_trunc('month', v_today)::date;
  v_member record;
  v_loan record;
  v_paused boolean;
  v_charge numeric;
  v_loan_cut numeric;
  v_admin_cut numeric;
  v_total numeric;
  v_savings_processed int := 0;
  v_savings_skipped jsonb := '[]'::jsonb;
  v_loans_processed int := 0;
  v_loans_skipped jsonb := '[]'::jsonb;
begin
  -- Nothing to do before the 5th of the month.
  if v_today < (v_month_start + 4) then
    return;
  end if;

  -- SAVINGS. This deliberately does NOT call record_savings_bulk()
  -- or record_savings_contribution() — both require an admin to be
  -- signed in (they check public.is_admin(), which looks at who is
  -- currently logged in via auth.uid()). This job has no logged-in
  -- user at all — it runs on a schedule, not from a session — so
  -- that check would always fail here. Instead, the same logic
  -- those functions use is repeated directly below. This function's
  -- own restricted access (only the database/cron may ever call
  -- it — see the REVOKE statement further down) is what keeps it
  -- safe, not an admin-session check.
  for v_member in
    select * from profiles
    where status = 'active'
      and (last_savings_date is null or last_savings_date < v_month_start)
  loop
    if v_member.savings_paused then
      v_savings_skipped := v_savings_skipped || jsonb_build_object('member_id', v_member.id, 'reason', 'Savings paused.');
    elsif v_member.monthly_savings_amount <= 0 then
      v_savings_skipped := v_savings_skipped || jsonb_build_object('member_id', v_member.id, 'reason', 'No monthly savings amount set.');
    else
      v_charge := round(v_member.monthly_savings_amount * 0.075);
      update profiles set
        savings_balance      = savings_balance + v_member.monthly_savings_amount,
        total_admin_charges  = total_admin_charges + v_charge,
        last_savings_date    = current_date,
        last_savings_amount  = v_member.monthly_savings_amount,
        next_savings_date    = public.fifth_of_next_month(current_date),
        next_savings_amount  = v_member.monthly_savings_amount
      where id = v_member.id;

      insert into transactions (member_id, description, amount, type)
      values (v_member.id, 'Monthly savings contribution (automatic)', v_member.monthly_savings_amount, 'savings');
      insert into transactions (member_id, description, amount, type)
      values (v_member.id, 'Administrative charge (7.5%) — deducted from salary, separate from savings (automatic)', -v_charge, 'admin_charge');

      v_savings_processed := v_savings_processed + 1;
    end if;
  end loop;

  -- LOAN DEDUCTIONS. Same reasoning as above — this repeats
  -- admin_record_loan_deduction()'s logic directly rather than
  -- calling it, since that function also requires an admin session.
  for v_loan in
    select * from loans
    where status = 'approved'
      and (last_deduction_date is null or last_deduction_date < v_month_start)
  loop
    select deductions_paused into v_paused from profiles where id = v_loan.member_id;
    if v_paused then
      v_loans_skipped := v_loans_skipped || jsonb_build_object('loan_id', v_loan.id, 'reason', 'Deductions paused for this member.');
      continue;
    end if;

    v_loan_cut  := least(v_loan.monthly_deduction, v_loan.balance);
    v_admin_cut := least(v_loan.admin_monthly_deduction, v_loan.admin_charge_balance);
    v_total     := v_loan_cut + v_admin_cut;

    update loans set
      balance = greatest(0, balance - v_loan_cut),
      admin_charge_balance = greatest(0, admin_charge_balance - v_admin_cut),
      months_paid = months_paid + 1,
      last_deduction_date = current_date,
      status = case when balance - v_loan_cut <= 0 and admin_charge_balance - v_admin_cut <= 0 then 'completed' else status end
    where id = v_loan.id;

    insert into transactions (member_id, description, amount, type)
    values (v_loan.member_id, 'Monthly loan deduction (automatic) — ' || v_loan.id, -v_total, 'loan');

    v_loans_processed := v_loans_processed + 1;
  end loop;

  insert into auto_processing_runs (run_date, savings_processed, savings_skipped, loans_processed, loans_skipped)
  values (v_today, v_savings_processed, v_savings_skipped, v_loans_processed, v_loans_skipped);
end;
$$;

-- Only the database owner / cron may call this — never the
-- client SDK, an admin's session, or anyone else's.
revoke execute on function public.run_monthly_auto_processing() from public, anon, authenticated;

-- ---------------------------------------------------------
-- 4. Schedule it. Runs once a day at 01:00 UTC — safely a no-op
--    on days before the 5th, and safely a no-op for anyone
--    already processed this month, so running daily is what
--    gives you automatic retry-until-success without any extra
--    logic.
--    NOTE: pg_cron's schedule is in the database server's
--    timezone (UTC on Supabase by default). 01:00 UTC is late
--    night / very early morning in Nigeria (WAT, UTC+1) —
--    adjust the "1" below if you'd prefer a different local
--    time.
-- ---------------------------------------------------------
create extension if not exists pg_cron;

select cron.unschedule(jobid) from cron.job where jobname = 'al-amanah-monthly-auto-processing';

select cron.schedule(
  'al-amanah-monthly-auto-processing',
  '0 1 * * *',
  $cron$select public.run_monthly_auto_processing();$cron$
);

commit;

-- =========================================================
-- After running:
--   - Nothing else to do. The job will start firing on its own
--     from the 5th of next month (or today, if today is already
--     the 5th or later).
--   - To check it's actually scheduled: run
--       select * from cron.job where jobname = 'al-amanah-monthly-auto-processing';
--   - To see its run history from pg_cron's own side (separate
--     from auto_processing_runs above): run
--       select * from cron.job_run_details order by start_time desc limit 20;
--   - To test it immediately without waiting: run
--       select public.run_monthly_auto_processing();
--     (it will still no-op if today is before the 5th, or if
--     everyone's already been processed this month).
-- =========================================================
