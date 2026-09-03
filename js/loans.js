/* Globals kept as "profile" and "myLoans" on purpose — js/loan-offset.js
   (loaded on this page too) reads these exact global names. */
let profile = null;
let myLoans = [];

const LOAN_TYPES_ICON = { real: "&#127968;", commodity: "&#128722;", education: "&#127891;" };

async function renderLoansPage() {
  profile = await requireMemberSession();
  if (!profile) return;
  myLoans = await getMyLoans();

  renderLoansTable();
  renderEligibility();
}

function renderEligibility() {
  const grid = document.getElementById("eligibilityCards");
  grid.innerHTML = Object.entries(LOAN_TYPES).map(([key, t]) => {
    const max = loanEligibleAmount(key, profile.savings_balance);
    const fee = t.feeRate > 0 ? formatNaira(Math.round(max * t.feeRate)) + ` ${t.feeLabel}` : "No extra fee";
    return `<div class="card">
      <div class="icon">${key === "real" ? "&#127968;" : key === "commodity" ? "&#128722;" : "&#129309;"}</div>
      <h3>${t.label}</h3>
      <p>${t.desc}</p>
      <div class="ledger-rows">
        <div class="ledger-row"><span>You're eligible for up to</span><span>${formatNaira(max)}</span></div>
        <div class="ledger-row"><span>Fee</span><span>${fee}</span></div>
        <div class="ledger-row"><span>Term</span><span>${t.duration} months</span></div>
      </div>
      <a href="apply-loan.html" class="btn btn-outline btn-sm" style="margin-top:14px;">Apply for this</a>
    </div>`;
  }).join("");
}

function renderProgress(status, declined) {
  if (declined) {
    return `<div style="font-size:11.5px;color:var(--danger);font-weight:600;">Declined at review stage</div>`;
  }
  const stepLabels = ["Submitted", "Approved", "Repaid"];
  const currentIdx = status === "pending" ? 0 : status === "approved" ? 1 : 2;
  return `<div style="display:flex;gap:4px;align-items:center;">
    ${stepLabels.map((label, i) => `
      <span title="${label}" style="width:9px;height:9px;border-radius:50%;background:${i <= currentIdx ? 'var(--green-600)' : 'var(--cream-dark)'};display:inline-block;"></span>
      ${i < stepLabels.length - 1 ? `<span style="width:14px;height:2px;background:${i < currentIdx ? 'var(--green-600)' : 'var(--cream-dark)'};display:inline-block;"></span>` : ""}
    `).join("")}
  </div>`;
}

function statusPill(status) {
  if (status === "approved") return `<span class="pill pill-ok">Approved</span>`;
  if (status === "declined") return `<span class="pill pill-bad">Declined</span>`;
  if (status === "completed") return `<span class="pill pill-ok">Completed</span>`;
  if (status === "offset") return `<span class="pill pill-wait">Offset / Closed</span>`;
  return `<span class="pill pill-wait">Under Review</span>`;
}

function statusPillText(status, workflowStatus) {
  if (status === "approved") return "Approved";
  if (status === "declined") return "Declined";
  if (status === "completed") return "Completed";
  if (status === "offset") return "Offset / Closed";
  const stageLabels = {
    awaiting_treasurer: "Awaiting Treasurer Review",
    returned_to_treasurer: "Returned to Treasurer",
    on_hold: "On Hold",
    awaiting_president: "Awaiting President Decision"
  };
  return stageLabels[workflowStatus] || "Under Review";
}

function renderLoansTable() {
  const body = document.getElementById("loansTableBody");
  if (!myLoans.length) {
    body.innerHTML = `<tr class="empty-row"><td colspan="8">You have no loan applications yet. <a href="apply-loan.html">Apply now &rarr;</a></td></tr>`;
    return;
  }
  body.innerHTML = myLoans.map(l => {
    const typeLabel = LOAN_TYPES[l.type] ? LOAN_TYPES[l.type].label : l.type;
    const action = l.status === "approved"
      ? `<span style="font-size:12px;color:var(--ink-soft)">Deductions are recorded by the admin</span>`
      : (l.status === "declined" ? `<span style="font-size:12px;color:var(--ink-soft)">${l.decline_reason || ""}</span>` : "—");
    return `<tr>
      <td class="mono-cell">${l.id}</td>
      <td>${typeLabel}</td>
      <td class="mono-cell">${formatNaira(l.amount)}</td>
      <td class="mono-cell">${l.status === "approved" ? formatNaira(l.balance) : "—"}</td>
      <td class="mono-cell">${l.status === "approved" ? formatNaira(l.monthly_deduction) : "—"}</td>
      <td>${renderProgress(l.status, l.status === "declined")} <span style="font-size:11px;color:var(--ink-soft)">${statusPillText(l.status, l.workflow_status)}</span></td>
      <td>${formatDate(l.date_applied)}</td>
      <td>${action}</td>
    </tr>`;
  }).join("");
}

function showLoanDetails() {
  const active = myLoans.filter(l => l.status === "approved");
  const box = document.getElementById("loanDetailsContent");
  if (!active.length) box.innerHTML = '<p class="lede">You have no active loans.</p>';
  else box.innerHTML = active.map(l => {
    const charge = Number(l.admin_charge) || 0;
    const total = Number(l.amount) + charge;
    return `<div class="card" style="margin:12px 0;"><h4>${LOAN_TYPES[l.type]?.label || l.type} — ${l.id}</h4>
      <div class="ledger-rows">
      <div class="ledger-row"><span>Loan amount</span><span>${formatNaira(l.amount)}</span></div>
      <div class="ledger-row"><span>Commodity charge (10%)</span><span>${formatNaira(charge)}</span></div>
      <div class="ledger-row"><span>Total loan obligation</span><span>${formatNaira(total)}</span></div>
      <div class="ledger-row"><span>Amount repaid</span><span>${formatNaira(Math.max(0,total-(Number(l.balance)||0)))}</span></div>
      <div class="ledger-row"><span>Outstanding balance</span><span>${formatNaira(l.balance)}</span></div>
      <div class="ledger-row"><span>Monthly deduction</span><span>${formatNaira(l.monthly_deduction)}</span></div>
      <div class="ledger-row"><span>Duration</span><span>${l.duration} months</span></div>
      <div class="ledger-row"><span>Status</span><span>${statusPill(l.status)}</span></div>
      </div></div>`;
  }).join('');
  document.getElementById("loanDetailsModal").hidden = false;
}
function closeLoanDetails() { document.getElementById("loanDetailsModal").hidden = true; }

document.addEventListener("DOMContentLoaded", async () => {
  renderLoansPage();
  const logoutBtn = document.getElementById("logoutBtn");
  if (logoutBtn) logoutBtn.addEventListener("click", async () => { await logoutUser(); window.location.href = "index.html?loggedout=1"; });
  const refresh = debounce(renderLoansPage, 400);
  const user = await getSessionUser();
  if (user) {
    subscribeToLoansTable(refresh, `member_id=eq.${user.id}`);
    subscribeToProfilesTable(refresh, `id=eq.${user.id}`);
  }
  setInterval(renderLoansPage, 45000);
  if (location.hash === "#eligibility") {
    setTimeout(() => document.getElementById("eligibility")?.scrollIntoView({ behavior: "smooth" }), 400);
  }
});
