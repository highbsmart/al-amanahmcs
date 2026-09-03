# Implemented Changes for the Fresh Supabase Project

This package is configured for the new Supabase project and incorporates the latest requested loan and member-management corrections.

## Supabase connection
- Project base URL configured as `https://hrxyqrhpwbqdcrxbyakn.supabase.co`.
- Supabase publishable key configured in `js/supabaseClient.js`.
- The REST endpoint is not used as the project URL.

## Loan lifecycle
- Commodity loan charge corrected to **10%**.
- Total loan obligation = loan amount + applicable 10% commodity charge.
- Approval sets the active loan balance to the total obligation.
- Duplicate pending/active loans of the same type are blocked.
- A processed application cannot be approved or declined again.
- Added **Loan Offset** for active loans.
- Added controlled **Loan Reset** for active/completed loans without deleting history.
- Completed, declined, and offset loans remain in history and do not block a new application.

## Savings and deductions
- Loan repayments do not reduce savings.
- Savings remain unchanged until a new savings contribution is recorded.
- Administrative charges remain separate from savings.
- Admin controls member savings and deductions.

## Admin workflow
- All Members now uses a single **View member** action for member-specific management.
- The member detail view contains savings controls and loan information/actions.
- Search by member name or membership number remains available.
- Bulk processing remains available for multiple members/loans.

## Member workflow
- Loan Obligation card can be clicked to view full active loan details.
- Admin decisions and balance updates use the same database records shown to members.
- Available/current loan balance now reflects active outstanding loan balance instead of incorrectly subtracting it from savings eligibility.

## Payslip fixes and admin editing (latest update)
- Fixed a rare mismatch where one loan's ID could be a text-prefix of
  another loan's ID (e.g. `LN-1001` and `LN-10011`), which could cause a
  deduction line to be counted on the wrong loan on the payslip. The
  payslip now matches the exact transaction instead of a loose text match.
- The payslip now shows the loan's label and ID together on the same
  line, matching what's stored, so nothing renders blank if a loan type
  is missing from the lookup table.
- Cache-busting version numbers on `js/data-live.js`, `js/dashboard.js`
  and `js/admin.js` were bumped. If the live site still shows old
  behaviour after uploading this package, do a hard refresh (Ctrl/Cmd +
  Shift + R) — most "the update isn't showing" issues are the browser
  serving a cached copy of the old JS file.
- **New: admin-editable payslips.** Admins can now open a member's
  record on the admin page and click **Edit payslip** to manually set
  the savings contribution, administrative charge, and each loan
  deduction line shown on that member's payslip for a given month, plus
  leave an optional note. Once saved, the member's payslip for that
  month shows exactly what the admin entered instead of the automatic
  calculation — useful when a transaction was recorded with a typo or a
  one-off correction is needed. Use **Reset to computed values** to
  remove the manual edit and go back to the automatic calculation.
  Requires `supabase/migration_payslip_overrides.sql` to be run once
  (see below) — until then, "Edit payslip" will show an error.

## Fresh-project installation
1. Run `supabase/schema.sql` **once** in the new project's SQL Editor.
2. Run `supabase/seed_member_directory.sql` only if you want the included demo/test members.
3. Turn off email confirmation for the placeholder member emails.
4. Create the first admin account as described in `SETUP.md`.
5. Test before adding real financial records.

## Updating an EXISTING live project (already has real data)
Run only the new migration below in the SQL Editor — do **not** re-run
`schema.sql` on a live project, it will not touch existing data but
there's no need to:
6. Run `supabase/migration_payslip_overrides.sql` **once** to enable the
   admin-editable payslip feature described above.

Do not run old migration files after running the complete fresh `schema.sql` unless you deliberately need a specific migration for a different database.

## Latest transaction synchronisation fix
Run `supabase/migration_transaction_sync_cancel.sql` in the Supabase SQL Editor after deploying this version. It adds real-time-safe transaction cancellation, records manual admin-charge edits in member histories, and ensures cancelled records are excluded from member active histories.

## Simplified payslip, clear/archive history, sticky close buttons, role-based navigation (latest update)

### 1. Payslip simplified
- Payslip now shows exactly: Member/Al-Amanah No./Department, a **Savings** block (Monthly Savings, Administrative Charge 7.5%, Savings Total), an **Active Loans** block (one line per loan with `status = approved`, using that loan's fixed monthly deduction — declined/completed/offset loans never appear), and a final **Total Cooperative Deduction**.
- All narration ("deducted from salary", "deducted separately", explanatory footnotes) removed from both the member payslip (`dashboard.js`) and the admin's live-preview calculation used in the payslip editor (`admin.js`).
- Admin-saved payslip overrides (`payslip_overrides` table) still take precedence when one exists for a member+month, unchanged.

### 2. Admin "Clear/Archive History" (new: `supabase/migration_clear_history.sql`)
- New columns on `transactions`: `cleared_at`, `cleared_by`, `clear_reason`.
- New RPCs: `admin_clear_transaction`, `admin_restore_transaction`, `admin_delete_transaction_permanently`, `admin_clear_member_history` (by category: `savings` / `admin_charge` / `loan` / `all`), `admin_clear_payslip_history`.
- **Clear is not Cancel.** Cancel reverses a balance (for correcting mistakes). Clear never touches any balance — it only hides a record completely from the member (no visible trace, no "Cancelled by admin" label) while leaving the underlying figures untouched. Cleared rows move into an admin-only **Cleared/Archived Records** table (in Member Detail) with **Restore** and **Permanently delete** actions. Permanent delete is only allowed on already-cleared rows, as a safety gate.
- `getMyTransactions()` and `getMemberTransactions()` exclude cleared rows by default everywhere (member dashboard, admin's main views); only the new archive view fetches them via `getMemberClearedTransactions()`.
- Admin's Member Detail now has a **History Management** toolbar: Clear Savings History / Clear Admin Charge History / Clear Loan History / Clear Payslip History / Clear All Member History.

### 3. Modal close button moved to top-right, sticky
- Added `.modal-header-row` (sticky, `position: sticky; top: 0;`) and `.modal-close-x` (✕ button) in `css/style.css`.
- Applied to all 7 modals across `dashboard.html` and `admin.html` — the title bar with the ✕ now stays pinned at the top while the body scrolls; redundant bottom "Close" buttons were removed.

### 4. Role-based navigation guard (new: `js/route-guard.js`)
- Every page declares `data-page-role="public" | "auth" | "member" | "admin"` on `<body>`.
  - `public` (index.html, about.html) and `auth` (login.html): a signed-in member/admin is redirected to their own dashboard instead of browsing these pages.
  - `member` (dashboard.html, profile.html, apply-loan.html): no session → login.html; signed in as an admin → admin.html.
  - `admin` (admin.html): a signed-in member (non-admin) → dashboard.html; no session at all falls through to admin.html's own login form as before.
  - `loan-info.html` and `setup-password.html` are intentionally left unguarded — loan info is meant to be readable by members too, and setup-password relies on a temporary session from the invite link.
- Nav links tagged `data-nav="home"` or `data-nav="guest-only"` are hidden automatically once someone is signed in.
- This is the client-side half of access control only — the real protection remains Supabase's row-level security policies in `supabase/schema.sql`, which already scope every table to `auth.uid()` / `public.is_admin()`.

### Migration order for this update
Run, in order, on the existing Supabase project (all safe to re-run):
1. `supabase/migration_transaction_sync_cancel.sql` (if not already applied)
2. `supabase/migration_clear_history.sql` (new)

No SQL changes were needed for the payslip, close-button, or navigation work — those are front-end only.
