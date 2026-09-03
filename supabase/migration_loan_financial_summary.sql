-- =========================================================
-- AL-AMANAH MCS — Loan workflow, part 3 (Step 8, database half)
-- Adds a read-only "financial summary" function so the Treasurer
-- portal can SHOW a member's financial position before an
-- assessment is submitted (not just capture it afterward).
--
-- REQUIRES step 5 and steps 6&7 to already be run.
--
-- Run this once in Supabase: SQL Editor -> New query -> paste ->
-- Run. Safe to re-run.
-- =========================================================

begin;

-- Anyone on the management team (Treasurer/President/Secretary/
-- Super Admin) can call this to preview a loan's financial
-- picture. Read-only — makes no changes.
create or replace function public.get_loan_financial_summary(p_loan_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_loan loans%rowtype;
  v_profile profiles%rowtype;
  v_active_deductions numeric;
  v_projected_deduction numeric;
begin
  if not (public.is_treasurer() or public.is_president() or public.is_secretary() or public.is_admin()) then
    raise exception 'Not authorized.';
  end if;

  select * into v_loan from loans where id = p_loan_id;
  if not found then raise exception 'Loan not found.'; end if;

  select * into v_profile from profiles where id = v_loan.member_id;

  select coalesce(sum(monthly_deduction), 0) into v_active_deductions
  from loans
  where member_id = v_loan.member_id and status = 'approved' and id <> p_loan_id;

  v_projected_deduction := case when v_loan.duration > 0
    then round((v_loan.amount + coalesce(v_loan.admin_charge, 0)) / v_loan.duration)
    else v_loan.amount + coalesce(v_loan.admin_charge, 0)
  end;

  return jsonb_build_object(
    'member_name', v_profile.first_name || ' ' || v_profile.surname,
    'alamanah_no', v_profile.alamanah_no,
    'loan_type', v_loan.type,
    'amount', v_loan.amount,
    'duration', v_loan.duration,
    'purpose', v_loan.purpose,
    'savings_balance', v_profile.savings_balance,
    'monthly_savings', v_profile.monthly_savings_amount,
    'admin_charge', v_profile.total_admin_charges,
    'active_loan_deductions', v_active_deductions,
    'projected_new_deduction', v_projected_deduction
  );
end;
$$;

-- Refactor submit_treasurer_assessment to reuse the function above
-- instead of recomputing the same numbers a second way. Behavior
-- is identical to before — this only removes duplicated logic so
-- the preview the Treasurer sees always matches what gets saved.
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
    update loans set workflow_status = 'awaiting_president' where id = p_loan_id;
  else
    update loans set workflow_status = 'on_hold' where id = p_loan_id;
  end if;
end;
$$;

commit;
