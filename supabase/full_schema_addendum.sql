-- =====================================================================
-- AL-AMANAH MCS — FULL SCHEMA ADDENDUM
--
-- This file consolidates every ad-hoc "RUN THIS NOW" SQL script given
-- during the development session, in the EXACT chronological order
-- they were actually run against the live database. Running this file
-- top-to-bottom on a fresh copy of the base schema (schema.sql +
-- the other supabase/migration_*.sql files already in this repo)
-- reproduces the current live database state.
--
-- This exists because those fixes were delivered as standalone files
-- and applied directly in Supabase's SQL Editor — never folded back
-- into this repo's committed migration files. Without this addendum,
-- the repo alone does NOT describe the live database: months of work
-- (loan guarantors, the SMS provider/cascade system, Secretary and
-- Treasurer tooling, delivery tracking) would be missing entirely.
--
-- Generated automatically from the real files, in the real order.
-- =====================================================================


-- =====================================================================
-- SOURCE: RUN THIS NOW sms channel fallback.sql
-- =====================================================================
-- =====================================================================
-- SMS CHANNEL FIX: proper dnd (transactional) sending + manual fallback
-- Safe to run anytime. Only touches SMS-sending, nothing financial.
-- =====================================================================

-- 1. Track which Termii route (dnd/generic) was actually used for each
--    message, so you can see it in notification_log and retry the other
--    one if a specific message never arrives.
alter table public.notification_log
  add column if not exists termii_channel text;

