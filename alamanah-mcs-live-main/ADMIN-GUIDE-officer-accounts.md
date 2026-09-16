# Setting up officers correctly (and fixing old TREAS-001-style accounts)

## The problem this fixes

SETUP.md's original "Create your first admin account" step told you to
insert a brand-new `profiles` row with a placeholder Al-Amanah No. like
`ADMIN-001` or `TREAS-001`:

```sql
insert into profiles (id, alamanah_no, surname, first_name, is_admin)
select id, 'ADMIN-001', 'Admin', 'Society', true
from auth.users where email = '...';
```

That works fine for someone who is *only* an admin and never a member.
But your management committee members are ALSO real members — they have
their own real Al-Amanah No., their own savings balance, their own loan
history. If you gave them a placeholder account like `TREAS-001` instead
of promoting their real member account, that officer now has **two
disconnected identities**: their real membership (with real savings/loans,
sitting unused) and a fake `TREAS-001` profile (with zero savings, used only
for portal access). "View as Member" on that fake account shows an empty,
wrong member record — not their real one.

## The correct workflow going forward

Never create a new placeholder profile for an officer who is already a
member. Instead, from **Admin Portal → Management Team → Assign a role to
a member**:

1. Enter their **real** Al-Amanah No. (the one tied to their actual savings
   and loan history) and pick the role. This calls `admin_set_role` on
   their EXISTING profile — nothing about their savings, loans, or Al-Amanah
   No. changes. They just gain officer access on top of their existing
   membership.
2. In the same table, click **"Set Sign-in Email"** next to their name and
   give them a real email address. This is the piece that was missing
   before: their member account was created with a generated placeholder
   email (e.g. `al0234@members.alamanahmcs.local`) that they don't know and
   can't type into the officer/admin login screen. Setting a real email
   here lets them log in at `treasurer.html` / `secretary.html` /
   `president.html` / `admin.html` with an address they actually have,
   while keeping the same underlying account (same Al-Amanah No., same
   member data).
3. Tell them their new sign-in email + their existing password (the one
   they set at `setup-password.html` when they first joined as a member).
   If they've never set a password as a member, have them do that first at
   `setup-password.html` using their Al-Amanah No. + surname, *then*
   promote them and set their officer email.

This requires `supabase/migration_set_officer_email.sql` to have been run
once (needs `migration_activity_log_and_issues.sql` first, same as the
existing role-management migration).

## Fixing an existing TREAS-001 / ADMIN-001 style account

If the officer's real savings and loans are sitting on this SAME
placeholder profile (they were only ever set up this way — they never
separately self-registered as a member), the fix is simple:

1. In **Management Team**, find their row — a **"Placeholder"** tag
   appears next to any Al-Amanah No. that doesn't start with `AL/`.
2. Click **"Fix Al-Amanah No."** and enter their real number. This only
   changes the number field — their savings, loans, and role are
   untouched. This requires `migration_fix_officer_alamanah_no.sql`
   (see below).
3. Make sure they also have a sign-in email set (step 2 above), so they
   can keep using their portal.

If instead their real Al-Amanah No. already belongs to a SEPARATE,
already-existing member profile (they self-registered as a member first,
*then* someone created a second placeholder profile for their officer
access — two disconnected records), don't use "Fix Al-Amanah No." on the
placeholder, since the number is already taken by the real profile.
Instead:

1. Promote the REAL profile to the correct role (step 1 above), on the
   already-existing member record.
2. Set a real sign-in email on that REAL profile (step 2 above).
3. Have them log in once with the new email + their real member password
   to confirm it lands them on the right portal.
4. The old placeholder profile is now redundant. If it has no real
   savings or loan history attached (it shouldn't), remove it from
   **Members → [find it] → View member → Danger Zone → Expunge Member**.
   Double-check all balances shown are ₦0 first.

## Logging back in as a member after a role is reassigned

Once someone's role changes back to `member` (or to someone else
entirely), they log in exactly like any other member: `login.html`, their
real `AL/…` number, and the same password they already use. This works
correctly even though their account's real sign-in email is a personal
address (set via "Set Sign-in Email") rather than the generated
`al0234@members.alamanahmcs.local` pattern — `migration_fix_officer_alamanah_no.sql`
also adds a lookup so Member Login resolves whichever email is actually on
file for that Al-Amanah No., instead of assuming the generated format.

## Why this doesn't need a code change

`admin_set_role` already worked on real, existing profiles — the CSV
template in SETUP.md just pointed people toward creating a *new* row
instead of reusing one. Nothing about the schema needed to change; the
only genuinely missing pieces were a way to give an existing member
account a real sign-in email (`admin_set_profile_email`), a way to
correct a placeholder Al-Amanah No. in place (`admin_update_alamanah_no`),
and a way for Member Login to resolve the right email for either case
(`email_for_alamanah_no`) — all three now live in
`migration_set_officer_email.sql` and `migration_fix_officer_alamanah_no.sql`.

## Making password-reset emails say "Al-Amanah MCS" instead of Supabase

This part can't be shipped as code — it's a Supabase Dashboard setting.
By default, Supabase sends auth emails (password reset, etc.) from its own
shared mail service, which shows up to members as coming from something
like `noreply@mail.app.supabase.io`, with a generic "Reset Password"
template that doesn't mention your society by name. To fix that:

1. **Authentication → Settings → SMTP Settings** (or "Custom SMTP",
   depending on your Supabase dashboard version). Turn on custom SMTP and
   connect your own sending service — e.g. a Google Workspace account,
   Zoho Mail, SendGrid, Resend, or similar. Set:
   - **Sender name:** `Al-Amanah MCS`
   - **Sender email:** something on your own domain if you have one (e.g.
     `no-reply@alamanahmcs.org`), otherwise whatever real inbox you're
     sending through.
2. **Authentication → Email Templates → Reset Password.** Replace the
   default template's subject and body with your own wording — e.g.
   subject `Reset your Al-Amanah MCS password`, and a body that mentions
   the society by name instead of the generic default text. Keep the
   `{{ .ConfirmationURL }}` placeholder in the button/link — that's what
   points the member to `reset-password.html` on your live site.
3. **Authentication → URL Configuration → Site URL.** Set this to your
   real deployed site (e.g. `https://highbsmart.github.io/alamanah-mcs-live/`
   or your real domain once you have one) so the link in the email lands
   on your branded pages, not a raw Supabase or localhost address.

Until custom SMTP is configured, reset emails will still work (the link
and flow built into the site function correctly) — they'll just visibly
come from Supabase's shared sender rather than looking like they're from
Al-Amanah MCS.
