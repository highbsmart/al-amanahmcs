-- =========================================================
-- MIGRATION: permanently delete loans, and bulk-delete "all
-- at once" for both loans and cleared/archived transactions.
-- Run this once in Supabase SQL Editor, after every other
-- migration (including migration_clear_history.sql and
-- migration_manual_offset_workflow.sql). Safe to re-run.
--
-- WHAT THIS ADDS
-- ---------------
-- 1. admin_delete_loan_permanently(loan_id)
--    Irreversibly deletes ONE loan record, plus the loan-type
--    transaction log entries tied to it (they carry the loan id
--    in their description, e.g. "... — LN-78120503") and any
--    manual/Paystack offset-request line items that reference it
--    (loan_offset_request_items has a foreign key on loan_id —
--    deleting the loan without clearing these first fails with
--    "violates foreign key constraint
--    loan_offset_request_items_loan_id_fkey"). Only allowed once
--    the loan is no longer active — declined, offset, or
--    completed — as a safety gate against deleting a loan a
--    member still owes money on.
--
-- 2. admin_delete_all_loans_permanently(member_id)
--    Runs (1) for every one of a member's loans that is already
--    in a terminal state (declined/offset/completed). Backs the
--    "Delete All Permanently" button on the Loans view. Any
--    loan that is still pending/approved is left untouched and
--    reported back as skipped.
--
-- 3. admin_delete_all_cleared_transactions(member_id)
--    Permanently deletes every transaction already sitting in a
--    member's Cleared/Archived Records (i.e. cleared_at is not
--    null). Backs the "Delete All Permanently" button on the
--    Cleared/Archived Records table — the single-record version,
--    admin_delete_transaction_permanently, already exists from
--    migration_clear_history.sql; this is the bulk companion.
--
-- 4. admin_delete_offset_request_permanently(request_id)
--    Permanently deletes one row from a member's "Loan Offset
--    History" (loan_offset_requests, plus its line items in
--    loan_offset_request_items). No status gate — a pending/
--    in-progress request can be deleted too, at the admin's
--    discretion.
--
-- 5. admin_delete_all_offset_requests_for_member(member_id)
--    Runs (4) for every offset request a member has. Backs the
--    "Delete All Permanently" button on the Loan Offset History
--    section of the Member Details modal.
-- =========================================================

-- ---------------------------------------------------------
-- 1. Permanently delete one loan (terminal states only).
-- ---------------------------------------------------------
create or replace function public.admin_delete_loan_permanently(p_loan_id text)
returns void language plpgsql security definer set search_path = public as $$
declare v_loan loans%rowtype;
begin
  if not public.is_admin() then raise exception 'Only admins may permanently delete a loan.'; end if;
  select * into v_loan from loans where id = p_loan_id for update;
  if not found then raise exception 'Loan not found.'; end if;
  if v_loan.status not in ('declined','offset','completed') then
    raise exception 'Only a declined, offset, or completed loan can be permanently deleted.';
  end if;
  -- Clear any offset-request line items pointing at this loan first —
  -- loan_offset_request_items.loan_id is a foreign key into loans, so
  -- the loan can't be deleted while one of these still references it.
  -- Only present on projects that have run
  -- migration_manual_offset_workflow.sql (or its stage1/stage2a
  -- predecessors), hence the existence check.
  if to_regclass('public.loan_offset_request_items') is not null then
    delete from loan_offset_request_items where loan_id = p_loan_id;
  end if;
  -- Loans are linked to their log entries by id inside the description
  -- text rather than a foreign key, so clean those up too.
  delete from transactions
    where member_id = v_loan.member_id
      and type = 'loan'
      and description like '%' || p_loan_id || '%';
  delete from loans where id = p_loan_id;
end; $$;

-- ---------------------------------------------------------
-- 2. Permanently delete every eligible (terminal-state) loan
--    for a member in one call.
-- ---------------------------------------------------------
create or replace function public.admin_delete_all_loans_permanently(p_member_id uuid)
returns table(loan_id text, processed boolean, message text)
language plpgsql security definer set search_path = public as $$
declare v_id text;
begin
  if not public.is_admin() then raise exception 'Only admins may permanently delete loans.'; end if;
  for v_id in
    select id from loans
      where member_id = p_member_id
        and status in ('declined','offset','completed')
  loop
    begin
      perform public.admin_delete_loan_permanently(v_id);
      loan_id := v_id; processed := true; message := 'Deleted';
    exception when others then
      loan_id := v_id; processed := false; message := sqlerrm;
    end;
    return next;
  end loop;
end; $$;

-- ---------------------------------------------------------
-- 3. Permanently delete every already-cleared transaction for
--    a member in one call ("Delete All Permanently" on the
--    Cleared/Archived Records table).
-- ---------------------------------------------------------
create or replace function public.admin_delete_all_cleared_transactions(p_member_id uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare v_count integer;
begin
  if not public.is_admin() then raise exception 'Only admins may permanently delete records.'; end if;
  delete from transactions where member_id = p_member_id and cleared_at is not null;
  get diagnostics v_count = row_count;
  return v_count;
end; $$;

-- ---------------------------------------------------------
-- 4. Permanently delete ONE loan offset request (a row in the
--    member-facing "Loan Offset History" table) — its line items
--    are deleted first, then the request itself. No status gate:
--    admins may delete a pending/in-progress request as well as a
--    completed one, at their own discretion.
-- ---------------------------------------------------------
create or replace function public.admin_delete_offset_request_permanently(p_request_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Only admins may permanently delete offset history.'; end if;
  if not exists (select 1 from loan_offset_requests where id = p_request_id) then
    raise exception 'Offset request not found.';
  end if;
  delete from loan_offset_request_items where offset_request_id = p_request_id;
  delete from loan_offset_requests where id = p_request_id;
end; $$;

-- ---------------------------------------------------------
-- 5. Permanently delete EVERY offset request for a member in one
--    call — backs "Delete All Permanently" on the Loan Offset
--    History section of the Member Details modal.
-- ---------------------------------------------------------
create or replace function public.admin_delete_all_offset_requests_for_member(p_member_id uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare v_count integer;
begin
  if not public.is_admin() then raise exception 'Only admins may permanently delete offset history.'; end if;
  delete from loan_offset_request_items
    where offset_request_id in (select id from loan_offset_requests where member_id = p_member_id);
  delete from loan_offset_requests where member_id = p_member_id;
  get diagnostics v_count = row_count;
  return v_count;
end; $$;