-- 2. Updated send function: sends transactional SMS via the 'dnd' route
--    by default (the correct route for real transactional alerts, per
--    Termii's own docs), but lets you override the channel if needed,
--    and records which channel was used.
create or replace function public.send_termii_sms(
  p_member_id uuid,
  p_phone text,
  p_message text,
  p_channel text default 'dnd'
)
returns void
language plpgsql
security definer
as $function$
declare
  v_base_url text := public.get_app_setting('termii_base_url');
  v_api_key  text := public.get_app_setting('termii_api_key');
  v_sender   text := public.get_app_setting('termii_sender_id');
  v_request_id bigint;
  v_phone text;
  v_channel text := coalesce(nullif(trim(p_channel), ''), 'dnd');
begin
  if v_channel not in ('dnd', 'generic', 'whatsapp') then
    raise exception 'Invalid SMS channel: %. Must be dnd, generic, or whatsapp.', v_channel;
  end if;

  if p_phone is null or trim(p_phone) = '' then
    insert into notification_log (member_id, channel, recipient, body, success, response, termii_channel)
    values (p_member_id, 'sms', p_phone, p_message, false, 'No phone number on file.', v_channel);
    return;
  end if;
  if v_base_url is null or v_api_key is null or v_sender is null then
    insert into notification_log (member_id, channel, recipient, body, success, response, termii_channel)
    values (p_member_id, 'sms', p_phone, p_message, false, 'Termii settings not configured (app_settings: termii_base_url / termii_api_key / termii_sender_id).', v_channel);
    return;
  end if;

  -- Termii requires international format (e.g. 2348130773569),
  -- not the local Nigerian format (e.g. 08130773569) members'
  -- phone numbers are stored in. Normalize automatically.
  v_phone := regexp_replace(p_phone, '[^0-9]', '', 'g');
  if left(v_phone, 1) = '0' then
    v_phone := '234' || substring(v_phone from 2);
  elsif left(v_phone, 3) <> '234' then
    v_phone := '234' || v_phone;
  end if;

  begin
    v_request_id := net.http_post(
      url := v_base_url || '/api/sms/send',
      headers := jsonb_build_object('Content-Type', 'application/json'),
      body := jsonb_build_object(
        'api_key', v_api_key,
        'to', v_phone,
        'from', v_sender,
        'sms', p_message,
        'type', 'plain',
        'channel', v_channel
      )
    );
    insert into notification_log (member_id, channel, recipient, body, success, response, termii_channel)
    values (p_member_id, 'sms', v_phone, p_message, true, 'Request queued via ' || v_channel || ' route (pg_net request id ' || v_request_id || ').', v_channel);
  exception when others then
    insert into notification_log (member_id, channel, recipient, body, success, response, termii_channel)
    values (p_member_id, 'sms', v_phone, p_message, false, sqlerrm, v_channel);
  end;
end;
$function$;

-- 3. Manual fallback: if an officer notices a specific SMS never
--    arrived, this resends the SAME message to the SAME member on
--    whichever channel it was NOT sent on the first time (dnd <-> generic).
--    Only Super Admins can trigger this.
create or replace function public.admin_resend_sms_alternate_channel(p_notification_log_id uuid)
returns void
language plpgsql
security definer
as $function$
declare
  v_log notification_log%rowtype;
  v_alt_channel text;
begin
  if not public.is_admin() then
    raise exception 'Only a Super Admin may resend a message on a different channel.';
  end if;

  select * into v_log from notification_log where id = p_notification_log_id;
  if not found then
    raise exception 'Notification log entry not found.';
  end if;
  if v_log.channel <> 'sms' then
    raise exception 'This function only resends SMS messages.';
  end if;

  v_alt_channel := case
    when coalesce(v_log.termii_channel, 'dnd') = 'dnd' then 'generic'
    else 'dnd'
  end;

  perform public.send_termii_sms(v_log.member_id, v_log.recipient, v_log.body, v_alt_channel);
end;
$function$;


-- =====================================================================
-- SOURCE: RUN THIS NOW drop old resend function.sql
-- =====================================================================
-- Removes the old (incorrect) bigint version of this function that was
-- created before the fix. Leaves the correct uuid version in place.
-- Safe to run anytime.
drop function if exists public.admin_resend_sms_alternate_channel(bigint);


-- =====================================================================
-- SOURCE: RUN THIS NOW resend statement sms.sql
-- =====================================================================
-- =====================================================================
-- Manual "resend this month's statement SMS" — lets a Super Admin
-- re-send the savings/loan SMS statement to a member (or many members
-- at once) on demand, independent of the automatic 5th-of-month run.
-- Composes the exact same message the automatic job sends, using each
-- member's CURRENT stored figures for this month — it does not create
-- any new transaction, charge, or deduction. Purely a notification.
-- Safe to run anytime.
-- =====================================================================

create or replace function public.admin_resend_statement_sms(
  p_member_id uuid,
  p_channel text default null
)
returns void
language plpgsql
security definer
as $function$
declare
  v_month_start date := date_trunc('month', current_date)::date;
  v_profile profiles%rowtype;
  v_loan_total numeric;
  v_total numeric;
  v_sms_message text;
begin
  if not public.is_admin() then
    raise exception 'Only a Super Admin may resend a statement SMS.';
  end if;

  select * into v_profile from profiles where id = p_member_id;
  if not found then
    raise exception 'Member not found.';
  end if;

  select coalesce(sum(monthly_deduction + admin_monthly_deduction), 0), coalesce(sum(balance), 0)
    into v_loan_total, v_total
  from loans
  where member_id = p_member_id
    and status in ('approved', 'completed')
    and last_deduction_date >= v_month_start;

  if v_profile.last_savings_date is not null and v_profile.last_savings_date >= v_month_start then
    v_sms_message := 'Al-Amanah MCS: Savings of NGN' || to_char(v_profile.last_savings_amount, 'FM999,999,999')
      || ' recorded. New balance: NGN' || to_char(v_profile.savings_balance, 'FM999,999,999')
      || case when v_loan_total > 0 then '. Loan deduction: NGN' || to_char(v_loan_total, 'FM999,999,999') || '. Outstanding: NGN' || to_char(v_total, 'FM999,999,999') else '' end
      || '. Thank you.';
  elsif v_loan_total > 0 then
    v_sms_message := 'Al-Amanah MCS: Loan deduction of NGN' || to_char(v_loan_total, 'FM999,999,999')
      || ' recorded. Outstanding balance: NGN' || to_char(v_total, 'FM999,999,999') || '. Thank you.';
  else
    raise exception 'No savings or loan deduction recorded for this member this month — nothing to resend.';
  end if;

  perform public.send_termii_sms(p_member_id, v_profile.phone, v_sms_message, p_channel);
end;
$function$;

-- Bulk version: pass an array of member ids (e.g. every active member,
-- or just a selected group). Skips members with nothing to resend
-- rather than failing the whole batch, and reports per-member status
-- back so the admin panel can show what happened.
create or replace function public.admin_resend_statement_sms_bulk(
  p_member_ids uuid[],
  p_channel text default null
)
returns table(member_id uuid, processed boolean, message text)
language plpgsql
security definer
as $function$
declare
  v_id uuid;
begin
  if not public.is_admin() then
    raise exception 'Only a Super Admin may resend statement SMS in bulk.';
  end if;

  foreach v_id in array p_member_ids loop
    begin
      perform public.admin_resend_statement_sms(v_id, p_channel);
      member_id := v_id; processed := true; message := 'Sent';
    exception when others then
      member_id := v_id; processed := false; message := sqlerrm;
    end;
    return next;
  end loop;
end;
$function$;


-- =====================================================================
-- SOURCE: RUN THIS NOW professional statement sms.sql
-- =====================================================================
-- =====================================================================
-- Professional statement SMS: breaks down Real / Commodity /
-- Humanitarian loan balances individually, then the total deduction
-- for the month — instead of one lumped "loan deduction" figure.
--
-- This introduces ONE shared function, compose_statement_sms_message(),
-- used by BOTH the automatic 5th-of-month job and the manual
-- "resend statement SMS" feature — so the two can never drift apart
-- again; there is only one place the wording lives.
--
-- Safe to run anytime. Does not touch any balance, transaction, or
-- deduction logic — purely how the SMS text is composed.
-- =====================================================================

-- 1. The shared message-composer. Returns null if the member has
--    genuinely nothing to report for the given month (no savings
--    contribution and no loan deduction) — callers should skip
--    sending in that case rather than send an empty statement.
create or replace function public.compose_statement_sms_message(
  p_member_id uuid,
  p_month_start date default date_trunc('month', current_date)::date
)
returns text
language plpgsql
security definer
as $function$
declare
  v_profile profiles%rowtype;
  v_month_total_deduction numeric;
  v_real_balance numeric;
  v_commodity_balance numeric;
  v_humanitarian_balance numeric;
  v_has_savings_this_month boolean;
  v_msg text;
begin
  select * into v_profile from profiles where id = p_member_id;
  if not found then
    raise exception 'Member not found.';
  end if;

  -- This month's total loan repayment (all loan types combined),
  -- whichever day in the month it was actually deducted.
  select coalesce(sum(monthly_deduction + admin_monthly_deduction), 0)
    into v_month_total_deduction
  from loans
  where member_id = p_member_id
    and status in ('approved', 'completed')
    and last_deduction_date >= p_month_start;

  -- Current OUTSTANDING balance per loan type — this is a running
  -- balance, not something that resets monthly, same as a real
  -- loan statement would show.
  select
    coalesce(sum(balance) filter (where type = 'real'), 0),
    coalesce(sum(balance) filter (where type = 'commodity'), 0),
    coalesce(sum(balance) filter (where type = 'humanitarian'), 0)
  into v_real_balance, v_commodity_balance, v_humanitarian_balance
  from loans
  where member_id = p_member_id
    and status = 'approved';

  v_has_savings_this_month := v_profile.last_savings_date is not null
    and v_profile.last_savings_date >= p_month_start;

  -- Nothing genuinely happened this month for this member — signal
  -- the caller to skip rather than send a statement with everything
  -- at zero.
  if not v_has_savings_this_month and v_month_total_deduction = 0 then
    return null;
  end if;

  v_msg := 'Al-Amanah MCS Statement - ' || to_char(p_month_start, 'FMMonth YYYY') || E'\n'
    || v_profile.first_name || ' ' || v_profile.surname || ' (' || v_profile.alamanah_no || ')' || E'\n';

  if v_has_savings_this_month then
    v_msg := v_msg || 'Savings: NGN' || to_char(v_profile.last_savings_amount, 'FM999,999,999')
      || ' contributed. Balance: NGN' || to_char(v_profile.savings_balance, 'FM999,999,999') || E'\n';
  else
    v_msg := v_msg || 'Savings Balance: NGN' || to_char(v_profile.savings_balance, 'FM999,999,999') || E'\n';
  end if;

  v_msg := v_msg
    || 'Loan Balances - Real: NGN' || to_char(v_real_balance, 'FM999,999,999')
    || ' | Commodity: NGN' || to_char(v_commodity_balance, 'FM999,999,999')
    || ' | Humanitarian: NGN' || to_char(v_humanitarian_balance, 'FM999,999,999') || E'\n';

  v_msg := v_msg || 'This Month''s Total Deduction: NGN' || to_char(v_month_total_deduction, 'FM999,999,999') || '. Thank you.';

  return v_msg;
end;
$function$;

-- 2. Update the automatic monthly job to use the shared composer for
--    BOTH notify loops (savings-day members, and loan-only-day
--    members) — so every member gets the identical professional
--    format regardless of which loop picked them up.
create or replace function public.run_monthly_auto_processing()
returns void
language plpgsql
security definer
as $function$
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
  v_notify record;
  v_month_label text := to_char(v_today, 'FMMonth YYYY');
  v_sms_message text;
begin
  if v_today < (v_month_start + 4) then
    return;
  end if;

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
      last_deduction_loan_cut = v_loan_cut,
      last_deduction_admin_cut = v_admin_cut,
      status = case when balance - v_loan_cut <= 0 and admin_charge_balance - v_admin_cut <= 0 then 'completed' else status end
    where id = v_loan.id;

    insert into transactions (member_id, description, amount, type)
    values (v_loan.member_id, 'Monthly loan deduction (automatic) — ' || v_loan.id, -v_total, 'loan');

    v_loans_processed := v_loans_processed + 1;
  end loop;

  insert into auto_processing_runs (run_date, savings_processed, savings_skipped, loans_processed, loans_skipped)
  values (v_today, v_savings_processed, v_savings_skipped, v_loans_processed, v_loans_skipped);

  for v_notify in
    select p.id, p.first_name, p.surname, p.phone, p.contact_email,
           p.savings_balance, p.last_savings_amount
    from profiles p
    where p.status = 'active' and p.last_savings_date = v_today
  loop
    v_sms_message := public.compose_statement_sms_message(v_notify.id, v_month_start);
    if v_sms_message is not null then
      perform public.send_termii_sms(v_notify.id, v_notify.phone, v_sms_message);
    end if;
    perform public.send_termii_email(v_notify.id, v_notify.contact_email,
      'Your Al-Amanah MCS Statement — ' || v_month_label,
      jsonb_build_object(
        'name', v_notify.first_name || ' ' || v_notify.surname,
        'month', v_month_label,
        'savings_amount', to_char(v_notify.last_savings_amount, 'FM999,999,999'),
        'savings_balance', to_char(v_notify.savings_balance, 'FM999,999,999')
      )
    );
  end loop;

  for v_notify in
    select distinct p.id, p.first_name, p.surname, p.phone, p.contact_email, p.savings_balance
    from profiles p
    join loans l on l.member_id = p.id
    where l.last_deduction_date = v_today
      and (p.last_savings_date is distinct from v_today)
  loop
    v_sms_message := public.compose_statement_sms_message(v_notify.id, v_month_start);
    if v_sms_message is not null then
      perform public.send_termii_sms(v_notify.id, v_notify.phone, v_sms_message);
    end if;
    perform public.send_termii_email(v_notify.id, v_notify.contact_email,
      'Your Al-Amanah MCS Statement — ' || v_month_label,
      jsonb_build_object(
        'name', v_notify.first_name || ' ' || v_notify.surname,
        'month', v_month_label,
        'savings_amount', '0',
        'savings_balance', to_char(v_notify.savings_balance, 'FM999,999,999')
      )
    );
  end loop;
end;
$function$;

-- 3. Update the manual "resend statement SMS" to use the exact same
--    shared composer, so a resend always matches what would have
--    gone out automatically.
create or replace function public.admin_resend_statement_sms(
  p_member_id uuid,
  p_channel text default null
)
returns void
language plpgsql
security definer
as $function$
declare
  v_profile profiles%rowtype;
  v_sms_message text;
begin
  if not public.is_admin() then
    raise exception 'Only a Super Admin may resend a statement SMS.';
  end if;

  select * into v_profile from profiles where id = p_member_id;
  if not found then
    raise exception 'Member not found.';
  end if;

  v_sms_message := public.compose_statement_sms_message(p_member_id);
  if v_sms_message is null then
    raise exception 'No savings or loan deduction recorded for this member this month — nothing to resend.';
  end if;

  perform public.send_termii_sms(p_member_id, v_profile.phone, v_sms_message, p_channel);
end;
$function$;


-- =====================================================================
-- SOURCE: RUN THIS NOW delivery status columns.sql
-- =====================================================================
-- =====================================================================
-- Adds columns to record Termii's REAL delivery status once their
-- webhook confirms it — separate from "success" (which only ever
-- meant "Termii accepted and charged the message").
-- Safe to run anytime. No existing data is touched.
-- =====================================================================

alter table public.notification_log
  add column if not exists delivery_status text,       -- e.g. 'DELIVERED', 'DND Active on Phone Number', 'Message Failed', 'Rejected', 'Expired'
  add column if not exists delivered_at timestamptz,    -- when the webhook told us the final status
  add column if not exists termii_message_id text;      -- Termii's own message id, from the webhook payload

comment on column public.notification_log.delivery_status is
  'Real delivery outcome reported by Termii''s webhook after the message reached (or failed to reach) the handset. Null until the webhook reports back.';


-- =====================================================================
-- SOURCE: RUN THIS NOW sms log delete functions.sql
-- =====================================================================
-- =====================================================================
-- Lets a Super Admin delete SMS log entries — one at a time, a
-- selected batch, or everything in a given status bucket (Delivered /
-- Pending / Failed) at once, to keep the log tidy.
--
-- There was previously no delete policy on notification_log at all
-- (only a read policy for admins), so deleting was impossible from the
-- client even for an admin. These functions go through the same
-- is_admin() gate as every other admin action in this app, rather than
-- opening up raw table-level delete access.
--
-- Safe to run anytime. This never touches savings, loans, or any
-- financial record — only the notification history.
-- =====================================================================

create or replace function public.admin_delete_notification_log_entries(p_ids uuid[])
returns integer
language plpgsql
security definer
as $function$
declare
  v_count integer;
begin
  if not public.is_admin() then
    raise exception 'Only a Super Admin may delete notification log entries.';
  end if;
  if p_ids is null or array_length(p_ids, 1) is null then
    return 0;
  end if;

  delete from notification_log where id = any(p_ids);
  get diagnostics v_count = row_count;
  return v_count;
end;
$function$;

-- Deletes every SMS log row matching one status bucket, using the
-- exact same classification the SMS Log screen uses:
--   'delivered' -> delivery_status starts with 'DELIVERED'
--   'failed'    -> send failed outright, OR the webhook reported
--                  anything other than delivered
--   'pending'   -> accepted by Termii, no webhook response yet
create or replace function public.admin_clear_notification_log_by_status(p_bucket text)
returns integer
language plpgsql
security definer
as $function$
declare
  v_count integer;
begin
  if not public.is_admin() then
    raise exception 'Only a Super Admin may clear notification log entries.';
  end if;
  if p_bucket not in ('delivered', 'pending', 'failed') then
    raise exception 'Invalid status bucket: %. Must be delivered, pending, or failed.', p_bucket;
  end if;

  if p_bucket = 'delivered' then
    delete from notification_log
      where channel = 'sms' and success = true and delivery_status ilike 'DELIVERED%';
  elsif p_bucket = 'pending' then
    delete from notification_log
      where channel = 'sms' and success = true and delivery_status is null;
  else -- failed
    delete from notification_log
      where channel = 'sms'
        and (success = false or (delivery_status is not null and delivery_status not ilike 'DELIVERED%'));
  end if;

  get diagnostics v_count = row_count;
  return v_count;
end;
$function$;


-- =====================================================================
-- SOURCE: RUN THIS NOW loan stage sms notifications.sql
-- =====================================================================
-- =====================================================================
-- Automatic SMS notifications for the loan approval chain.
--
-- Whenever a loan application moves into a stage that needs a
-- Bursary Officer, Treasurer, or President's attention, every active
-- officer holding that role (with a phone number on file) gets an
-- SMS telling them a review is waiting.
--
-- This is implemented as a single database trigger on the `loans`
-- table, rather than adding notification code inside each existing
-- workflow function — so it fires no matter how a loan enters that
-- stage (a brand-new application, a re-submission, a "returned for
-- more info", etc.), and there's only one place this logic lives.
--
-- Safe to run anytime. Does not touch any balance, decision, or
-- vetting logic — purely adds a notification side-effect.
-- =====================================================================

create or replace function public.notify_officers_of_loan_stage()
returns trigger
language plpgsql
security definer
as $function$
declare
  v_role text;
  v_reason text;
  v_profile profiles%rowtype;
  v_officer record;
  v_message text;
  v_notified_count int := 0;
begin
  -- Only fire on a genuine change of stage (an UPDATE that didn't
  -- actually change workflow_status is a no-op here).
  if TG_OP = 'UPDATE' and OLD.workflow_status is not distinct from NEW.workflow_status then
    return NEW;
  end if;

  case NEW.workflow_status
    when 'awaiting_bursary'     then v_role := 'bursary';   v_reason := 'is awaiting your Bursary review';
    when 'returned_to_bursary'  then v_role := 'bursary';   v_reason := 'has been returned to you for further Bursary review';
    when 'awaiting_treasurer'   then v_role := 'treasurer'; v_reason := 'has passed Bursary vetting and is awaiting your Treasurer assessment';
    when 'returned_to_treasurer' then v_role := 'treasurer'; v_reason := 'has been returned to you for Treasurer reassessment';
    when 'awaiting_president'   then v_role := 'president'; v_reason := 'has passed Treasurer assessment and is awaiting your decision as President';
    else v_role := null;
  end case;

  if v_role is null then
    return NEW;
  end if;

  select * into v_profile from profiles where id = NEW.member_id;

  v_message := 'Al-Amanah MCS: Loan application ' || NEW.id || ' for '
    || coalesce(v_profile.first_name || ' ' || v_profile.surname, 'a member')
    || ' (' || coalesce(v_profile.alamanah_no, '-') || ') — '
    || initcap(NEW.type) || ' loan, NGN' || to_char(NEW.amount, 'FM999,999,999')
    || ' — ' || v_reason || '. Please log in to review.';

  for v_officer in
    select id, phone from profiles
    where role = v_role and status = 'active' and phone is not null and trim(phone) <> ''
  loop
    perform public.send_termii_sms(v_officer.id, v_officer.phone, v_message);
    v_notified_count := v_notified_count + 1;
  end loop;

  return NEW;
end;
$function$;

drop trigger if exists trg_notify_officers_of_loan_stage on loans;
create trigger trg_notify_officers_of_loan_stage
  after insert or update of workflow_status on loans
  for each row execute function public.notify_officers_of_loan_stage();


-- =====================================================================
-- SOURCE: RUN THIS NOW fix send_termii_sms overload.sql
-- =====================================================================
-- Removes the OLD 3-argument version of send_termii_sms(uuid, text, text)
-- that got left behind when we added the optional p_channel parameter.
-- Having both the old 3-arg version and the new 4-arg version (with a
-- default) at the same time makes every 3-argument call ambiguous —
-- Postgres can't tell which one you meant. This leaves only the
-- correct 4-argument version in place.
-- Safe to run anytime.
drop function if exists public.send_termii_sms(uuid, text, text);


-- =====================================================================
-- SOURCE: RUN THIS NOW fix loan notification encoding.sql
-- =====================================================================
-- =====================================================================
-- Fixes the loan-review notification SMS to use only plain, standard
-- SMS-safe characters (GSM-7), matching the messages that already
-- work reliably (savings/loan deduction statements).
--
-- The previous version used a fancy em dash (—) instead of a plain
-- hyphen (-). That single character forces the ENTIRE message into
-- Unicode (UCS-2) encoding instead of the standard GSM-7 character
-- set, which:
--   1. Roughly triples the number of message segments needed (more
--      cost per send), and
--   2. Multi-part Unicode SMS is well known to be more likely to
--      arrive incomplete or get silently dropped by some networks —
--      unlike your working statement messages, which are pure
--      GSM-7-safe plain text.
--
-- This replaces the trigger function with an identical version, just
-- using a plain hyphen instead. Nothing else changes.
-- Safe to run anytime.
-- =====================================================================

create or replace function public.notify_officers_of_loan_stage()
returns trigger
language plpgsql
security definer
as $function$
declare
  v_role text;
  v_reason text;
  v_profile profiles%rowtype;
  v_officer record;
  v_message text;
  v_notified_count int := 0;
begin
  if TG_OP = 'UPDATE' and OLD.workflow_status is not distinct from NEW.workflow_status then
    return NEW;
  end if;

  case NEW.workflow_status
    when 'awaiting_bursary'     then v_role := 'bursary';   v_reason := 'is awaiting your Bursary review';
    when 'returned_to_bursary'  then v_role := 'bursary';   v_reason := 'has been returned to you for further Bursary review';
    when 'awaiting_treasurer'   then v_role := 'treasurer'; v_reason := 'has passed Bursary vetting and is awaiting your Treasurer assessment';
    when 'returned_to_treasurer' then v_role := 'treasurer'; v_reason := 'has been returned to you for Treasurer reassessment';
    when 'awaiting_president'   then v_role := 'president'; v_reason := 'has passed Treasurer assessment and is awaiting your decision as President';
    else v_role := null;
  end case;

  if v_role is null then
    return NEW;
  end if;

  select * into v_profile from profiles where id = NEW.member_id;

  v_message := 'Al-Amanah MCS: Loan application ' || NEW.id || ' for '
    || coalesce(v_profile.first_name || ' ' || v_profile.surname, 'a member')
    || ' (' || coalesce(v_profile.alamanah_no, '-') || ') - '
    || initcap(NEW.type) || ' loan, NGN' || to_char(NEW.amount, 'FM999,999,999')
    || ' - ' || v_reason || '. Please log in to review.';

  for v_officer in
    select id, phone from profiles
    where role = v_role and status = 'active' and phone is not null and trim(phone) <> ''
  loop
    perform public.send_termii_sms(v_officer.id, v_officer.phone, v_message);
    v_notified_count := v_notified_count + 1;
  end loop;

  return NEW;
end;
$function$;


-- =====================================================================
-- SOURCE: RUN THIS NOW dual sms provider setup.sql
-- =====================================================================
-- =====================================================================
-- DUAL SMS PROVIDER SETUP: Termii + BulkSMSNigeria
--
-- Adds BulkSMSNigeria as a second SMS provider, alongside Termii —
-- not replacing it. A single "smart" send function decides which
-- provider to use (controlled by one app_setting you can flip anytime),
-- and every message can be resent either:
--   (a) on the SAME provider's other route (like dnd <-> generic
--       already works for Termii, now also direct-corporate <->
--       direct-refund for BulkSMSNigeria), or
--   (b) via the OTHER PROVIDER ENTIRELY — the real point of having two.
--
-- This does NOT touch anything currently working. Termii keeps
-- functioning exactly as it does today unless you deliberately switch
-- the primary provider setting.
--
-- Safe to run anytime.
-- =====================================================================

-- 1. Track which provider sent each message, alongside the existing
--    "channel/route" column (termii_channel is reused generically for
--    BOTH providers' route names: dnd/generic for Termii,
--    direct-corporate/direct-refund for BulkSMSNigeria).
alter table public.notification_log
  add column if not exists sms_provider text not null default 'termii';

comment on column public.notification_log.sms_provider is
  'Which SMS provider actually sent this message: termii or bulksms.';

-- =====================================================================
-- 2. BulkSMSNigeria send function — mirrors send_termii_sms exactly in
--    structure and behavior, so it's a drop-in alternative.
--
--    Before this works, add these three settings (ask your BulkSMS
--    account dashboard for the exact values once your KYC is approved):
--      insert into app_settings (key, value) values
--        ('bulksms_base_url', 'https://www.bulksmsnigeria.com/api/v2/sms'),
--        ('bulksms_api_token', 'YOUR-TOKEN-HERE'),
--        ('bulksms_sender_id', 'YOUR-SENDER-ID-HERE')
--      on conflict (key) do update set value = excluded.value;
-- =====================================================================
create or replace function public.send_bulksms_sms(
  p_member_id uuid,
  p_phone text,
  p_message text,
  p_gateway text default 'direct-corporate'
)
returns void
language plpgsql
security definer
as $function$
declare
  v_base_url  text := public.get_app_setting('bulksms_base_url');
  v_api_token text := public.get_app_setting('bulksms_api_token');
  v_sender    text := public.get_app_setting('bulksms_sender_id');
  v_request_id bigint;
  v_phone text;
  v_gateway text := coalesce(nullif(trim(p_gateway), ''), 'direct-corporate');
begin
  if v_gateway not in ('direct-refund', 'direct-corporate', 'otp', 'dual-backup') then
    raise exception 'Invalid BulkSMSNigeria gateway: %. Must be direct-refund, direct-corporate, otp, or dual-backup.', v_gateway;
  end if;

  if p_phone is null or trim(p_phone) = '' then
    insert into notification_log (member_id, channel, recipient, body, success, response, termii_channel, sms_provider)
    values (p_member_id, 'sms', p_phone, p_message, false, 'No phone number on file.', v_gateway, 'bulksms');
    return;
  end if;
  if v_base_url is null or v_api_token is null or v_sender is null then
    insert into notification_log (member_id, channel, recipient, body, success, response, termii_channel, sms_provider)
    values (p_member_id, 'sms', p_phone, p_message, false, 'BulkSMSNigeria settings not configured yet (app_settings: bulksms_base_url / bulksms_api_token / bulksms_sender_id).', v_gateway, 'bulksms');
    return;
  end if;

  -- Same phone normalization as Termii, for consistency.
  v_phone := regexp_replace(p_phone, '[^0-9]', '', 'g');
  if left(v_phone, 1) = '0' then
    v_phone := '234' || substring(v_phone from 2);
  elsif left(v_phone, 3) <> '234' then
    v_phone := '234' || v_phone;
  end if;

  begin
    v_request_id := net.http_post(
      url := v_base_url,
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || v_api_token,
        'Accept', 'application/json'
      ),
      body := jsonb_build_object(
        'from', v_sender,
        'to', v_phone,
        'body', p_message,
        'gateway', v_gateway,
        'callback_url', public.get_app_setting('bulksms_webhook_url')
      )
    );
    insert into notification_log (member_id, channel, recipient, body, success, response, termii_channel, sms_provider)
    values (p_member_id, 'sms', v_phone, p_message, true, 'Request queued via BulkSMSNigeria (' || v_gateway || ') route (pg_net request id ' || v_request_id || ').', v_gateway, 'bulksms');
  exception when others then
    insert into notification_log (member_id, channel, recipient, body, success, response, termii_channel, sms_provider)
    values (p_member_id, 'sms', v_phone, p_message, false, sqlerrm, v_gateway, 'bulksms');
  end;
