-- =========================================================
-- AL-AMANAH MCS — Automatic monthly SMS + Email notifications
-- via Termii, sent right after each member's savings
-- contribution and/or loan deduction is processed for the month.
--
-- Uses Supabase's pg_net extension to call Termii's REST API
-- directly from the database — no separate server needed.
--
-- IMPORTANT — Termii settings are NOT hardcoded here (they're
-- your account's secrets). You set them once, separately, with
-- the companion "SET_TERMII_SETTINGS" snippet — see the
-- instructions that came with this file.
--
-- Email requires you to first create an "Email Configuration"
-- and an "Email Template" in your own Termii dashboard — Termii
-- has no API to create those for you, only to send using them
-- once they exist. See the instructions for the exact template
-- variable names this code sends.
--
-- Every attempt (success or failure) is logged to
-- notification_log so nothing is a silent black box. A failed
-- SMS or email NEVER blocks or reverses the actual savings/loan
-- processing — money-handling and notifications are fully
-- independent of each other.
--
-- REQUIRES: migration_auto_monthly_processing.sql already in
-- place.
--
-- Run ONCE in Supabase SQL Editor. Safe to re-run.
-- =========================================================

begin;

create extension if not exists pg_net;

-- ---------------------------------------------------------
-- 1. Audit log — every notification attempt, whichever channel.
-- ---------------------------------------------------------
create table if not exists notification_log (
  id          uuid primary key default gen_random_uuid(),
  member_id   uuid references profiles(id),
  channel     text not null check (channel in ('sms','email')),
  recipient   text,
  subject     text,
  body        text,
  success     boolean not null default false,
  response    text,
  created_at  timestamptz not null default now()
);

alter table notification_log enable row level security;

drop policy if exists "admin read notification log" on notification_log;
create policy "admin read notification log" on notification_log
  for select using (public.is_admin());

-- ---------------------------------------------------------
-- 2. Send one SMS via Termii. Never raises — logs the outcome
--    and returns quietly either way, so a failed message never
--    breaks the caller's larger loop.
-- ---------------------------------------------------------
create or replace function public.send_termii_sms(p_member_id uuid, p_phone text, p_message text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_base_url text := current_setting('app.termii_base_url', true);
  v_api_key  text := current_setting('app.termii_api_key', true);
  v_sender   text := current_setting('app.termii_sender_id', true);
  v_request_id bigint;
  v_status int;
  v_body text;
begin
  if p_phone is null or trim(p_phone) = '' then
    insert into notification_log (member_id, channel, recipient, body, success, response)
    values (p_member_id, 'sms', p_phone, p_message, false, 'No phone number on file.');
    return;
  end if;
  if v_base_url is null or v_api_key is null or v_sender is null then
    insert into notification_log (member_id, channel, recipient, body, success, response)
    values (p_member_id, 'sms', p_phone, p_message, false, 'Termii settings not configured (app.termii_base_url / app.termii_api_key / app.termii_sender_id).');
    return;
  end if;

  begin
    select id into v_request_id from net.http_post(
      url := v_base_url || '/api/sms/send',
      headers := jsonb_build_object('Content-Type', 'application/json'),
      body := jsonb_build_object(
        'api_key', v_api_key,
        'to', p_phone,
        'from', v_sender,
        'sms', p_message,
        'type', 'plain',
        'channel', 'dnd'
      )
    );
    insert into notification_log (member_id, channel, recipient, body, success, response)
    values (p_member_id, 'sms', p_phone, p_message, true, 'Request queued (pg_net request id ' || v_request_id || ').');
  exception when others then
    insert into notification_log (member_id, channel, recipient, body, success, response)
    values (p_member_id, 'sms', p_phone, p_message, false, sqlerrm);
  end;
end;
$$;

-- ---------------------------------------------------------
-- 3. Send one email via Termii's templated-email product.
--    Requires an Email Configuration + Template already created
--    in the Termii dashboard — see the instructions.
-- ---------------------------------------------------------
create or replace function public.send_termii_email(p_member_id uuid, p_email text, p_subject text, p_variables jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_base_url text := current_setting('app.termii_base_url', true);
  v_api_key  text := current_setting('app.termii_api_key', true);
  v_config_id text := current_setting('app.termii_email_configuration_id', true);
  v_template_id text := current_setting('app.termii_email_template_id', true);
  v_request_id bigint;
begin
  if p_email is null or trim(p_email) = '' then
    insert into notification_log (member_id, channel, recipient, subject, success, response)
    values (p_member_id, 'email', p_email, p_subject, false, 'No email address on file.');
    return;
  end if;
  if v_base_url is null or v_api_key is null or v_config_id is null or v_template_id is null then
    insert into notification_log (member_id, channel, recipient, subject, success, response)
    values (p_member_id, 'email', p_email, p_subject, false, 'Termii email settings not configured (app.termii_email_configuration_id / app.termii_email_template_id).');
    return;
  end if;

  begin
    select id into v_request_id from net.http_post(
      url := v_base_url || '/api/templates/send-email',
      headers := jsonb_build_object('Content-Type', 'application/json'),
      body := jsonb_build_object(
        'api_key', v_api_key,
        'email', p_email,
        'subject', p_subject,
        'email_configuration_id', v_config_id,
        'template_id', v_template_id,
        'variables', p_variables
      )
    );
    insert into notification_log (member_id, channel, recipient, subject, success, response)
    values (p_member_id, 'email', p_email, p_subject, true, 'Request queued (pg_net request id ' || v_request_id || ').');
  exception when others then
    insert into notification_log (member_id, channel, recipient, subject, success, response)
    values (p_member_id, 'email', p_email, p_subject, false, sqlerrm);
  end;
end;
$$;

revoke execute on function public.send_termii_sms(uuid, text, text) from public, anon, authenticated;
revoke execute on function public.send_termii_email(uuid, text, text, jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------
-- 4. Wire notifications into the monthly job. Re-declares
--    run_monthly_auto_processing() with the SAME processing
--    logic as before, plus: after processing, for every member
--    who had something happen this run, compose and send one SMS
--    and one email covering everything that happened to them
--    this month (savings and/or loan deductions combined).
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
  v_notify record;
  v_month_label text := to_char(v_today, 'FMMonth YYYY');
  v_loan_total numeric;
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

  -- NOTIFICATIONS — one SMS and one email per member who had
  -- anything actually processed this run (never for skips).
  for v_notify in
    select p.id, p.first_name, p.surname, p.phone, p.contact_email,
           p.savings_balance, p.last_savings_amount
    from profiles p
    where p.status = 'active' and p.last_savings_date = v_today
  loop
    select coalesce(sum(monthly_deduction + admin_monthly_deduction), 0), coalesce(sum(balance), 0)
      into v_loan_total, v_total
    from loans where member_id = v_notify.id and status in ('approved','completed') and last_deduction_date = v_today;

    v_sms_message := 'Al-Amanah MCS: Savings of NGN' || to_char(v_notify.last_savings_amount, 'FM999,999,999')
      || ' recorded. New balance: NGN' || to_char(v_notify.savings_balance, 'FM999,999,999')
      || case when v_loan_total > 0 then '. Loan deduction: NGN' || to_char(v_loan_total, 'FM999,999,999') || '. Outstanding: NGN' || to_char(v_total, 'FM999,999,999') else '' end
      || '. Thank you.';

    perform public.send_termii_sms(v_notify.id, v_notify.phone, v_sms_message);
    perform public.send_termii_email(v_notify.id, v_notify.contact_email,
      'Your Al-Amanah MCS Statement — ' || v_month_label,
      jsonb_build_object(
        'name', v_notify.first_name || ' ' || v_notify.surname,
        'month', v_month_label,
        'savings_amount', to_char(v_notify.last_savings_amount, 'FM999,999,999'),
        'savings_balance', to_char(v_notify.savings_balance, 'FM999,999,999'),
        'loan_deduction_amount', to_char(v_loan_total, 'FM999,999,999'),
        'loan_outstanding_balance', to_char(v_total, 'FM999,999,999')
      )
    );
  end loop;

  -- Also notify anyone whose ONLY event this run was a loan
  -- deduction (no savings contribution today, e.g. paused
  -- savings but active loan).
  for v_notify in
    select distinct p.id, p.first_name, p.surname, p.phone, p.contact_email, p.savings_balance
    from profiles p
    join loans l on l.member_id = p.id
    where l.last_deduction_date = v_today
      and (p.last_savings_date is distinct from v_today)
  loop
    select coalesce(sum(monthly_deduction + admin_monthly_deduction), 0), coalesce(sum(balance), 0)
      into v_loan_total, v_total
    from loans where member_id = v_notify.id and status in ('approved','completed') and last_deduction_date = v_today;

    v_sms_message := 'Al-Amanah MCS: Loan deduction of NGN' || to_char(v_loan_total, 'FM999,999,999')
      || ' recorded. Outstanding balance: NGN' || to_char(v_total, 'FM999,999,999') || '. Thank you.';

    perform public.send_termii_sms(v_notify.id, v_notify.phone, v_sms_message);
    perform public.send_termii_email(v_notify.id, v_notify.contact_email,
      'Your Al-Amanah MCS Statement — ' || v_month_label,
      jsonb_build_object(
        'name', v_notify.first_name || ' ' || v_notify.surname,
        'month', v_month_label,
        'savings_amount', '0',
        'savings_balance', to_char(v_notify.savings_balance, 'FM999,999,999'),
        'loan_deduction_amount', to_char(v_loan_total, 'FM999,999,999'),
        'loan_outstanding_balance', to_char(v_total, 'FM999,999,999')
      )
    );
  end loop;
end;
$$;

revoke execute on function public.run_monthly_auto_processing() from public, anon, authenticated;

commit;
