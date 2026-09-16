/* Dashboard = slim overview only. Full sections (savings, loans,
   transactions, payslip) live on their own dedicated pages now —
   see js/savings.js, js/loans.js, js/transactions.js, js/payslip.js */

async function renderDashboard() {
  const profile = await requireMemberSession();
  if (!profile) return;

  const myLoans = await getMyLoans();
  const summary = memberSummary(profile, myLoans);

  document.getElementById("dashAlaNo").textContent = profile.alamanah_no;
  document.getElementById("dashWelcome").textContent = `Welcome, ${profile.first_name} ${profile.surname}`;
  document.getElementById("dashDept").textContent = profile.department || "";

  document.getElementById("savingsAmount").textContent = formatNaira(profile.savings_balance);

  const statusPill = document.getElementById("statusPill");
  if (profile.status === "active") { statusPill.textContent = "Active"; statusPill.className = "pill pill-ok"; }
  else if (profile.status === "retired") { statusPill.textContent = "Retired"; statusPill.className = "pill pill-wait"; }
  else { statusPill.textContent = "Dismissed"; statusPill.className = "pill pill-bad"; }

  document.getElementById("loanBalanceAmount").textContent = formatNaira(summary.totalOriginalObligation);
  document.getElementById("loanCountPill").textContent = `${summary.approvedLoans.length} active`;
  document.getElementById("availableAmount").textContent = formatNaira(summary.availableLoanBalance);
  document.getElementById("availableCountPill").textContent = `${summary.approvedLoans.length} loan${summary.approvedLoans.length === 1 ? "" : "s"}`;
}

document.addEventListener("DOMContentLoaded", async () => {
  renderDashboard();
  const logoutBtn = document.getElementById("logoutBtn");
  if (logoutBtn) logoutBtn.addEventListener("click", async () => { await logoutUser(); window.location.href = "index.html?loggedout=1"; });
  if (new URLSearchParams(location.search).get("applied") === "1") {
    toast("Loan application submitted successfully and is currently under review.");
    // Strip the flag so refreshing this page doesn't show the same
    // "submitted successfully" toast again — it should only appear
    // once, right after the actual submission.
    history.replaceState(null, "", location.pathname);
  }
  // Debounced + scoped to this member only: a burst of updates
  // collapses into one re-render, and other members' changes no
  // longer trigger a re-render here at all.
  const refresh = debounce(renderDashboard, 400);
  const user = await getSessionUser();
  if (user) {
    subscribeToLoansTable(refresh, `member_id=eq.${user.id}`);
    subscribeToProfilesTable(refresh, `id=eq.${user.id}`);
  }
  setInterval(renderDashboard, 45000);
});