end;
$function$;

-- =====================================================================
-- 3. The "smart" dispatcher every part of the app should call from now
--    on, instead of calling send_termii_sms directly. It reads ONE
--    setting to decide which provider is primary right now:
--
--      insert into app_settings (key, value) values ('primary_sms_provider', 'termii')
--      on conflict (key) do update set value = excluded.value;
--
--    Change that single value to 'bulksms' any time you want to swap
--    which provider handles everything, with no code changes needed.
-- =====================================================================
create or replace function public.send_sms_smart(
  p_member_id uuid,
  p_phone text,
  p_message text
)
returns void
language plpgsql
security definer
as $function$
declare
  v_provider text := coalesce(public.get_app_setting('primary_sms_provider'), 'termii');
begin
  if v_provider = 'bulksms' then
    perform public.send_bulksms_sms(p_member_id, p_phone, p_message);
  else
    perform public.send_termii_sms(p_member_id, p_phone, p_message);
  end if;
end;
$function$;

-- =====================================================================
-- 4. Point every existing sender at the smart dispatcher, so switching
--    providers later needs no further code changes.
-- =====================================================================

-- 4a. Loan-stage officer notifications
create or replace function public.notify_officers_of_loan_stage()
returns trigger
language plpgsql
security definer
as $function$
declare
  v_role text;
  v_reason text;
  v_profile profiles%rowtype;
  v_officer record;
  v_message text;
begin
  if TG_OP = 'UPDATE' and OLD.workflow_status is not distinct from NEW.workflow_status then
    return NEW;
  end if;

  case NEW.workflow_status
    when 'awaiting_bursary'     then v_role := 'bursary';   v_reason := 'is awaiting your Bursary review';
    when 'returned_to_bursary'  then v_role := 'bursary';   v_reason := 'has been returned to you for further Bursary review';
    when 'awaiting_treasurer'   then v_role := 'treasurer'; v_reason := 'has passed Bursary vetting and is awaiting your Treasurer assessment';
    when 'returned_to_treasurer' then v_role := 'treasurer'; v_reason := 'has been returned to you for Treasurer reassessment';
    when 'awaiting_president'   then v_role := 'president'; v_reason := 'has passed Treasurer assessment and is awaiting your decision as President';
    else v_role := null;
  end case;

  if v_role is null then
    return NEW;
  end if;

  select * into v_profile from profiles where id = NEW.member_id;

  v_message := 'Al-Amanah MCS: Loan application ' || NEW.id || ' for '
    || coalesce(v_profile.first_name || ' ' || v_profile.surname, 'a member')
    || ' (' || coalesce(v_profile.alamanah_no, '-') || ') - '
    || initcap(NEW.type) || ' loan, NGN' || to_char(NEW.amount, 'FM999,999,999')
    || ' - ' || v_reason || '. Please log in to review.';

  for v_officer in
    select id, phone from profiles
    where role = v_role and status = 'active' and phone is not null and trim(phone) <> ''
  loop
    perform public.send_sms_smart(v_officer.id, v_officer.phone, v_message);
  end loop;

  return NEW;
end;
$function$;

-- 4b. Manual "resend this month's statement SMS"
create or replace function public.admin_resend_statement_sms(
  p_member_id uuid,
  p_channel text default null
)
returns void
language plpgsql
security definer
as $function$
declare
  v_profile profiles%rowtype;
  v_sms_message text;
  v_provider text := coalesce(public.get_app_setting('primary_sms_provider'), 'termii');
begin
  if not public.is_admin() then
    raise exception 'Only a Super Admin may resend a statement SMS.';
  end if;

  select * into v_profile from profiles where id = p_member_id;
  if not found then
    raise exception 'Member not found.';
  end if;

  v_sms_message := public.compose_statement_sms_message(p_member_id);
  if v_sms_message is null then
    raise exception 'No savings or loan deduction recorded for this member this month — nothing to resend.';
  end if;

  -- If an explicit channel/route override was given, honor it on
  -- whichever provider is currently primary; otherwise use the smart
  -- default for that provider.
  if p_channel is not null then
    if v_provider = 'bulksms' then
      perform public.send_bulksms_sms(p_member_id, v_profile.phone, v_sms_message, p_channel);
    else
      perform public.send_termii_sms(p_member_id, v_profile.phone, v_sms_message, p_channel);
    end if;
  else
    perform public.send_sms_smart(p_member_id, v_profile.phone, v_sms_message);
  end if;
end;
$function$;

