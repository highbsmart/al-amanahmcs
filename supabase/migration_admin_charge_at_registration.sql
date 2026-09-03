-- =========================================================
-- MIGRATION: let the admin set an opening administrative
-- charges figure when registering a new member — same idea
-- as the existing "Savings Setup" fields (Monthly Savings
-- Amount / Opening Savings Balance), just for admin charges.
-- Applies to both the single "Create New Member" form and
-- the Bulk Upload CSV.
--
-- Run this ONCE in Supabase: Dashboard -> SQL Editor -> New
-- query -> paste -> Run. Safe to run on an existing live
-- project; it only adds a column and replaces one function.
-- =========================================================

-- 1. Give member_directory a place to hold the opening admin
--    charges figure, same as savings_balance already does.
alter table member_directory add column if not exists total_admin_charges numeric not null default 0;

-- 2. Carry it into profiles.total_admin_charges when the member
--    claims their account, same as every other directory field.
create or replace function public.handle_new_member()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_alamanah_no text := new.raw_user_meta_data ->> 'alamanah_no';
  v_surname     text := new.raw_user_meta_data ->> 'surname';
  v_directory   member_directory%rowtype;
begin
  if v_alamanah_no is null or v_surname is null then
    return new;
  end if;

  select * into v_directory
  from member_directory
  where lower(alamanah_no) = lower(v_alamanah_no)
    and lower(surname) = lower(v_surname)
    and claimed = false
  limit 1;

  if not found then
    raise exception 'No unclaimed member record matches that Al-Amanah number and surname.';
  end if;

  insert into profiles (id, alamanah_no, surname, first_name, department, phone, contact_email,
                         savings_balance, total_admin_charges, monthly_savings_amount, joined)
  values (new.id, v_directory.alamanah_no, v_directory.surname, v_directory.first_name,
          v_directory.department, v_directory.phone, v_directory.contact_email,
          v_directory.savings_balance, v_directory.total_admin_charges, v_directory.monthly_savings_amount, v_directory.joined);

  update member_directory set claimed = true where alamanah_no = v_directory.alamanah_no;

  return new;
end;
$$;

-- Done. Redeploy the updated site files (admin.html/js/data-live.js) alongside this.
