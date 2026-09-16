-- Sync manual admin edits with member transaction histories and allow safe cancellation.
alter table public.transactions add column if not exists cancelled_at timestamptz;
alter table public.transactions add column if not exists cancelled_by uuid references public.profiles(id);
alter table public.transactions add column if not exists cancel_reason text;

create or replace function public.edit_total_admin_charges(p_member_id uuid, p_new_amount numeric, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare v_previous numeric; v_delta numeric;
begin
  if not public.is_admin() then raise exception 'Only admins may edit a member''s admin charges.'; end if;
  if p_new_amount < 0 then raise exception 'Admin charges figure cannot be negative.'; end if;
  if p_reason is null or trim(p_reason) = '' then raise exception 'A reason is required for an admin charges correction.'; end if;
  select total_admin_charges into v_previous from profiles where id=p_member_id;
  if not found then raise exception 'Member not found.'; end if;
  v_delta := p_new_amount - v_previous;
  update profiles set total_admin_charges=p_new_amount where id=p_member_id;
  insert into admin_charge_adjustments(member_id,previous_amount,new_amount,reason,adjusted_by)
  values(p_member_id,v_previous,p_new_amount,p_reason,auth.uid());
  if v_delta <> 0 then
    insert into transactions(member_id,description,amount,type)
    values(p_member_id,'Manual administrative charge adjustment — '||p_reason,-v_delta,'admin_charge');
  end if;
end; $$;

create or replace function public.cancel_transaction(p_transaction_id uuid, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_tx transactions%rowtype;
begin
  if not public.is_admin() then raise exception 'Only admins may cancel transactions.'; end if;
  select * into v_tx from transactions where id=p_transaction_id for update;
  if not found then raise exception 'Transaction not found.'; end if;
  if v_tx.cancelled_at is not null then raise exception 'This transaction is already cancelled.'; end if;
  if v_tx.type='loan' then raise exception 'Loan repayment transactions cannot be cancelled here because they change loan balances. Use the loan reset/offset controls.'; end if;
  if v_tx.type='savings' then
    update profiles set savings_balance=greatest(0,savings_balance-v_tx.amount) where id=v_tx.member_id;
  elsif v_tx.type='admin_charge' then
    update profiles set total_admin_charges=greatest(0,total_admin_charges+v_tx.amount) where id=v_tx.member_id;
  end if;
  update transactions set cancelled_at=now(),cancelled_by=auth.uid(),cancel_reason=nullif(trim(coalesce(p_reason,'')), '') where id=p_transaction_id;
end; $$;

-- Cancel several transactions in one call (used by the "Cancel all" button
-- so the admin doesn't have to click Cancel on every row one at a time).
-- Each id is processed independently — if one fails (already cancelled,
-- a loan row, etc.) the rest still go through, and the caller gets back
-- a per-row result to report to the admin.
create or replace function public.cancel_transactions_bulk(p_transaction_ids uuid[], p_reason text default null)
returns table(transaction_id uuid, processed boolean, message text)
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not public.is_admin() then raise exception 'Only admins may cancel transactions.'; end if;
  foreach v_id in array p_transaction_ids loop
    begin
      perform public.cancel_transaction(v_id, p_reason);
      transaction_id := v_id; processed := true; message := 'Cancelled';
    exception when others then
      transaction_id := v_id; processed := false; message := sqlerrm;
    end;
    return next;
  end loop;
end; $$;

-- Convenience wrapper: cancel every still-active, cancellable (non-loan)
-- transaction belonging to one member in a single call.
create or replace function public.cancel_all_member_transactions(p_member_id uuid, p_reason text default null)
returns table(transaction_id uuid, processed boolean, message text)
language plpgsql security definer set search_path = public as $$
declare v_ids uuid[];
begin
  if not public.is_admin() then raise exception 'Only admins may cancel transactions.'; end if;
  select array_agg(id) into v_ids from transactions
    where member_id = p_member_id and cancelled_at is null and type <> 'loan';
  if v_ids is null then
    return;
  end if;
  return query select * from public.cancel_transactions_bulk(v_ids, p_reason);
end; $$;