-- =====================================================================
-- 5. Resend controls — TWO distinct actions per message now:
--    (a) same provider, other route  (b) the other provider entirely
-- =====================================================================

-- (a) Same provider, alternate route — now handles BOTH providers.
create or replace function public.admin_resend_sms_alternate_channel(p_notification_log_id uuid)
returns void
language plpgsql
security definer
as $function$
declare
  v_log notification_log%rowtype;
  v_alt text;
begin
  if not public.is_admin() then
    raise exception 'Only a Super Admin may resend a message on a different route.';
  end if;

  select * into v_log from notification_log where id = p_notification_log_id;
  if not found then
    raise exception 'Notification log entry not found.';
  end if;
  if v_log.channel <> 'sms' then
    raise exception 'This function only resends SMS messages.';
  end if;

  if v_log.sms_provider = 'bulksms' then
    v_alt := case when coalesce(v_log.termii_channel, 'direct-corporate') = 'direct-corporate' then 'direct-refund' else 'direct-corporate' end;
    perform public.send_bulksms_sms(v_log.member_id, v_log.recipient, v_log.body, v_alt);
  else
    v_alt := case when coalesce(v_log.termii_channel, 'dnd') = 'dnd' then 'generic' else 'dnd' end;
    perform public.send_termii_sms(v_log.member_id, v_log.recipient, v_log.body, v_alt);
  end if;
end;
$function$;

-- (b) The other provider entirely — the real payoff of running two.
create or replace function public.admin_resend_sms_other_provider(p_notification_log_id uuid)
returns void
language plpgsql
security definer
as $function$
declare
  v_log notification_log%rowtype;
begin
  if not public.is_admin() then
    raise exception 'Only a Super Admin may resend a message via a different provider.';
  end if;

  select * into v_log from notification_log where id = p_notification_log_id;
  if not found then
    raise exception 'Notification log entry not found.';
  end if;
  if v_log.channel <> 'sms' then
    raise exception 'This function only resends SMS messages.';
  end if;

  if v_log.sms_provider = 'bulksms' then
    perform public.send_termii_sms(v_log.member_id, v_log.recipient, v_log.body);
  else
    perform public.send_bulksms_sms(v_log.member_id, v_log.recipient, v_log.body);
  end if;
end;
$function$;

-- 4c. The automatic 5th-of-month statement job — same smart dispatcher.
create or replace function public.run_monthly_auto_processing()
returns void
language plpgsql
security definer
as $function$
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
  v_notify record;
  v_month_label text := to_char(v_today, 'FMMonth YYYY');
  v_sms_message text;
begin
  if v_today < (v_month_start + 4) then
    return;
  end if;

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
      last_deduction_loan_cut = v_loan_cut,
      last_deduction_admin_cut = v_admin_cut,
      status = case when balance - v_loan_cut <= 0 and admin_charge_balance - v_admin_cut <= 0 then 'completed' else status end
    where id = v_loan.id;

    insert into transactions (member_id, description, amount, type)
    values (v_loan.member_id, 'Monthly loan deduction (automatic) — ' || v_loan.id, -v_total, 'loan');

    v_loans_processed := v_loans_processed + 1;
  end loop;

  insert into auto_processing_runs (run_date, savings_processed, savings_skipped, loans_processed, loans_skipped)
  values (v_today, v_savings_processed, v_savings_skipped, v_loans_processed, v_loans_skipped);

  for v_notify in
    select p.id, p.first_name, p.surname, p.phone, p.contact_email,
           p.savings_balance, p.last_savings_amount
    from profiles p
    where p.status = 'active' and p.last_savings_date = v_today
  loop
    v_sms_message := public.compose_statement_sms_message(v_notify.id, v_month_start);
    if v_sms_message is not null then
      perform public.send_sms_smart(v_notify.id, v_notify.phone, v_sms_message);
    end if;
    perform public.send_termii_email(v_notify.id, v_notify.contact_email,
      'Your Al-Amanah MCS Statement — ' || v_month_label,
      jsonb_build_object(
        'name', v_notify.first_name || ' ' || v_notify.surname,
        'month', v_month_label,
        'savings_amount', to_char(v_notify.last_savings_amount, 'FM999,999,999'),
        'savings_balance', to_char(v_notify.savings_balance, 'FM999,999,999')
      )
    );
  end loop;

  for v_notify in
    select distinct p.id, p.first_name, p.surname, p.phone, p.contact_email, p.savings_balance
    from profiles p
    join loans l on l.member_id = p.id
    where l.last_deduction_date = v_today
      and (p.last_savings_date is distinct from v_today)
  loop
    v_sms_message := public.compose_statement_sms_message(v_notify.id, v_month_start);
    if v_sms_message is not null then
      perform public.send_sms_smart(v_notify.id, v_notify.phone, v_sms_message);
    end if;
    perform public.send_termii_email(v_notify.id, v_notify.contact_email,
      'Your Al-Amanah MCS Statement — ' || v_month_label,
      jsonb_build_object(
        'name', v_notify.first_name || ' ' || v_notify.surname,
        'month', v_month_label,
        'savings_amount', '0',
        'savings_balance', to_char(v_notify.savings_balance, 'FM999,999,999')
      )
    );
  end loop;
end;
$function$;


-- =====================================================================
-- SOURCE: RUN THIS NOW bulksms use international gateway.sql
-- =====================================================================
-- =====================================================================
-- Updates BulkSMSNigeria's default gateway to "international" — per
-- their own support team, this is the route that reaches DND numbers
-- across ALL networks (the real equivalent of what Termii's "dnd"
-- channel was supposed to do). "direct-refund" becomes the fallback
-- route when resending — it's the standard/cheap route, and
-- BulkSMSNigeria doesn't charge you if it gets blocked by DND, so
-- it's a safe thing to try as an alternate.
--
-- Safe to run anytime. Only affects BulkSMSNigeria sends — Termii is
-- untouched.
-- =====================================================================

create or replace function public.send_bulksms_sms(
  p_member_id uuid,
  p_phone text,
  p_message text,
  p_gateway text default 'international'
)
returns void
language plpgsql
security definer
as $function$
declare
  v_base_url  text := public.get_app_setting('bulksms_base_url');
  v_api_token text := public.get_app_setting('bulksms_api_token');
  v_sender    text := public.get_app_setting('bulksms_sender_id');
  v_request_id bigint;
  v_phone text;
  v_gateway text := coalesce(nullif(trim(p_gateway), ''), 'international');
begin
  if v_gateway not in ('direct-refund', 'direct-corporate', 'otp', 'dual-backup', 'international') then
    raise exception 'Invalid BulkSMSNigeria gateway: %. Must be direct-refund, direct-corporate, otp, dual-backup, or international.', v_gateway;
  end if;

  if p_phone is null or trim(p_phone) = '' then
    insert into notification_log (member_id, channel, recipient, body, success, response, termii_channel, sms_provider)
    values (p_member_id, 'sms', p_phone, p_message, false, 'No phone number on file.', v_gateway, 'bulksms');
    return;
  end if;
  if v_base_url is null or v_api_token is null or v_sender is null then
    insert into notification_log (member_id, channel, recipient, body, success, response, termii_channel, sms_provider)
    values (p_member_id, 'sms', p_phone, p_message, false, 'BulkSMSNigeria settings not configured yet (app_settings: bulksms_base_url / bulksms_api_token / bulksms_sender_id).', v_gateway, 'bulksms');
    return;
  end if;

  v_phone := regexp_replace(p_phone, '[^0-9]', '', 'g');
  if left(v_phone, 1) = '0' then
    v_phone := '234' || substring(v_phone from 2);
  elsif left(v_phone, 3) <> '234' then
    v_phone := '234' || v_phone;
  end if;

  begin
    v_request_id := net.http_post(
      url := v_base_url,
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || v_api_token,
        'Accept', 'application/json'
      ),
      body := jsonb_build_object(
        'from', v_sender,
        'to', v_phone,
        'body', p_message,
        'gateway', v_gateway,
        'callback_url', public.get_app_setting('bulksms_webhook_url')
      )
    );
    insert into notification_log (member_id, channel, recipient, body, success, response, termii_channel, sms_provider)
    values (p_member_id, 'sms', v_phone, p_message, true, 'Request queued via BulkSMSNigeria (' || v_gateway || ') route (pg_net request id ' || v_request_id || ').', v_gateway, 'bulksms');
  exception when others then
    insert into notification_log (member_id, channel, recipient, body, success, response, termii_channel, sms_provider)
    values (p_member_id, 'sms', v_phone, p_message, false, sqlerrm, v_gateway, 'bulksms');
  end;
end;
$function$;

-- Update the "same provider, other route" resend to flip between
-- 'international' (DND-capable) and 'direct-refund' (standard/cheap)
-- instead of the old direct-corporate/direct-refund pairing.
create or replace function public.admin_resend_sms_alternate_channel(p_notification_log_id uuid)
returns void
language plpgsql
security definer
as $function$
declare
  v_log notification_log%rowtype;
  v_alt text;
begin
  if not public.is_admin() then
    raise exception 'Only a Super Admin may resend a message on a different route.';
  end if;

  select * into v_log from notification_log where id = p_notification_log_id;
  if not found then
    raise exception 'Notification log entry not found.';
  end if;
  if v_log.channel <> 'sms' then
    raise exception 'This function only resends SMS messages.';
  end if;

  if v_log.sms_provider = 'bulksms' then
    v_alt := case when coalesce(v_log.termii_channel, 'international') = 'international' then 'direct-refund' else 'international' end;
    perform public.send_bulksms_sms(v_log.member_id, v_log.recipient, v_log.body, v_alt);
  else
    v_alt := case when coalesce(v_log.termii_channel, 'dnd') = 'dnd' then 'generic' else 'dnd' end;
    perform public.send_termii_sms(v_log.member_id, v_log.recipient, v_log.body, v_alt);
  end if;
end;
$function$;


-- =====================================================================
-- SOURCE: RUN THIS NOW sms cascade escalation.sql
-- =====================================================================
-- =====================================================================
-- AUTOMATIC SMS ESCALATION CASCADE
--
-- Instead of picking one fixed provider/route, every SMS now starts on
-- the cheapest route and automatically climbs to the next one ONLY if
-- needed — stopping the instant any tier reports Delivered.
--
-- Default order (edit anytime — see bottom of this file):
--   1. Termii dnd
--   2. Termii generic
--   3. BulkSMSNigeria direct-refund   (cheap, free if blocked)
--   4. BulkSMSNigeria international   (most reliable, most expensive —
--                                      used only as a last resort)
--
-- Escalates immediately if a tier comes back with a clear rejection,
-- or after a wait period if a tier stays silent with no report either
-- way. Never escalates once something reports Delivered.
--
-- IMPORTANT — this needs one more manual step after running this file:
-- enabling the pg_cron extension so the escalation check runs on a
-- schedule automatically. Instructions are at the bottom of this file.
--
-- Safe to run anytime.
-- =====================================================================

-- 1. New tracking columns — tie every attempt in the same cascade
--    together, and record its position in the sequence.
alter table public.notification_log
  add column if not exists cascade_group_id uuid not null default gen_random_uuid(),
  add column if not exists cascade_step int not null default 0,
  add column if not exists cascade_superseded boolean not null default false;

comment on column public.notification_log.cascade_group_id is
  'Groups every escalation attempt for the same logical message together.';
comment on column public.notification_log.cascade_step is
  'Position (0-indexed) in the sms_cascade_sequence setting this attempt used.';
comment on column public.notification_log.cascade_superseded is
  'True once this attempt has been escalated past (a later tier was tried instead).';

-- 2. Default cascade settings — edit these anytime, no code changes
--    needed. sms_cascade_sequence is a comma-separated list of
--    "provider:route" steps, tried in order.
insert into app_settings (key, value) values
  ('sms_cascade_sequence', 'termii:dnd,termii:generic,bulksms:direct-refund,bulksms:international'),
  ('sms_cascade_wait_minutes', '10')
