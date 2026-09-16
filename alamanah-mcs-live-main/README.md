# Al-Amanah Multi-Purpose Co-operative Society — Website

Affiliated with Kwara State College of Arabic and Islamic Legal Studies (KwaraCAILS), Ilorin.

## Status: production-ready frontend, needs Supabase provisioned
This site now runs on a **real backend** (Supabase: Postgres + Auth), not
localStorage. Member login uses real hashed passwords, all data is shared
across every visitor/device, and loan approvals/deductions are enforced
server-side. **See SETUP.md — that's the file your developer needs.**
Until SETUP.md is completed, the login/dashboard/apply/admin pages won't
work (they'll fail to connect, since js/supabaseClient.js has placeholder
credentials).

## Pages
- index.html — Home / landing page (static, no login needed)
- about.html — About the cooperative (static)
- loan-info.html — Loan product details (static)
- login.html — Member login (Al-Amanah number + password)
- setup-password.html — First-time account creation for existing members
- dashboard.html — Member dashboard (savings, loans, transactions)
- apply-loan.html — Loan application form
- admin.html — Admin login + management panel (approve/decline loans)

## How the backend works
- `supabase/schema.sql` — full database schema, security rules, and server-side
  functions. Run once in your Supabase project's SQL Editor.
- `supabase/seed_member_directory.sql` — the list of members allowed to
  register. Replace the demo rows with your real staff list before go-live.
- `js/supabaseClient.js` — where your developer pastes the project URL and
  API key.
- `js/data-live.js` — every function the site uses to talk to the database
  (login, sign-up, loans, transactions, admin actions).

Full instructions: **SETUP.md**.

## Demo login (only works after SETUP.md is completed and the seed file is run)
- Member: Al-Amanah No. `AL/014`, surname `Abdulraheem` → set up a
  password at /setup-password.html, then log in at /login.html.
- Admin: created manually per SETUP.md step 5 (no demo admin ships by default,
  for security).

## Structure
    alamanah/
      index.html, about.html, loan-info.html      -> public pages
      login.html, setup-password.html              -> member auth
      dashboard.html, apply-loan.html               -> member area
      admin.html                                    -> admin portal
      css/style.css
      js/main.js             -> shared UI (nav, reveal animations, toasts)
      js/supabaseClient.js   -> Supabase connection (fill in credentials)
      js/data-live.js        -> all database read/write logic
      js/dashboard.js, js/apply-loan.js, js/admin.js -> page-specific logic
      supabase/schema.sql               -> database schema + security rules
      supabase/migration_savings_admin_charge_fix.sql       -> upgrade script (savings/admin-charge separation)
      supabase/migration_admin_deduction_controls.sql       -> upgrade script (admin-only deductions, pause/resume, audit trail)
      supabase/seed_member_directory.sql -> allowed-member list
      assets/logo.jpg        -> KwaraCAILS crest
      SETUP.md                -> step-by-step backend setup guide
