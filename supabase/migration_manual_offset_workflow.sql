-- =========================================================
-- AL-AMANAH MCS — Manual / Offline Offset Payments
--
-- Adds a second way for a loan to get offset, alongside the
-- existing Paystack flow:
--
--   MEMBER requests an offset from their dashboard, choosing
--   "pay directly to the cooperative" instead of Paystack.
--        ↓
--   TREASURER sees it in a queue, confirms the money actually
--   arrived (bank transfer, cash, etc.), and that one action
--   closes the loan — same result as a completed Paystack
--   payment, just without Paystack involved at all.
--
-- Also retrofits the EXISTING one-click "offset a loan" button
-- Super Admin already has (in admin.html) so it now produces the
-- same printable receipt and offset letter as everything else,
-- instead of just silently closing the loan with no paper trail.
--
-- REQUIRES migration_loan_offset_stage1.sql and stage2a.sql
-- already run.
--
-- Run this once in Supabase: SQL Editor -> New query -> paste ->
-- Run. Safe to re-run.
-- =========================================================

begin;

-- ---------------------------------------------------------
-- 1. Track HOW a request is being paid, and who confirmed it
--    if it wasn't Paystack.
-- ---------------------------------------------------------
alter table loan_offset_requests
  add column if not exists payment_method text not null default 'paystack'
    check (payment_method in ('paystack', 'manual', 'manual_admin'));
alter table loan_offset_requests add column if not exists confirmed_by uuid references profiles(id);
alter table loan_offset_requests add column if not exists manual_confirmation_note text;

-- ---------------------------------------------------------
-- 2. The Treasurer now also needs to see offset requests (to
--    find the ones awaiting their confirmation), not just
--    President/Secretary/Super Admin as before.
-- ---------------------------------------------------------
drop policy if exists "management reads all offset requests" on loan_offset_requests;
create policy "management reads all offset requests" on loan_offset_requests
  for select using (public.is_admin() or public.is_treasurer() or public.is_president() or public.is_secretary());

drop policy if exists "management reads all offset items" on loan_offset_request_items;
create policy "management reads all offset items" on loan_offset_request_items
  for select using (public.is_admin() or public.is_treasurer() or public.is_president() or public.is_secretary());

-- ---------------------------------------------------------
-- 3. create_offset_request now accepts a payment method.
--    Existing calls with just the loan list still work exactly
--    as before (defaults to 'paystack') — nothing about the
--    online payment flow changes.
-- ---------------------------------------------------------
create or replace function public.create_offset_request(p_loan_ids text[], p_payment_method text default 'paystack')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_member_id uuid := auth.uid();
  v_request_id uuid;
  v_reference text;
  v_total numeric := 0;
  v_loan loans%rowtype;
begin
  if v_member_id is null then
    raise exception 'You must be logged in to request an offset.';
  end if;

  if p_payment_method not in ('paystack', 'manual') then
    raise exception 'Invalid payment method.';
  end if;

  if p_loan_ids is null or array_length(p_loan_ids, 1) is null then
    raise exception 'Select at least one loan to offset.';
  end if;

  v_reference := 'ALM-OFS-' || to_char(now(), 'YYYYMMDDHH24MISS') || '-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 6);

  insert into loan_offset_requests (member_id, request_reference, total_amount, payment_method)
  values (v_member_id, v_reference, 0, p_payment_method)
  returning id into v_request_id;

  for v_loan in
    select * from loans
    where id = any(p_loan_ids) and member_id = v_member_id and status = 'approved'
  loop
    if coalesce(v_loan.balance, 0) <= 0 then
      continue;
    end if;

    insert into loan_offset_request_items (offset_request_id, loan_id, loan_type, outstanding_balance_snapshot, amount_to_offset)
    values (v_request_id, v_loan.id, v_loan.type, v_loan.balance, v_loan.balance);

    v_total := v_total + v_loan.balance;
  end loop;

  if v_total <= 0 then
    delete from loan_offset_requests where id = v_request_id;
    raise exception 'None of the selected loans have an outstanding balance eligible for offset.';
  end if;

  update loan_offset_requests set total_amount = v_total where id = v_request_id;

  return jsonb_build_object(
    'offset_request_id', v_request_id,
    'request_reference', v_reference,
    'total_amount', v_total
  );
