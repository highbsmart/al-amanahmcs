-- =========================================================
-- Seed member_directory
-- Run AFTER schema.sql. These are the members allowed to
-- register (create a password) on the live site.
-- Replace/extend with your real member list before go-live.
-- =========================================================

insert into member_directory (alamanah_no, surname, first_name, department, phone, savings_balance, joined)
values
  ('AL/014', 'Abdulraheem', 'Kamaldeen', 'Department of Arabic, KwaraCAILS', '0803 111 2233', 486500, '2019-03-11'),
  ('AL/2021/087', 'Yusuf',       'Fatimah',   'Bursary Department, KwaraCAILS',   '0806 555 7788', 212300, '2021-09-20'),
  ('AL/2017/003', 'Bello',       'Ibrahim',   'Registry, KwaraCAILS',             '0701 222 9090', 630000, '2017-01-15')
on conflict (alamanah_no) do nothing;

-- Note: status defaults to 'active' and savings_last_reviewed defaults to
-- today automatically (see profiles table in schema.sql) — no need to set
-- them here. An admin can change either any time from the admin panel.

-- ---------------------------------------------------------
-- TEMPLATE: for your real member roll, add one row per staff
-- member (or bulk-import a CSV via Supabase Table Editor ->
-- member_directory -> Insert -> Import data from CSV, using
-- these exact column names as headers):
--
-- alamanah_no,surname,first_name,department,phone,savings_balance,joined
-- AL/2024/101,Suleiman,Aisha,Academic Planning,0810 000 0000,50000,2024-02-01
-- ---------------------------------------------------------
