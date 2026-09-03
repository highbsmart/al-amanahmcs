# SETUP.md — Going Live with a Real Backend (Supabase)

This turns the site from a browser-only demo into a real, secure, multi-user
system: real passwords, one shared database, admin-controlled loan approvals.
Hand this file to your developer — every step below is required, in order.

---

## 1. Create the Supabase project
1. Go to https://supabase.com → sign up / log in → **New project**.
2. Pick a name (e.g. `alamanah-mcs`), a strong database password (save it
   somewhere safe — it's separate from any app login), and a region close to
   Nigeria (e.g. Europe/Frankfurt is usually the nearest option).
3. Wait ~2 minutes for the project to finish provisioning.

## 2. Run the database schema
1. In the Supabase dashboard, open **SQL Editor → New query**.
2. Open `supabase/schema.sql` from this project, paste the entire contents in,
   and click **Run**. This creates all tables, security rules, and functions
   (already includes the admin-only deduction controls described below — a
   fresh install needs nothing further from the migration files).
3. Open a second new query, paste in `supabase/seed_member_directory.sql`,
   and click **Run**. This loads the 3 demo members for testing — replace
   this file's contents with your real member list before real go-live
   (see the template/instructions inside that file for CSV import).

**Already have a live project from before?** Run `supabase/migration_admin_deduction_controls.sql`
once (after the existing `migration_savings_admin_charge_fix.sql`, if you
haven't already) to bring it up to date — it adds the new columns and
functions without touching any data you already have.

## 3. Turn off email confirmation
Because members log in with an **Al-Amanah number**, not a real email
address, the site generates an internal placeholder email behind the scenes
(e.g. `al2019014@members.alamanahmcs.local`). Supabase's default setting
would try to send a confirmation email there — which will never arrive and
will block login. Turn this off:

1. **Authentication → Providers → Email**.
2. Turn **OFF** "Confirm email".
3. Save.

## 4. Get your API keys
1. **Project Settings → API**.
2. Copy the **Project URL** and the **publishable/anon public key** (depending on the API Keys screen).
3. Open `js/supabaseClient.js` in this project and paste them in:
   ```js
   const SUPABASE_URL = "https://xxxxxxxx.supabase.co";
   const SUPABASE_ANON_KEY = "eyJ...";
   ```
   The anon key is safe to expose in frontend code — it only ever works
   within the row-level-security rules defined in `schema.sql`.

> **This ZIP is already configured for the new Supabase project.** Do not paste the REST endpoint (`.../rest/v1/`) into `SUPABASE_URL`; the client URL must be the project base URL (`https://<project-ref>.supabase.co`).

## 5. Create your first admin account
Admins do NOT sign up through the website — they're created directly so
membership fraud isn't possible.
1. **Authentication → Users → Add user → Create new user.**
   Use a real email address and a strong password.
2. **Table Editor → profiles.** You won't see a row yet because this admin
   has no member_directory entry — that's fine, admins don't need one.
   Instead, run this in **SQL Editor** (replace the email and details):
   ```sql
   insert into profiles (id, alamanah_no, surname, first_name, is_admin)
   select id, 'ADMIN-001', 'Admin', 'Society', true
   from auth.users where email = 'the-email-you-just-created@example.com';
   ```
3. Log in at `/admin.html` with that email and password to confirm it works.

## 6. Test the member flow end to end
1. Go to `/setup-password.html`, enter `AL/014` / `Abdulraheem`
   (a seeded demo member) and create a password.
2. Confirm it redirects to the dashboard with real savings/loan data.
3. Log out, log back in at `/login.html` with the same credentials.
4. Apply for a loan, then approve/decline it from `/admin.html`.
5. From `/admin.html`'s Members tab, use "Record savings" for that member,
   then set a "Monthly amt." for them. From the Deductions tab, click
   "Process this month" on their approved loan and confirm the loan
   balance drops while the member's savings balance is unaffected.

## 7. Deploy
Same as before — push this whole folder to GitHub and deploy on Netlify/Vercel
(see the earlier hosting guide). Nothing extra is needed for Supabase; the
site talks to it directly from the browser.

## 8. Before real members touch it
- [ ] Replace the seeded demo rows in `member_directory` with your real staff
      list (CSV import via Table Editor, or the SQL template in
      `seed_member_directory.sql`).
- [ ] Delete or ignore the 3 demo members once real data is loaded.
- [ ] Create real admin accounts for each committee member who needs access
      (repeat step 5); avoid sharing one login.
- [ ] In Supabase → **Authentication → Settings**, set a **Site URL** matching
      your real domain (e.g. `https://alamanahmcs.org`).
- [ ] Consider enabling Supabase's **Point-in-time recovery / backups**
      (Settings → Database) — important once real money data is involved.
- [ ] Password resets: since members don't have real emails on file, a
      forgotten password currently has to be reset manually by an admin via
      **Authentication → Users → select the member → Reset password**. If
      you'd like a self-service reset flow (e.g. via SMS or a security
      question), that's a follow-up feature — ask and I'll build it.

---

## Deduction management (admin-only)
- **Members never record their own deduction.** Savings contributions and
  loan repayments are recorded exclusively by an admin, from `admin.html`.
- **Bulk processing.** The Members tab can process a monthly savings
  contribution for many selected members at once (each using their own
  stored "Monthly amt."); the Deductions tab can do the same for many
  approved loans at once (each using its own monthly repayment amount), or
  for every eligible loan in one click.
- **Loans never touch savings.** A loan repayment only reduces the
  outstanding loan balance only. Savings only ever grows via
  a savings contribution.
- **Pause / resume.** An admin can pause or resume savings, and separately
  pause or resume loan deductions, for one member or for everyone at once.
  A paused member's balance is left untouched and their dashboard clearly
  shows "Savings Deduction Paused" / "Deduction Status: Paused".
- **Editing savings.** An admin can directly correct a member's savings
  balance with a required reason; every edit is logged to the
  `savings_adjustments` table (previous amount, new amount, reason, who
  made it, when).
- **Member search.** The Members tab has a live search by name or
  Al-Amanah number.
- **Next contribution schedule.** After each recorded contribution, the
  system stores the next due date as the 5th of the following month and
  the next expected amount, shown on both the admin and member dashboards.

## Business rules implemented in this build
- **Real Loan** — 3× savings balance, fixed 24-month term, no separate loan fee.
- **Commodity Loan** — flat ₦500,000 maximum (regardless of savings), 10%
  commodity loan charge added on top, fixed 12-month term.
- **Humanitarian Loan** — flat ₦100,000 maximum, fixed 8-month term, no fee.
- **Administrative charge** — 7.5% deducted from every monthly savings
  contribution (not from loans). Recorded by an admin via the "Record
  savings" button next to each member in the admin panel's Members tab —
  enter the gross amount and the full savings amount is credited to savings, while the 7.5% charge is recorded separately as a salary deduction.
- **Member status & review cycle** — each member has a status (Active /
  Retired / Dismissed) settable by an admin; savings recording should stop
  once a member is no longer Active. Every profile also tracks a "savings
  last reviewed" date; the admin panel flags anyone overdue for their
  six-monthly review and lets an admin mark one complete with one click.
- **₦1,000 application fee** — shown as an informational notice on the apply
  page for now, until online payment is wired up (see Phase 2 below).

## Phase 2 (not yet built): online ₦1,000 application fee payment
This needs a Nigerian payment gateway account before it can be built:
1. Create an account at paystack.com and complete business verification.
2. Get your **Test Secret Key** and **Test Public Key** from
   Settings → API Keys & Webhooks.
3. Send both test keys over and the payment step gets added to
   apply-loan.html, verified server-side via a Supabase Edge Function (so a
   member can't fake a successful payment from the browser).
4. Switch to live keys only after testing the full flow end-to-end.

---

## How the security actually works (for your developer's peace of mind)
- Passwords are never stored or handled by this code — Supabase Auth hashes
  and manages them entirely.
- A member can only ever read or write **their own** profile, loans, and
  transactions — enforced at the database level via Row Level Security
  (`schema.sql` section 7), not just hidden in the UI. Even a malicious user
  poking at the API directly cannot see another member's data.
- Members cannot sign up as themselves unless a matching, unclaimed row
  already exists in `member_directory` — that table is populated only by
  admins, so nobody can register a fake identity.
- Approving/declining loans and recording deductions happen through
  database functions (`decide_loan`, `record_loan_deduction`) that check
  admin status or ownership server-side — a member can't approve their own
  loan or edit their own balance by tampering with browser requests.
