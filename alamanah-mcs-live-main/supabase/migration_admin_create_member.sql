-- =========================================================
-- MIGRATION: fix "Create New Member" / "Bulk Upload Members"
--
-- The admin.html buttons were calling two Supabase Edge Functions
-- (create-member, bulk-create-members) that were never built, so
-- clicking them did nothing. This migration switches them to use
-- the same working mechanism the app already relies on: the admin
-- adds a row to member_directory, and the member self-registers at
-- setup-password.html with their Al-Amanah No. + surname.
--
-- Run this ONCE in Supabase: Dashboard -> SQL Editor -> New query
-- -> paste -> Run. Safe to run on an existing live project; it only
-- adds columns and replaces one function, it does not touch data.
-- =========================================================

-- 1. Let the directory carry the two fields the Create Member form
--    already collects but the table didn't have a place for yet.
alter table member_directory add column if not exists monthly_savings_amount numeric not null default 0;
alter table member_directory add column if not exists contact_email text;
alter table profiles add column if not exists contact_email text;

-- 2. Make sure those two fields actually survive into `profiles`
--    when the member claims their account (previously they were
--    silently dropped).
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
                         savings_balance, monthly_savings_amount, joined)
  values (new.id, v_directory.alamanah_no, v_directory.surname, v_directory.first_name,
          v_directory.department, v_directory.phone, v_directory.contact_email,
          v_directory.savings_balance, v_directory.monthly_savings_amount, v_directory.joined);

  update member_directory set claimed = true where alamanah_no = v_directory.alamanah_no;

  return new;
end;
$$;

-- 3. member_directory already has RLS policy "admins manage directory"
--    (for all using is_admin() with check is_admin()), so the admin
--    panel can insert/select/delete rows directly with no new policy
--    needed here.
