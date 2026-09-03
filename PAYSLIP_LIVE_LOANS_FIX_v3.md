# Payslip Live Loans Fix V3

The payslip now fetches fresh data every time it is generated:

- Member profile: live
- Savings/passbook transactions: live
- Loans: live

The payslip no longer depends on the `myLoans` values previously loaded when the dashboard first opened. When a member opens or changes the payslip month, the system calls `getMyLoans()` again and rebuilds the active loan rows from the latest database values.

Included loan statuses: `approved` and `active`.
Only loans with a positive `monthly_deduction` are included in the total active loan deduction.

This is a frontend-only synchronization fix; no Supabase SQL migration is required for this specific change.