on conflict (key) do nothing;

-- =====================================================================
-- 3. Expand send_termii_sms and send_bulksms_sms to accept cascade
--    tracking info. Dropping the exact old 4-argument signatures
--    first, so there's only ever ONE version of each function —
--    avoiding the "function is not unique" bug from earlier.
-- =====================================================================
drop function if exists public.send_termii_sms(uuid, text, text, text);
drop function if exists public.send_bulksms_sms(uuid, text, text, text);

create or replace function public.send_termii_sms(
  p_member_id uuid,
  p_phone text,
  p_message text,
  p_channel text default 'dnd',
  p_cascade_group_id uuid default gen_random_uuid(),
  p_cascade_step int default 0
)
returns void
language plpgsql
security definer
as $function$
declare
  v_base_url text := public.get_app_setting('termii_base_url');
  v_api_key  text := public.get_app_setting('termii_api_key');
  v_sender   text := public.get_app_setting('termii_sender_id');
  v_request_id bigint;
  v_phone text;
  v_channel text := coalesce(nullif(trim(p_channel), ''), 'dnd');
begin
  if v_channel not in ('dnd', 'generic', 'whatsapp') then
    raise exception 'Invalid SMS channel: %. Must be dnd, generic, or whatsapp.', v_channel;
  end if;

  if p_phone is null or trim(p_phone) = '' then
    insert into notification_log (member_id, channel, recipient, body, success, response, termii_channel, sms_provider, cascade_group_id, cascade_step)
    values (p_member_id, 'sms', p_phone, p_message, false, 'No phone number on file.', v_channel, 'termii', p_cascade_group_id, p_cascade_step);
    return;
  end if;
  if v_base_url is null or v_api_key is null or v_sender is null then
    insert into notification_log (member_id, channel, recipient, body, success, response, termii_channel, sms_provider, cascade_group_id, cascade_step)
    values (p_member_id, 'sms', p_phone, p_message, false, 'Termii settings not configured (app_settings: termii_base_url / termii_api_key / termii_sender_id).', v_channel, 'termii', p_cascade_group_id, p_cascade_step);
    return;
  end if;

  v_phone := regexp_replace(p_phone, '[^0-9]', '', 'g');
  if left(v_phone, 1) = '0' then
    v_phone := '234' || substring(v_phone from 2);
  elsif left(v_phone, 3) <> '234' then
    v_phone := '234' || v_phone;
  end if;

  begin
    v_request_id := net.http_post(
      url := v_base_url || '/api/sms/send',
      headers := jsonb_build_object('Content-Type', 'application/json'),
      body := jsonb_build_object(
        'api_key', v_api_key,
        'to', v_phone,
        'from', v_sender,
        'sms', p_message,
        'type', 'plain',
        'channel', v_channel
      )
    );
    insert into notification_log (member_id, channel, recipient, body, success, response, termii_channel, sms_provider, cascade_group_id, cascade_step)
    values (p_member_id, 'sms', v_phone, p_message, true, 'Request queued via ' || v_channel || ' route (pg_net request id ' || v_request_id || ').', v_channel, 'termii', p_cascade_group_id, p_cascade_step);
  exception when others then
    insert into notification_log (member_id, channel, recipient, body, success, response, termii_channel, sms_provider, cascade_group_id, cascade_step)
    values (p_member_id, 'sms', v_phone, p_message, false, sqlerrm, v_channel, 'termii', p_cascade_group_id, p_cascade_step);
  end;
end;
$function$;

create or replace function public.send_bulksms_sms(
  p_member_id uuid,
  p_phone text,
  p_message text,
  p_gateway text default 'international',
  p_cascade_group_id uuid default gen_random_uuid(),
  p_cascade_step int default 0
)
returns void
language plpgsql
security definer
as $function$
declare
  v_base_url  text := public.get_app_setting('bulksms_base_url');
  v_api_token text := public.get_app_setting('bulksms_api_token');
  v_sender    text := public.get_app_setting('bulksms_sender_id');
  v_request_id bigint;
  v_phone text;
  v_gateway text := coalesce(nullif(trim(p_gateway), ''), 'international');
begin
  if v_gateway not in ('direct-refund', 'direct-corporate', 'otp', 'dual-backup', 'international') then
    raise exception 'Invalid BulkSMSNigeria gateway: %.', v_gateway;
  end if;

  if p_phone is null or trim(p_phone) = '' then
    insert into notification_log (member_id, channel, recipient, body, success, response, termii_channel, sms_provider, cascade_group_id, cascade_step)
    values (p_member_id, 'sms', p_phone, p_message, false, 'No phone number on file.', v_gateway, 'bulksms', p_cascade_group_id, p_cascade_step);
    return;
  end if;
  if v_base_url is null or v_api_token is null or v_sender is null then
    insert into notification_log (member_id, channel, recipient, body, success, response, termii_channel, sms_provider, cascade_group_id, cascade_step)
    values (p_member_id, 'sms', p_phone, p_message, false, 'BulkSMSNigeria settings not configured (app_settings: bulksms_base_url / bulksms_api_token / bulksms_sender_id).', v_gateway, 'bulksms', p_cascade_group_id, p_cascade_step);
    return;
  end if;

  v_phone := regexp_replace(p_phone, '[^0-9]', '', 'g');
  if left(v_phone, 1) = '0' then
    v_phone := '234' || substring(v_phone from 2);
  elsif left(v_phone, 3) <> '234' then
    v_phone := '234' || v_phone;
  end if;

  begin
    v_request_id := net.http_post(
      url := v_base_url,
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || v_api_token,
        'Accept', 'application/json'
      ),
      body := jsonb_build_object(
        'from', v_sender,
        'to', v_phone,
        'body', p_message,
        'gateway', v_gateway,
        'callback_url', public.get_app_setting('bulksms_webhook_url')
      )
    );
    insert into notification_log (member_id, channel, recipient, body, success, response, termii_channel, sms_provider, cascade_group_id, cascade_step)
    values (p_member_id, 'sms', v_phone, p_message, true, 'Request queued via BulkSMSNigeria (' || v_gateway || ') route (pg_net request id ' || v_request_id || ').', v_gateway, 'bulksms', p_cascade_group_id, p_cascade_step);
  exception when others then
    insert into notification_log (member_id, channel, recipient, body, success, response, termii_channel, sms_provider, cascade_group_id, cascade_step)
    values (p_member_id, 'sms', v_phone, p_message, false, sqlerrm, v_gateway, 'bulksms', p_cascade_group_id, p_cascade_step);
  end;
end;
$function$;

-- =====================================================================
-- 4. The cascade engine itself.
-- =====================================================================

