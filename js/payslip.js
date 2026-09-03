let profile = null;
let myLoans = [];

async function renderPayslip() {
  const month = document.getElementById("payslipMonth").value; // "YYYY-MM"
  const box = document.getElementById("payslipContent");
  if (!month) { box.innerHTML = '<p class="lede">Choose a month above.</p>'; return; }
  box.innerHTML = '<p class="lede">Loading payslip…</p>';

  const [y, m] = month.split("-");
  const monthLabel = new Date(Number(y), Number(m) - 1, 1).toLocaleDateString("en-GB", { month: "long", year: "numeric" });

  let override = null;
  try { override = await getPayslipOverride(profile.id, month); } catch (err) { /* fall back to computed figures */ }

  let savings, adminCharge, loanRows, noteHtml = "";
  if (override) {
    savings = Number(override.savings_contribution) || 0;
    adminCharge = Number(override.admin_charge) || 0;
    loanRows = (Array.isArray(override.loan_rows) ? override.loan_rows : []).map(r => ({ label: r.label, amt: Number(r.amount) || 0 }));
    if (override.note) noteHtml = `<p class="lede" style="margin-top:10px;font-size:12px;">${escapeHtml(override.note)}</p>`;
  } else {
    savings = Number(profile.monthly_savings_amount) || 0;
    adminCharge = Math.round(savings * ADMIN_SAVINGS_CHARGE_RATE);
    const activeLoans = myLoans.filter(l => l.status === "approved");
    loanRows = activeLoans.map(l => ({
      label: `${LOAN_TYPES[l.type] ? LOAN_TYPES[l.type].label : l.type}`,
      amt: Number(l.monthly_deduction) || 0
    })).filter(r => r.amt > 0);
  }
  const loanDeducted = loanRows.reduce((s, r) => s + r.amt, 0);
  const savingsTotal = savings + adminCharge;
  const total = savingsTotal + loanDeducted;

  box.innerHTML = `
    <div id="payslipPrintArea" class="payslip-doc">
      <div class="payslip-letterhead">
        <h2>Al-Amanah Multi-Purpose Co-operative Society</h2>
        <p>Monthly Deduction Payslip — ${monthLabel}</p>
      </div>

      <div class="payslip-meta">
        <div class="payslip-meta-row"><span>Member</span><span>${profile.first_name} ${profile.surname}</span></div>
        <div class="payslip-meta-row"><span>Al-Amanah No.</span><span>${profile.alamanah_no}</span></div>
        <div class="payslip-meta-row"><span>Department</span><span>${profile.department || "—"}</span></div>
      </div>

      <div class="payslip-section">
        <div class="payslip-section-title">Savings</div>
        <div class="payslip-line"><span>Monthly Savings</span><span>${formatNaira(savings)}</span></div>
        <div class="payslip-line"><span>Administrative Charge (7.5%)</span><span>${formatNaira(adminCharge)}</span></div>
        <div class="payslip-line payslip-subtotal"><span>Savings Total</span><span>${formatNaira(savingsTotal)}</span></div>
      </div>

      <div class="payslip-section">
        <div class="payslip-section-title">Active Loans</div>
        ${loanRows.length
          ? loanRows.map(r => `<div class="payslip-line"><span>${r.label}</span><span>${formatNaira(r.amt)}</span></div>`).join("")
          : `<div class="payslip-line"><span>No active loans</span><span>—</span></div>`}
        <div class="payslip-line payslip-subtotal"><span>Total Active Loan Deduction</span><span>${formatNaira(loanDeducted)}</span></div>
      </div>

      <div class="payslip-grand-total">
        <span>Total Cooperative Deduction</span><span>${formatNaira(total)}</span>
      </div>

      ${noteHtml}
      <p class="payslip-footer-note">Generated on ${formatDate(new Date().toISOString().slice(0, 10))}</p>
    </div>`;
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

function printPayslip() {
  window.print();
}

async function initPayslipPage() {
  profile = await requireMemberSession();
  if (!profile) return;
  myLoans = await getMyLoans();

  const monthInput = document.getElementById("payslipMonth");
  if (!monthInput.value) monthInput.value = new Date().toISOString().slice(0, 7);
  renderPayslip();
}

document.addEventListener("DOMContentLoaded", () => {
  initPayslipPage();
  const logoutBtn = document.getElementById("logoutBtn");
  if (logoutBtn) logoutBtn.addEventListener("click", async () => { await logoutUser(); window.location.href = "index.html?loggedout=1"; });
});
