-- =========================================================
-- MIGRATION: admin can clear (archive) a member's history
-- Run this once in Supabase SQL Editor, after the other
-- migrations, including migration_transaction_sync_cancel.sql.
-- Safe to re-run.
--
-- HOW THIS IS DIFFERENT FROM "CANCEL"
-- ------------------------------------
-- Cancelling a transaction (see migration_transaction_sync_cancel.sql)
-- REVERSES its effect on the member's savings/admin-charge balance —
-- it's for correcting a wrongly entered figure, and the entry stays
-- visible (struck through, marked "Cancelled") for the audit trail.
--
-- Clearing is different: it does NOT touch any balance. It simply
-- removes an entry from what the member can see — their savings
-- history, loan history, and payslip — with zero visible trace, no
-- "Cancelled by admin" label, nothing. The money already moved and
-- stays moved; this only tidies up what the member is shown.
--
-- Nothing is ever hard-deleted by clearing alone. A cleared row moves
-- into the admin-only "Cleared/Archived Records" list, where the
-- admin can Restore it (member sees it again, exactly as before) or
-- Permanently Delete it (irreversible, only allowed once it's already
-- cleared).
-- =========================================================

alter table public.transactions add column if not exists cleared_at timestamptz;
alter table public.transactions add column if not exists cleared_by uuid references public.profiles(id);
alter table public.transactions add column if not exists clear_reason text;

-- ---------------------------------------------------------
-- Clear one transaction (hide it from the member; no balance change).
-- ---------------------------------------------------------
create or replace function public.admin_clear_transaction(p_transaction_id uuid, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_tx transactions%rowtype;
begin
  if not public.is_admin() then raise exception 'Only admins may clear a record.'; end if;
  select * into v_tx from transactions where id = p_transaction_id for update;
  if not found then raise exception 'Transaction not found.'; end if;
  if v_tx.cleared_at is not null then raise exception 'This record is already cleared.'; end if;
  update transactions set
    cleared_at = now(),
    cleared_by = auth.uid(),
    clear_reason = nullif(trim(coalesce(p_reason, '')), '')
  where id = p_transaction_id;
end; $$;

-- Restore a cleared transaction — the member sees it again exactly as
-- it was. No balance change (clearing never changed one).
create or replace function public.admin_restore_transaction(p_transaction_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_tx transactions%rowtype;
begin
  if not public.is_admin() then raise exception 'Only admins may restore a record.'; end if;
  select * into v_tx from transactions where id = p_transaction_id for update;
  if not found then raise exception 'Transaction not found.'; end if;
  if v_tx.cleared_at is null then raise exception 'This record is not cleared.'; end if;
  update transactions set cleared_at = null, cleared_by = null, clear_reason = null where id = p_transaction_id;
end; $$;

-- Permanently delete a transaction — only ever allowed once it has
-- already been cleared, as a safety gate against deleting live data
-- by accident. Irreversible.
create or replace function public.admin_delete_transaction_permanently(p_transaction_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_tx transactions%rowtype;
begin
  if not public.is_admin() then raise exception 'Only admins may permanently delete a record.'; end if;
  select * into v_tx from transactions where id = p_transaction_id for update;
  if not found then raise exception 'Transaction not found.'; end if;
  if v_tx.cleared_at is null then raise exception 'Clear this record first before permanently deleting it.'; end if;
  delete from transactions where id = p_transaction_id;
end; $$;

-- Clear every not-yet-cleared transaction of one category for a member
-- in a single call. p_category: 'savings' | 'admin_charge' | 'loan' | 'all'.
create or replace function public.admin_clear_member_history(p_member_id uuid, p_category text, p_reason text default null)
returns table(transaction_id uuid, processed boolean, message text)
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not public.is_admin() then raise exception 'Only admins may clear history.'; end if;
  if p_category not in ('savings','admin_charge','loan','all') then
    raise exception 'Unknown history category: %', p_category;
  end if;
  for v_id in
    select id from transactions
      where member_id = p_member_id
        and cleared_at is null
        and (p_category = 'all' or type = p_category)
  loop
    begin
      perform public.admin_clear_transaction(v_id, p_reason);
      transaction_id := v_id; processed := true; message := 'Cleared';
    exception when others then
      transaction_id := v_id; processed := false; message := sqlerrm;
    end;
    return next;
  end loop;
end; $$;

-- "Clear Payslip History": remove every saved payslip override for a
-- member, so every month reverts to the standard, live-calculated
-- payslip. Overrides aren't soft-archived (they are just admin
-- shortcuts, not financial records), so this is a direct delete —
-- consistent with admin_delete_payslip_override already being a
-- direct delete for a single month.
create or replace function public.admin_clear_payslip_history(p_member_id uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare v_count integer;
begin
  if not public.is_admin() then raise exception 'Only admins may clear payslip history.'; end if;
  delete from payslip_overrides where member_id = p_member_id;
  get diagnostics v_count = row_count;
  return v_count;
end; $$;