end;
$$;

-- ---------------------------------------------------------
-- 4. confirm_manual_offset_payment() — the Treasurer's one
--    action that closes a manually-paid offset request. Reuses
--    complete_loan_offset() (the exact same function Paystack
--    uses) so a manually-confirmed loan closes out identically
--    to an online one — same balance logic, same idempotency
--    protection, same audit trail.
-- ---------------------------------------------------------
create or replace function public.confirm_manual_offset_payment(p_offset_request_id uuid, p_confirmation_note text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_request loan_offset_requests%rowtype;
begin
  if not public.is_treasurer() then
    raise exception 'Only the Treasurer may confirm a manually-paid offset.';
  end if;

  select * into v_request from loan_offset_requests where id = p_offset_request_id for update;
  if not found then raise exception 'Offset request not found.'; end if;

  if v_request.payment_method <> 'manual' then
    raise exception 'This request is not a manual/offline payment.';
  end if;

  if v_request.payment_status <> 'pending' then
    raise exception 'This request has already been processed.';
  end if;

  if coalesce(trim(p_confirmation_note), '') = '' then
    raise exception 'Please note how the payment was received (e.g. bank transfer reference, date).';
  end if;

  update loan_offset_requests
  set payment_status = 'paid',
      paid_at = now(),
      confirmed_by = auth.uid(),
      manual_confirmation_note = p_confirmation_note
  where id = p_offset_request_id;

  perform public.complete_loan_offset(v_request.request_reference);
end;
$$;

-- ---------------------------------------------------------
-- 5. offset_loan() (Super Admin's existing one-click action)
--    now also creates a completed offset-request record behind
--    the scenes, so the member gets a receipt and offset letter
--    for it too — same as every other way a loan can be closed.
--    The loan-closing behavior itself is UNCHANGED.
-- ---------------------------------------------------------
create or replace function public.offset_loan(p_loan_id text, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_loan loans%rowtype;
  v_reference text;
  v_request_id uuid;
begin
  if not public.is_admin() then raise exception 'Only admins may offset loans.'; end if;
  select * into v_loan from loans where id = p_loan_id for update;
  if not found or v_loan.status <> 'approved' then raise exception 'Only an active loan can be offset.'; end if;

  update loans set status='offset', balance=0, admin_charge_balance=0, date_decision=current_date,
    decline_reason=coalesce(p_reason, 'Loan offset by administrator.') where id=p_loan_id;
  insert into transactions (member_id, description, amount, type)
  values (v_loan.member_id, 'Loan offset/closed — ' || p_loan_id || case when p_reason is null then '' else ': '||p_reason end, 0, 'loan');

  -- New: record this the same way every other offset path does,
  -- already marked complete, so it shows up in the member's Loan
  -- Offset History with a working receipt and offset letter.
  v_reference := 'ALM-OFS-' || to_char(now(), 'YYYYMMDDHH24MISS') || '-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 6);

  insert into loan_offset_requests (member_id, request_reference, total_amount, payment_method, payment_status, offset_status, paid_at, verified_at, completed_at, confirmed_by, manual_confirmation_note)
  values (v_loan.member_id, v_reference, v_loan.balance, 'manual_admin', 'paid', 'completed', now(), now(), now(), auth.uid(), coalesce(p_reason, 'Loan offset by administrator.'))
  returning id into v_request_id;

  insert into loan_offset_request_items (offset_request_id, loan_id, loan_type, outstanding_balance_snapshot, amount_to_offset)
  values (v_request_id, v_loan.id, v_loan.type, v_loan.balance, v_loan.balance);
end;
$$;

commit;