-- Sends one specific step of the cascade sequence (internal helper —
-- not something you'd normally call directly).
create or replace function public.send_sms_via_cascade_step(
  p_member_id uuid,
  p_phone text,
  p_message text,
  p_cascade_group_id uuid,
  p_step int
)
returns void
language plpgsql
security definer
as $function$
declare
  v_sequence text[] := string_to_array(
    coalesce(public.get_app_setting('sms_cascade_sequence'), 'termii:dnd,termii:generic,bulksms:direct-refund,bulksms:international'),
    ','
  );
  v_token text;
  v_provider text;
  v_route text;
begin
  if p_step >= array_length(v_sequence, 1) then
    return; -- no more tiers left
  end if;

  v_token := trim(v_sequence[p_step + 1]); -- postgres arrays are 1-indexed
  v_provider := split_part(v_token, ':', 1);
  v_route := split_part(v_token, ':', 2);

  if v_provider = 'bulksms' then
    perform public.send_bulksms_sms(p_member_id, p_phone, p_message, v_route, p_cascade_group_id, p_step);
  else
    perform public.send_termii_sms(p_member_id, p_phone, p_message, v_route, p_cascade_group_id, p_step);
  end if;
end;
$function$;

-- Every part of the app calls THIS to send an SMS — starts a fresh
-- cascade at tier 0. Same name/signature as before, so nothing else
-- needs to change.
create or replace function public.send_sms_smart(
  p_member_id uuid,
  p_phone text,
  p_message text
)
returns void
language plpgsql
security definer
as $function$
declare
  v_group_id uuid := gen_random_uuid();
begin
  perform public.send_sms_via_cascade_step(p_member_id, p_phone, p_message, v_group_id, 0);
end;
$function$;

-- The escalator — meant to run every few minutes via pg_cron (see
-- bottom of this file). Finds attempts that either got a clear
-- rejection, or have stayed silent too long, and pushes them to the
-- next tier. Returns how many were escalated (for your own curiosity).
create or replace function public.escalate_stalled_sms_cascades()
returns integer
language plpgsql
security definer
as $function$
declare
  v_wait_minutes int := coalesce(nullif(public.get_app_setting('sms_cascade_wait_minutes'), '')::int, 10);
  v_sequence text[] := string_to_array(
    coalesce(public.get_app_setting('sms_cascade_sequence'), 'termii:dnd,termii:generic,bulksms:direct-refund,bulksms:international'),
    ','
  );
  v_row record;
  v_escalated_count int := 0;
begin
  for v_row in
    select *
    from notification_log
    where channel = 'sms'
      and success = true
      and cascade_superseded = false
      and cascade_step < array_length(v_sequence, 1) - 1
      and (
        (delivery_status is not null and delivery_status not ilike 'DELIV%')
        or
        (delivery_status is null and created_at < now() - (v_wait_minutes || ' minutes')::interval)
      )
  loop
    update notification_log set cascade_superseded = true where id = v_row.id;
    perform public.send_sms_via_cascade_step(v_row.member_id, v_row.recipient, v_row.body, v_row.cascade_group_id, v_row.cascade_step + 1);
    v_escalated_count := v_escalated_count + 1;
  end loop;

  return v_escalated_count;
end;
$function$;

-- =====================================================================
-- 5. ONE MANUAL STEP LEFT: schedule the escalator to run automatically.
--
-- Run this separately, AFTER confirming pg_cron is enabled:
-- Supabase Dashboard -> Database -> Extensions -> search "pg_cron" ->
-- Enable it. Then run:
--
--   select cron.schedule(
--     'escalate-stalled-sms',
--     '*/5 * * * *',
--     $$select public.escalate_stalled_sms_cascades();$$
--   );
--
-- This checks every 5 minutes for anything stuck and pushes it
-- forward automatically. Without this step, the cascade will still
-- START correctly on every new message, but won't AUTO-ESCALATE —
-- you'd need to run "select public.escalate_stalled_sms_cascades();"
-- manually each time to move things forward.
-- =====================================================================


-- =====================================================================
-- SOURCE: RUN THIS NOW quiet hours and cascade fixes.sql
-- =====================================================================
-- =====================================================================
-- 1. QUIET HOURS: no SMS goes out between 8pm and 8am West Africa
--    Time — including the automatic monthly deduction/savings job,
--    since everything already funnels through send_sms_smart.
--
-- Anything that would have sent during that window is queued instead,
-- and automatically sent the moment 8am arrives — nothing is lost,
-- it's just delayed to a reasonable hour.
-- =====================================================================

create table if not exists public.sms_queue (
  id uuid primary key default gen_random_uuid(),
  member_id uuid references public.profiles(id) on delete cascade,
  phone text not null,
  message text not null,
  created_at timestamptz not null default now(),
  dispatched_at timestamptz
);

alter table public.sms_queue enable row level security;
drop policy if exists "admin read sms queue" on public.sms_queue;
create policy "admin read sms queue" on public.sms_queue
  for select using (public.is_admin());

-- The main send entry point now checks the time first. Same name and
-- signature as before, so nothing calling it needs to change.
create or replace function public.send_sms_smart(
  p_member_id uuid,
  p_phone text,
  p_message text
)
returns void
language plpgsql
security definer
as $function$
declare
  v_lagos_time time := (now() at time zone 'Africa/Lagos')::time;
  v_is_quiet_hours boolean := (v_lagos_time >= '20:00'::time or v_lagos_time < '08:00'::time);
  v_group_id uuid := gen_random_uuid();
begin
  if v_is_quiet_hours then
    insert into public.sms_queue (member_id, phone, message)
    values (p_member_id, p_phone, p_message);
    return;
  end if;

  perform public.send_sms_via_cascade_step(p_member_id, p_phone, p_message, v_group_id, 0);
end;
$function$;

-- Runs every morning to flush anything that queued up overnight —
-- scheduled below via pg_cron at 8:00 AM WAT (07:00 UTC).
create or replace function public.dispatch_queued_overnight_sms()
returns integer
language plpgsql
security definer
as $function$
declare
  v_row record;
  v_count int := 0;
begin
  for v_row in
    select * from public.sms_queue where dispatched_at is null order by created_at
  loop
    perform public.send_sms_smart(v_row.member_id, v_row.phone, v_row.message);
    update public.sms_queue set dispatched_at = now() where id = v_row.id;
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$function$;

-- Schedule the 8 AM flush (07:00 UTC = 08:00 WAT year-round, since
-- Nigeria doesn't observe daylight saving).
select cron.unschedule(jobid) from cron.job where jobname = 'al-amanah-dispatch-overnight-sms';
select cron.schedule(
  'al-amanah-dispatch-overnight-sms',
  '0 7 * * *',
  $cron$select public.dispatch_queued_overnight_sms();$cron$
);

-- =====================================================================
-- 2. Reorder the cascade to try Termii's GENERIC route first, since
--    it's the one that's actually working right now — dnd remains in
--    the sequence for later, once Termii activates it, but is no
--    longer wasted as the very first (currently non-functional)
--    attempt on every message.
-- =====================================================================
update app_settings
set value = 'termii:generic,termii:dnd,bulksms:direct-refund,bulksms:international'
where key = 'sms_cascade_sequence';

-- =====================================================================
-- 3. ONE-TIME FIX: stop pre-existing messages (sent before the cascade
--    system existed) from being swept into automatic escalation. Every
--    row that already existed got a default cascade_step of 0 when
--    those columns were added — this marks all of them as "already
--    handled" so the escalator only ever touches genuinely new,
--    intentionally-tracked cascades going forward.
--
-- Safe to run once, right now. Do not re-run this later — it would
-- also swallow up any real new cascades still legitimately in
-- progress at the time you run it.
-- =====================================================================
update notification_log
set cascade_superseded = true
where created_at < now();


-- =====================================================================
-- SOURCE: RUN THIS NOW secretary reporting functions.sql
-- =====================================================================
-- =====================================================================
-- Secretary reporting functions — gives the Secretary role read access
-- to the loan and membership data needed for a proper administrative
-- register, WITHOUT opening up broad table-level RLS access. Follows
-- the same pattern already used for Treasurer/President/Bursary
-- (get_loan_financial_summary, get_bursary_financial_summary, etc.):
-- a SECURITY DEFINER function that checks the role internally, rather
-- than a blanket "secretary can read every row" policy.
--
-- Safe to run anytime. Read-only — creates no new writable access.
-- =====================================================================

-- Full loan register, every application regardless of status, with
-- member details already joined in — powers the Loan Applications
-- Register and the Approved Loans Monthly Register.
create or replace function public.get_secretary_loan_register()
returns table (
  loan_id text,
  member_id uuid,
  member_name text,
  alamanah_no text,
  department text,
  type text,
  amount numeric,
  purpose text,
  duration int,
  date_applied date,
  status text,
  workflow_status text,
  date_decision date,
  decline_reason text,
  admin_charge numeric,
  balance numeric,
  monthly_deduction numeric,
  months_paid int
)
language plpgsql
security definer
as $function$
begin
  if not (public.is_secretary() or public.is_admin()) then
    raise exception 'Only the Secretary may view the loan register.';
  end if;

  return query
  select
    l.id, l.member_id,
    p.first_name || ' ' || p.surname,
    p.alamanah_no, p.department,
    l.type, l.amount, l.purpose, l.duration,
    l.date_applied, l.status, l.workflow_status,
    l.date_decision, l.decline_reason,
    l.admin_charge, l.balance, l.monthly_deduction, l.months_paid
  from loans l
  join profiles p on p.id = l.member_id
  order by l.date_applied desc;
end;
$function$;

-- Full membership register — for the printable membership list, one
-- of the Secretary's standard administrative documents.
create or replace function public.get_secretary_member_register()
returns table (
  member_id uuid,
  alamanah_no text,
  first_name text,
  surname text,
  department text,
  phone text,
  status text,
  joined date,
  savings_balance numeric
)
language plpgsql
security definer
as $function$
begin
  if not (public.is_secretary() or public.is_admin()) then
    raise exception 'Only the Secretary may view the membership register.';
  end if;

  return query
  select p.id, p.alamanah_no, p.first_name, p.surname, p.department, p.phone, p.status, p.joined, p.savings_balance
  from profiles p
  order by p.alamanah_no;
end;
$function$;

-- Single-loan detail, used for the individual printable "Loan
-- Application Form" — includes officer sign-off info (assessment +
-- decision), so the printed form doubles as a filing-ready record.
create or replace function public.get_secretary_loan_detail(p_loan_id text)
returns jsonb
language plpgsql
security definer
as $function$
declare
  v_loan loans%rowtype;
  v_profile profiles%rowtype;
  v_vetting jsonb;
  v_assessment jsonb;
  v_decision jsonb;
begin
  if not (public.is_secretary() or public.is_admin()) then
    raise exception 'Only the Secretary may view loan application details.';
  end if;

  select * into v_loan from loans where id = p_loan_id;
  if not found then
    raise exception 'Loan not found.';
  end if;
  select * into v_profile from profiles where id = v_loan.member_id;

  select to_jsonb(lv) into v_vetting from loan_vettings lv where lv.loan_id = p_loan_id order by lv.created_at desc limit 1;
  select to_jsonb(la) into v_assessment from loan_assessments la where la.loan_id = p_loan_id order by la.created_at desc limit 1;
  select to_jsonb(ld) into v_decision from loan_decisions ld where ld.loan_id = p_loan_id order by ld.created_at desc limit 1;

  return jsonb_build_object(
    'loan', to_jsonb(v_loan),
    'member', jsonb_build_object(
      'name', v_profile.first_name || ' ' || v_profile.surname,
      'alamanah_no', v_profile.alamanah_no,
      'department', v_profile.department,
      'phone', v_profile.phone
    ),
    'bursary_vetting', v_vetting,
    'treasurer_assessment', v_assessment,
    'president_decision', v_decision
  );
end;
$function$;


-- =====================================================================
-- SOURCE: RUN THIS NOW treasurer bulk ledger upload.sql
-- =====================================================================
-- =====================================================================
-- TREASURER BULK LEDGER UPDATE — lets the Treasurer reconcile many
-- members' financial records at once from a physical ledger, via CSV
-- upload, instead of editing one member at a time.
--
-- Each CSV row is keyed by Al-Amanah No. and can set:
--   - monthly_savings_amount   (their recurring monthly savings amount)
--   - savings_balance          (their total accumulated savings — "Total Savings")
--   - total_admin_charges      (their total accumulated admin charges — "Total Admin Charge")
--   - loan_type                (real / commodity / humanitarian — which loan the next 4 fields apply to)
--   - loan_balance             (that loan's outstanding principal balance)
--   - loan_monthly_deduction   (that loan's monthly repayment amount — "Loans Deductions")
--   - loan_admin_charge_balance (that loan's remaining admin charge — "Admin Charge")
--   - months_paid              (how many months they've already repaid)
--
-- Every field is optional per row — leave a column blank in the CSV
-- to leave that value untouched. Every change is logged the same way
-- manual admin corrections are (previous value, new value, who did it,
-- reason), so this stays fully auditable.
--
-- Only updates an approved, currently-active loan of the given type —
-- it will not touch a completed/declined/offset loan, and will report
-- that clearly rather than silently failing.
--
-- Safe to run anytime.
-- =====================================================================

-- Handles ONE row. Raises an exception on any real problem (member not
-- found, loan not found for the given type, etc.) — the bulk wrapper
-- below catches this per-row so one bad row doesn't stop the batch.
create or replace function public.treasurer_bulk_update_ledger_single(
  p_alamanah_no text,
  p_monthly_savings_amount numeric,
  p_savings_balance numeric,
  p_total_admin_charges numeric,
  p_loan_type text,
  p_loan_balance numeric,
  p_loan_monthly_deduction numeric,
  p_loan_admin_charge_balance numeric,
  p_months_paid int
)
returns text
language plpgsql
security definer
as $function$
declare
  v_profile profiles%rowtype;
  v_loan loans%rowtype;
  v_reason text := 'Bulk ledger reconciliation by Treasurer, ' || to_char(now(), 'YYYY-MM-DD HH24:MI');
  v_notes text[] := '{}';
  v_clean_no text := 'AL/' || regexp_replace(upper(trim(p_alamanah_no)), '^AL/?', '');
begin
  if not (public.is_treasurer() or public.is_admin()) then
    raise exception 'Only the Treasurer may bulk-update the member ledger.';
  end if;

  select * into v_profile from profiles where alamanah_no = v_clean_no;
  if not found then
    raise exception 'No member found with Al-Amanah No. %', v_clean_no;
  end if;

  -- Profile-level fields
  if p_monthly_savings_amount is not null then
    update profiles set monthly_savings_amount = p_monthly_savings_amount where id = v_profile.id;
    v_notes := v_notes || ('Monthly savings amount set to ' || p_monthly_savings_amount);
  end if;

  if p_savings_balance is not null and p_savings_balance <> v_profile.savings_balance then
    insert into savings_adjustments (member_id, previous_amount, new_amount, reason, adjusted_by)
    values (v_profile.id, v_profile.savings_balance, p_savings_balance, v_reason, auth.uid());
    insert into transactions (member_id, description, amount, type)
    values (v_profile.id, 'Bulk ledger reconciliation (savings balance)', p_savings_balance - v_profile.savings_balance, 'savings');
    update profiles set savings_balance = p_savings_balance where id = v_profile.id;
    v_notes := v_notes || ('Total savings set to ' || p_savings_balance);
  end if;

  if p_total_admin_charges is not null and p_total_admin_charges <> v_profile.total_admin_charges then
    insert into admin_charge_adjustments (member_id, previous_amount, new_amount, reason, adjusted_by)
    values (v_profile.id, v_profile.total_admin_charges, p_total_admin_charges, v_reason, auth.uid());
    insert into transactions (member_id, description, amount, type)
    values (v_profile.id, 'Bulk ledger reconciliation (total admin charges)', -(p_total_admin_charges - v_profile.total_admin_charges), 'admin_charge');
    update profiles set total_admin_charges = p_total_admin_charges where id = v_profile.id;
    v_notes := v_notes || ('Total admin charge set to ' || p_total_admin_charges);
  end if;

  -- Loan-level fields — only if a loan_type was given AND at least
  -- one loan field was actually provided.
  if p_loan_type is not null and (p_loan_balance is not null or p_loan_monthly_deduction is not null or p_loan_admin_charge_balance is not null or p_months_paid is not null) then
    if p_loan_type not in ('real', 'commodity', 'humanitarian') then
      raise exception 'Invalid loan_type "%" — must be real, commodity, or humanitarian.', p_loan_type;
    end if;

    select * into v_loan from loans where member_id = v_profile.id and type = p_loan_type and status = 'approved';
    if not found then
      raise exception 'No active (approved) % loan found for this member — loan fields skipped.', p_loan_type;
    end if;

    update loans set
      balance = coalesce(p_loan_balance, balance),
      monthly_deduction = coalesce(p_loan_monthly_deduction, monthly_deduction),
      admin_charge_balance = coalesce(p_loan_admin_charge_balance, admin_charge_balance),
      months_paid = coalesce(p_months_paid, months_paid)
    where id = v_loan.id;

    insert into transactions (member_id, description, amount, type)
    values (v_profile.id, 'Bulk ledger reconciliation (' || p_loan_type || ' loan) — ' || v_loan.id, 0, 'loan');

    v_notes := v_notes || (initcap(p_loan_type) || ' loan ledger updated (balance/deduction/admin charge/months paid as provided)');
  end if;

  perform public.log_activity(
    'treasurer_bulk_ledger_update', 'profile', v_profile.id::text, v_profile.id,
    null, null, jsonb_build_object('alamanah_no', v_clean_no, 'notes', v_notes)
  );

  if array_length(v_notes, 1) is null then
    return v_clean_no || ': no changes (all fields blank).';
  end if;
  return v_clean_no || ': ' || array_to_string(v_notes, '; ');
end;
$function$;

-- Bulk wrapper — pass a JSONB array of row objects, one per CSV row.
-- Each row's keys should match the parameter names above (alamanah_no,
-- monthly_savings_amount, savings_balance, total_admin_charges,
-- loan_type, loan_balance, loan_monthly_deduction,
-- loan_admin_charge_balance, months_paid). Missing/blank values should
-- be omitted or null.
create or replace function public.treasurer_bulk_update_ledger(p_rows jsonb)
returns table(alamanah_no text, processed boolean, message text)
language plpgsql
security definer
as $function$
declare
  v_row jsonb;
begin
  if not (public.is_treasurer() or public.is_admin()) then
    raise exception 'Only the Treasurer may bulk-update the member ledger.';
  end if;

  for v_row in select * from jsonb_array_elements(p_rows)
  loop
    begin
      alamanah_no := coalesce(v_row->>'alamanah_no', '(missing)');
      message := public.treasurer_bulk_update_ledger_single(
        v_row->>'alamanah_no',
        nullif(v_row->>'monthly_savings_amount', '')::numeric,
        nullif(v_row->>'savings_balance', '')::numeric,
        nullif(v_row->>'total_admin_charges', '')::numeric,
        nullif(v_row->>'loan_type', ''),
        nullif(v_row->>'loan_balance', '')::numeric,
        nullif(v_row->>'loan_monthly_deduction', '')::numeric,
        nullif(v_row->>'loan_admin_charge_balance', '')::numeric,
        nullif(v_row->>'months_paid', '')::int
      );
      processed := true;
    exception when others then
      processed := false;
      message := sqlerrm;
    end;
    return next;
  end loop;
end;
$function$;


-- =====================================================================
-- SOURCE: RUN THIS NOW loan guarantor requirement.sql
-- =====================================================================
-- =====================================================================
-- LOAN GUARANTOR REQUIREMENT
--
-- Every loan application now requires TWO guarantors, collected at
-- the point of application. Each guarantor must physically sign a
-- printed Guarantor Form acknowledging their guarantee in writing —
-- this isn't just paperwork on the side: a loan CANNOT be marked
-- "Eligible" by the Bursary Officer until both guarantor forms are
-- confirmed received, the same way the 1/3 net-pay rule is already
-- a hard, unbypassable gate.
--
-- Safe to run anytime.
-- =====================================================================

create table if not exists public.loan_guarantors (
  id              uuid primary key default gen_random_uuid(),
  loan_id         text not null references loans(id) on delete cascade,
  guarantor_number int not null check (guarantor_number in (1, 2)),
  full_name       text not null,
  alamanah_no     text,              -- optional: filled in if the guarantor is also a member
  phone           text not null,
  department      text,
  relationship    text not null,     -- e.g. "Colleague", "Head of Department", "Family"
  form_received   boolean not null default false,
  verified_by     uuid references profiles(id),
  verified_at     timestamptz,
  created_at      timestamptz not null default now(),
  unique (loan_id, guarantor_number)
);

alter table public.loan_guarantors enable row level security;

-- Members can add guarantors for their OWN loan at application time,
-- and see them, but cannot edit or delete afterwards — a guarantor
-- declaration shouldn't be alterable once submitted.
drop policy if exists "members add own loan guarantors" on public.loan_guarantors;
create policy "members add own loan guarantors" on public.loan_guarantors
  for insert with check (
    exists (select 1 from loans l where l.id = loan_guarantors.loan_id and l.member_id = auth.uid())
  );

drop policy if exists "members read own loan guarantors" on public.loan_guarantors;
create policy "members read own loan guarantors" on public.loan_guarantors
  for select using (
    exists (select 1 from loans l where l.id = loan_guarantors.loan_id and l.member_id = auth.uid())
  );

-- Officers who touch the loan pipeline can see every guarantor record.
drop policy if exists "officers read all loan guarantors" on public.loan_guarantors;
create policy "officers read all loan guarantors" on public.loan_guarantors
  for select using (
    public.is_admin() or public.is_bursary() or public.is_treasurer() or public.is_president() or public.is_secretary()
  );

-- =====================================================================
-- Member-facing: submit both guarantors right after applying.
-- =====================================================================
create or replace function public.submit_loan_guarantors(
  p_loan_id text,
  p_guarantors jsonb  -- array of exactly 2 objects: {full_name, alamanah_no, phone, department, relationship}
)
returns void
language plpgsql
security definer
as $function$
declare
  v_loan loans%rowtype;
  v_g jsonb;
  v_num int := 0;
begin
  select * into v_loan from loans where id = p_loan_id and member_id = auth.uid();
  if not found then
    raise exception 'Loan not found or does not belong to you.';
  end if;

  if jsonb_array_length(p_guarantors) <> 2 then
    raise exception 'Exactly two guarantors are required.';
  end if;

  for v_g in select * from jsonb_array_elements(p_guarantors)
  loop
    v_num := v_num + 1;
    if coalesce(trim(v_g->>'full_name'), '') = '' then
      raise exception 'Guarantor % is missing a full name.', v_num;
    end if;
    if coalesce(trim(v_g->>'phone'), '') = '' then
      raise exception 'Guarantor % is missing a phone number.', v_num;
    end if;
    if coalesce(trim(v_g->>'relationship'), '') = '' then
      raise exception 'Guarantor % is missing their relationship to you.', v_num;
    end if;

    insert into loan_guarantors (loan_id, guarantor_number, full_name, alamanah_no, phone, department, relationship)
    values (
      p_loan_id, v_num,
      trim(v_g->>'full_name'),
      nullif(trim(coalesce(v_g->>'alamanah_no', '')), ''),
      trim(v_g->>'phone'),
      nullif(trim(coalesce(v_g->>'department', '')), ''),
      trim(v_g->>'relationship')
    );
  end loop;
end;
$function$;

-- =====================================================================
-- Officer-facing: mark a guarantor's signed physical form as received
-- and verified. Only Secretary, Bursary, or Admin can do this — the
-- people actually handling paperwork.
-- =====================================================================
create or replace function public.verify_loan_guarantor_form(
  p_loan_id text,
  p_guarantor_number int,
  p_received boolean
)
returns void
language plpgsql
security definer
as $function$
begin
  if not (public.is_secretary() or public.is_bursary() or public.is_admin()) then
    raise exception 'Only the Secretary or Bursary Officer may verify guarantor forms.';
  end if;

  update loan_guarantors set
    form_received = p_received,
    verified_by = case when p_received then auth.uid() else null end,
    verified_at = case when p_received then now() else null end
  where loan_id = p_loan_id and guarantor_number = p_guarantor_number;

  if not found then
    raise exception 'Guarantor record not found for this loan.';
  end if;
end;
$function$;

-- Convenience function: returns both guarantors for a loan, for
-- display on printable forms and officer screens.
create or replace function public.get_loan_guarantors(p_loan_id text)
returns setof loan_guarantors
language sql
security definer
as $function$
  select * from loan_guarantors where loan_id = p_loan_id order by guarantor_number;
$function$;

-- =====================================================================
-- THE HARD GATE: Bursary cannot mark a loan "eligible" unless both
-- guarantor forms are confirmed received — exactly like the existing
-- 1/3 net-pay rule, this is enforced by the database itself, not just
-- convention.
-- =====================================================================
create or replace function public.submit_bursary_vetting(
  p_loan_id text,
  p_eligibility_status text,
  p_note text,
  p_gross_pay numeric default null,
  p_other_monthly_deductions numeric default null
)
returns void
language plpgsql
security definer
as $function$
declare
  v_loan loans%rowtype;
  v_profile profiles%rowtype;
  v_existing numeric;
  v_proposed numeric;
  v_gross numeric;
  v_other numeric;
  v_net_before_coop numeric;
  v_limit numeric;
  v_remaining_net numeric;
  v_within boolean;
  v_new_workflow_status text;
  v_guarantors_confirmed int;
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

  -- Hard gate: both guarantor forms must be confirmed received before
  -- this application can be marked eligible.
  if p_eligibility_status = 'eligible' then
    select count(*) into v_guarantors_confirmed
    from loan_guarantors where loan_id = p_loan_id and form_received = true;

    if v_guarantors_confirmed < 2 then
      raise exception 'This application cannot be marked eligible: both signed guarantor forms must be confirmed received first (currently % of 2 confirmed).', v_guarantors_confirmed;
    end if;
  end if;

  if p_gross_pay is not null or p_other_monthly_deductions is not null then
    perform public.set_member_salary(v_loan.member_id, p_gross_pay, p_other_monthly_deductions);
  end if;

  select * into v_profile from profiles where id = v_loan.member_id;
  v_gross := v_profile.gross_pay;
  v_other := v_profile.other_monthly_deductions;

  if v_gross is null or v_other is null then
    raise exception 'Record this member''s Gross Pay and Other (non-cooperative) Deductions before vetting this application.';
  end if;

  select coalesce(sum(monthly_deduction), 0) into v_existing
  from loans
  where member_id = v_loan.member_id and status = 'approved' and id <> p_loan_id;
  v_existing := v_existing
    + coalesce(v_profile.monthly_savings_amount, 0)
    + round(coalesce(v_profile.monthly_savings_amount, 0) * 0.075);

  v_proposed := case when v_loan.duration > 0
    then round((v_loan.amount + coalesce(v_loan.admin_charge, 0)) / v_loan.duration)
    else v_loan.amount + coalesce(v_loan.admin_charge, 0)
  end;

  v_net_before_coop := v_gross - v_other;
  v_remaining_net := v_net_before_coop - v_existing - v_proposed;
  v_limit := round(v_gross / 3.0);
  v_within := v_remaining_net >= v_limit;

  if p_eligibility_status = 'eligible' and not v_within then
    raise exception 'This application cannot be marked eligible: after all deductions (other %, existing cooperative %, this loan %), only % would remain — below one-third of Gross Pay (%).',
      to_char(v_other, 'FM999,999,999'),
      to_char(v_existing, 'FM999,999,999'),
      to_char(v_proposed, 'FM999,999,999'),
      to_char(round(v_remaining_net), 'FM999,999,999'),
      to_char(v_limit, 'FM999,999,999');
  end if;

  insert into loan_vettings (
    loan_id, bursary_officer_id, gross_pay, other_monthly_deductions, net_pay,
    existing_monthly_deductions, proposed_monthly_deduction, total_projected_deductions,
    one_third_gross_limit, net_pay_after_deductions, within_limit, eligibility_status, note
  ) values (
    p_loan_id, auth.uid(), v_gross, v_other, v_net_before_coop,
    v_existing, v_proposed, v_existing + v_proposed,
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
      decline_reason = coalesce(p_note, 'Net Pay after all deductions would fall below one-third of Gross Pay (Bursary vetting).'),
      workflow_status = v_new_workflow_status
    where id = p_loan_id;
  else
    v_new_workflow_status := 'on_hold_bursary';
    update loans set workflow_status = v_new_workflow_status where id = p_loan_id;
  end if;

  perform public.log_activity(
    'loan_vetting_submitted', 'loan', p_loan_id, v_loan.member_id,
    v_loan.workflow_status, v_new_workflow_status,
    jsonb_build_object('eligibility_status', p_eligibility_status, 'total_projected_deductions', v_existing + v_proposed, 'within_limit', v_within)
  );
end;
$function$;

-- =====================================================================
-- Also enrich the Secretary's existing loan-detail printout (used by
-- the "Print Form" button in the Loan Applications Register) with
-- guarantor info, so it shows both guarantors and whether their
-- signed forms have been confirmed received.
-- =====================================================================
create or replace function public.get_secretary_loan_detail(p_loan_id text)
returns jsonb
language plpgsql
security definer
as $function$
declare
  v_loan loans%rowtype;
  v_profile profiles%rowtype;
  v_vetting jsonb;
  v_assessment jsonb;
  v_decision jsonb;
  v_guarantors jsonb;
begin
  if not (public.is_secretary() or public.is_admin()) then
    raise exception 'Only the Secretary may view loan application details.';
  end if;

  select * into v_loan from loans where id = p_loan_id;
  if not found then
    raise exception 'Loan not found.';
  end if;
  select * into v_profile from profiles where id = v_loan.member_id;

  select to_jsonb(lv) into v_vetting from loan_vettings lv where lv.loan_id = p_loan_id order by lv.created_at desc limit 1;
  select to_jsonb(la) into v_assessment from loan_assessments la where la.loan_id = p_loan_id order by la.created_at desc limit 1;
  select to_jsonb(ld) into v_decision from loan_decisions ld where ld.loan_id = p_loan_id order by ld.created_at desc limit 1;
  select jsonb_agg(to_jsonb(g) order by g.guarantor_number) into v_guarantors from loan_guarantors g where g.loan_id = p_loan_id;

  return jsonb_build_object(
    'loan', to_jsonb(v_loan),
    'member', jsonb_build_object(
      'name', v_profile.first_name || ' ' || v_profile.surname,
      'alamanah_no', v_profile.alamanah_no,
      'department', v_profile.department,
      'phone', v_profile.phone
    ),
    'bursary_vetting', v_vetting,
    'treasurer_assessment', v_assessment,
    'president_decision', v_decision,
    'guarantors', coalesce(v_guarantors, '[]'::jsonb)
  );
end;
$function$;



-- =====================================================================
-- SOURCE: RUN THIS NOW allow treasurer verify guarantors.sql
-- =====================================================================
-- =====================================================================
-- Allows the Treasurer to also acknowledge/confirm a guarantor's
-- signed form during their loan assessment step — previously only
-- Bursary and Secretary could do this. Either office confirming is
-- now sufficient; this doesn't require both to confirm separately.
--
-- Safe to run anytime.
-- =====================================================================
create or replace function public.verify_loan_guarantor_form(
  p_loan_id text,
  p_guarantor_number int,
  p_received boolean
)
returns void
language plpgsql
security definer
as $function$
begin
  if not (public.is_secretary() or public.is_bursary() or public.is_treasurer() or public.is_admin()) then
    raise exception 'Only the Secretary, Bursary Officer, or Treasurer may verify guarantor forms.';
  end if;

  update loan_guarantors set
    form_received = p_received,
    verified_by = case when p_received then auth.uid() else null end,
    verified_at = case when p_received then now() else null end
  where loan_id = p_loan_id and guarantor_number = p_guarantor_number;

  if not found then
    raise exception 'Guarantor record not found for this loan.';
  end if;
end;
$function$;


-- =====================================================================
-- SOURCE: RUN THIS NOW fix guarantor confirmation ownership.sql
-- =====================================================================
-- =====================================================================
-- FIX: guarantor confirmation restricted to Treasurer only, and the
-- hard gate moved to where it actually belongs.
--
-- Bursary reviews an application BEFORE the Treasurer does. Since only
-- the Treasurer can now confirm guarantor forms, requiring guarantors
-- to be confirmed before BURSARY can approve was a logical dead end —
-- the Treasurer hasn't had a chance to review it yet at that point.
-- The hard gate now lives on the Treasurer's assessment step instead,
-- which is the stage that actually happens after guarantors could
-- realistically be confirmed.
--
-- Safe to run anytime.
-- =====================================================================

-- 1. Only the Treasurer (or Admin) may confirm a guarantor's form now.
create or replace function public.verify_loan_guarantor_form(
  p_loan_id text,
  p_guarantor_number int,
  p_received boolean
)
returns void
language plpgsql
security definer
as $function$
begin
  if not (public.is_treasurer() or public.is_admin()) then
    raise exception 'Only the Treasurer may verify guarantor forms.';
  end if;

  update loan_guarantors set
    form_received = p_received,
    verified_by = case when p_received then auth.uid() else null end,
    verified_at = case when p_received then now() else null end
  where loan_id = p_loan_id and guarantor_number = p_guarantor_number;

  if not found then
    raise exception 'Guarantor record not found for this loan.';
  end if;
end;
$function$;

-- 2. Remove the guarantor hard-gate from Bursary vetting — Bursary
--    still handles the 1/3 net-pay affordability rule, just not the
--    guarantor confirmation anymore.
create or replace function public.submit_bursary_vetting(
  p_loan_id text,
  p_eligibility_status text,
  p_note text,
  p_gross_pay numeric default null,
  p_other_monthly_deductions numeric default null
)
returns void
language plpgsql
security definer
as $function$
declare
  v_loan loans%rowtype;
  v_profile profiles%rowtype;
  v_existing numeric;
  v_proposed numeric;
  v_gross numeric;
  v_other numeric;
  v_net_before_coop numeric;
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

  if p_gross_pay is not null or p_other_monthly_deductions is not null then
    perform public.set_member_salary(v_loan.member_id, p_gross_pay, p_other_monthly_deductions);
  end if;

  select * into v_profile from profiles where id = v_loan.member_id;
  v_gross := v_profile.gross_pay;
  v_other := v_profile.other_monthly_deductions;

  if v_gross is null or v_other is null then
    raise exception 'Record this member''s Gross Pay and Other (non-cooperative) Deductions before vetting this application.';
  end if;

  select coalesce(sum(monthly_deduction), 0) into v_existing
  from loans
  where member_id = v_loan.member_id and status = 'approved' and id <> p_loan_id;
  v_existing := v_existing
    + coalesce(v_profile.monthly_savings_amount, 0)
    + round(coalesce(v_profile.monthly_savings_amount, 0) * 0.075);

  v_proposed := case when v_loan.duration > 0
    then round((v_loan.amount + coalesce(v_loan.admin_charge, 0)) / v_loan.duration)
    else v_loan.amount + coalesce(v_loan.admin_charge, 0)
  end;

  v_net_before_coop := v_gross - v_other;
  v_remaining_net := v_net_before_coop - v_existing - v_proposed;
  v_limit := round(v_gross / 3.0);
  v_within := v_remaining_net >= v_limit;

  if p_eligibility_status = 'eligible' and not v_within then
    raise exception 'This application cannot be marked eligible: after all deductions (other %, existing cooperative %, this loan %), only % would remain — below one-third of Gross Pay (%).',
      to_char(v_other, 'FM999,999,999'),
      to_char(v_existing, 'FM999,999,999'),
      to_char(v_proposed, 'FM999,999,999'),
      to_char(round(v_remaining_net), 'FM999,999,999'),
      to_char(v_limit, 'FM999,999,999');
  end if;

  insert into loan_vettings (
    loan_id, bursary_officer_id, gross_pay, other_monthly_deductions, net_pay,
    existing_monthly_deductions, proposed_monthly_deduction, total_projected_deductions,
    one_third_gross_limit, net_pay_after_deductions, within_limit, eligibility_status, note
  ) values (
    p_loan_id, auth.uid(), v_gross, v_other, v_net_before_coop,
    v_existing, v_proposed, v_existing + v_proposed,
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
      decline_reason = coalesce(p_note, 'Net Pay after all deductions would fall below one-third of Gross Pay (Bursary vetting).'),
      workflow_status = v_new_workflow_status
    where id = p_loan_id;
  else
    v_new_workflow_status := 'on_hold_bursary';
    update loans set workflow_status = v_new_workflow_status where id = p_loan_id;
  end if;

  perform public.log_activity(
    'loan_vetting_submitted', 'loan', p_loan_id, v_loan.member_id,
    v_loan.workflow_status, v_new_workflow_status,
    jsonb_build_object('eligibility_status', p_eligibility_status, 'total_projected_deductions', v_existing + v_proposed, 'within_limit', v_within)
  );
end;
$function$;

-- 3. Add the guarantor hard-gate to Treasurer's assessment instead —
--    cannot mark a loan "eligible" until both guarantor forms are
--    confirmed received.
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
  v_guarantors_confirmed int;
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

  -- Hard gate: both guarantor forms must be confirmed received before
  -- this application can be marked eligible.
  if p_eligibility_status = 'eligible' then
    select count(*) into v_guarantors_confirmed
    from loan_guarantors where loan_id = p_loan_id and form_received = true;

    if v_guarantors_confirmed < 2 then
      raise exception 'This application cannot be marked eligible: both signed guarantor forms must be confirmed received first (currently % of 2 confirmed).', v_guarantors_confirmed;
    end if;
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


-- =====================================================================
-- IMPORTANT NOTES — read before using this file
-- =====================================================================
--
-- 1. ⚠️  ONE-TIME STATEMENT INCLUDED ABOVE — DO NOT RE-RUN ON YOUR
--    CURRENT LIVE DATABASE. The section from "quiet hours and cascade
--    fixes.sql" contains:
--        update notification_log set cascade_superseded = true where created_at < now();
--    This was a one-time cleanup to stop pre-existing messages from
--    being swept into the new auto-escalation system. On a FRESH,
--    empty database (disaster recovery, new environment) it is
--    harmless — there's no data yet. But if you run this addendum
--    again against your CURRENT live database, it will incorrectly
--    mark every real, currently-in-progress SMS as "already handled,"
--    breaking auto-escalation for them.
--
--    => This file is for REBUILDING a database from scratch only.
--       Never re-run it against the live, already-running database.
--
-- 2. SECRETS ARE NOT INCLUDED. Your Termii and BulkSMSNigeria API
--    keys, sender IDs, and webhook URLs live in the app_settings
--    table and were deliberately left OUT of this file (they're
--    private credentials, not schema). After rebuilding a database
--    from scratch, you must re-insert them manually:
--
--      insert into app_settings (key, value) values
--        ('termii_base_url', 'https://v3.api.termii.com'),
--        ('termii_api_key', 'YOUR-TERMII-KEY'),
--        ('termii_sender_id', 'YOUR-SENDER-ID'),
--        ('bulksms_base_url', 'https://www.bulksmsnigeria.com/api/v2/sms'),
--        ('bulksms_api_token', 'YOUR-BULKSMS-TOKEN'),
--        ('bulksms_sender_id', 'YOUR-BULKSMS-SENDER-ID'),
--        ('bulksms_webhook_url', 'https://YOUR-PROJECT.supabase.co/functions/v1/bulksms-dlr-webhook'),
--        ('primary_sms_provider', 'termii')
--      on conflict (key) do update set value = excluded.value;
--
-- 3. TWO EDGE FUNCTIONS are also not in this SQL file, since they're
--    separate Deno files, not SQL: termii-dlr-webhook and
--    bulksms-dlr-webhook. Both live under supabase/functions/ in this
--    repo already and must be deployed separately via the Supabase
--    dashboard (Edge Functions → Create → paste code → Deploy → turn
--    off "Verify JWT").
--
-- 4. pg_cron SCHEDULES must also be re-created manually after a fresh
--    rebuild — they are not stored as ordinary schema and don't
--    survive a database recreation:
--
--      select cron.schedule('escalate-stalled-sms', '*/5 * * * *',
--        $$select public.escalate_stalled_sms_cascades();$$);
--      select cron.schedule('al-amanah-dispatch-overnight-sms', '0 7 * * *',
--        $$select public.dispatch_queued_overnight_sms();$$);
--
--    (The monthly auto-processing job's schedule is already committed
--    in supabase/migration_auto_monthly_processing.sql.)
-- =====================================================================
