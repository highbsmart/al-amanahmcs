/* =========================================================
   Treasurer portal — real content (Step 8).
   Loaded only on treasurer.html. Hooks into officer-portal.js
   via window.onOfficerReady, which fires once login succeeds.
   ========================================================= */
window.onOfficerReady = function () {
  loadTreasurerQueue();
  loadTreasurerHistory();
  loadManualOffsetQueue();
};

let currentAssessmentLoanId = null;

async function loadTreasurerQueue() {
  const body = document.getElementById("treasurerQueueBody");
  body.innerHTML = `<tr class="empty-row"><td colspan="6">Loading…</td></tr>`;
  try {
    const loans = await getOfficerQueue(["awaiting_treasurer", "returned_to_treasurer", "on_hold"]);
    document.getElementById("treasurerQueueCount").textContent = loans.length;
    if (!loans.length) {
      body.innerHTML = `<tr class="empty-row"><td colspan="6">No applications waiting for assessment right now.</td></tr>`;
      return;
    }
    body.innerHTML = loans.map(loan => `
      <tr>
        <td>${(loan.profiles?.first_name || "")} ${(loan.profiles?.surname || "")}<div class="hint">${loan.profiles?.alamanah_no || ""}</div></td>
        <td>${capitalize(loan.type)}</td>
        <td>${formatNaira(loan.amount)}</td>
        <td>${loan.date_applied}</td>
        <td>${workflowBadge(loan.workflow_status)}</td>
        <td><button class="btn btn-primary btn-sm" onclick="openAssessmentModal('${loan.id}')">Review</button></td>
      </tr>
    `).join("");
  } catch (err) {
    body.innerHTML = `<tr class="empty-row"><td colspan="6">Could not load queue: ${err.message}</td></tr>`;
  }
}

function workflowBadge(status) {
  const map = {
    awaiting_treasurer:    { cls: "pill-wait", label: "Awaiting assessment" },
    returned_to_treasurer: { cls: "pill-bad",  label: "Returned by President" },
    on_hold:               { cls: "pill-bad",  label: "On hold" }
  };
  const m = map[status] || { cls: "pill-wait", label: status };
  return `<span class="pill ${m.cls}">${m.label}</span>`;
}

function capitalize(s) { return s ? s.charAt(0).toUpperCase() + s.slice(1) : s; }

function vettingBadge(status) {
  const map = {
    eligible: { cls: "pill-ok", label: "ELIGIBLE" },
    not_eligible: { cls: "pill-bad", label: "NOT ELIGIBLE" },
    needs_more_information: { cls: "pill-wait", label: "NEEDS MORE INFORMATION" },
    on_hold: { cls: "pill-wait", label: "ON HOLD" }
  };
  const m = map[status] || { cls: "pill-wait", label: status };
  return `<span class="pill ${m.cls}">${m.label}</span>`;
}

async function openAssessmentModal(loanId) {
  currentAssessmentLoanId = loanId;
  const box = document.getElementById("assessmentModalBody");
  box.innerHTML = `<p class="hint">Loading financial position…</p>`;
  document.getElementById("assessmentModal").hidden = false;

  try {
    const [summary, vetting] = await Promise.all([
      getLoanFinancialSummary(loanId),
      getVettingForLoan(loanId)
    ]);
    box.innerHTML = `
      <div class="stat-strip" style="grid-template-columns:1fr 1fr;margin-bottom:20px;">
        <div class="stat-card"><div class="hint">Member</div><div style="font-weight:700;">${summary.member_name}</div><div class="hint">${summary.alamanah_no}</div></div>
        <div class="stat-card"><div class="hint">Request</div><div style="font-weight:700;">${capitalize(summary.loan_type)} Loan — ${formatNaira(summary.amount)}</div><div class="hint">${summary.duration} months</div></div>
        <div class="stat-card"><div class="hint">Savings Balance</div><div style="font-weight:700;">${formatNaira(summary.savings_balance)}</div></div>
        <div class="stat-card"><div class="hint">Monthly Savings</div><div style="font-weight:700;">${formatNaira(summary.monthly_savings)}</div></div>
        <div class="stat-card"><div class="hint">Active Loan Deductions</div><div style="font-weight:700;">${formatNaira(summary.active_loan_deductions)}</div></div>
        <div class="stat-card"><div class="hint">Projected New Deduction</div><div style="font-weight:700;">${formatNaira(summary.projected_new_deduction)}</div></div>
      </div>
      <p class="hint" style="margin-bottom:16px;"><strong>Purpose:</strong> ${summary.purpose}</p>

      <div class="form-note" style="margin-bottom:20px;">
        <strong>Bursary Officer's Vetting</strong><br>
        ${vetting
          ? `Result: ${vettingBadge(vetting.eligibility_status)}<br>
             Gross Pay: ${formatNaira(vetting.gross_pay)} &middot; Other Deductions: ${formatNaira(vetting.other_monthly_deductions)} &middot; Net Pay (calculated): ${formatNaira(vetting.net_pay)}<br>
             After existing cooperative deductions (${formatNaira(vetting.existing_monthly_deductions)}) and this loan (${formatNaira(vetting.proposed_monthly_deduction)}), ${formatNaira(vetting.net_pay_after_deductions)} would remain — required minimum is 1/3 of Gross Pay (${formatNaira(vetting.one_third_gross_limit)})<br>
             Note: ${vetting.note}`
          : `<span class="pill pill-wait">NOT YET SUBMITTED</span>`}
      </div>

      <form id="assessmentForm">
        <div class="field">
          <label for="assessmentEligibility">Assessment</label>
          <select id="assessmentEligibility" required>
            <option value="">— Select —</option>
            <option value="eligible">Eligible — Recommend Approval</option>
            <option value="not_eligible">Not Eligible — Recommend Rejection</option>
            <option value="needs_more_information">Needs More Information</option>
            <option value="on_hold">Put on Hold</option>
          </select>
        </div>
        <div class="field">
          <label for="assessmentRecommendation">Recommendation (short)</label>
          <input type="text" id="assessmentRecommendation" placeholder="e.g. Approve, Reject, Hold pending payslip" required>
        </div>
        <div class="field">
          <label for="assessmentNote">Assessment note</label>
          <textarea id="assessmentNote" rows="4" required placeholder="Explain the basis for this assessment…"></textarea>
        </div>
        <div class="form-error" id="assessmentError"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-ghost" onclick="closeAssessmentModal()">Cancel</button>
          <button type="submit" class="btn btn-primary" id="assessmentSubmitBtn">Submit Assessment</button>
        </div>
      </form>
    `;
    document.getElementById("assessmentForm").addEventListener("submit", handleAssessmentSubmit);
  } catch (err) {
    box.innerHTML = `<p class="form-error show">Could not load this application: ${err.message}</p>`;
  }
}

async function handleAssessmentSubmit(e) {
  e.preventDefault();
  const eligibility = document.getElementById("assessmentEligibility").value;
  const recommendation = document.getElementById("assessmentRecommendation").value.trim();
  const note = document.getElementById("assessmentNote").value.trim();
  const errBox = document.getElementById("assessmentError");
  const btn = document.getElementById("assessmentSubmitBtn");
  errBox.classList.remove("show");

  btn.disabled = true; btn.textContent = "Submitting…";
  try {
    await submitTreasurerAssessment(currentAssessmentLoanId, eligibility, recommendation, note);
    closeAssessmentModal();
    toast("Assessment submitted.");
    loadTreasurerQueue();
  } catch (err) {
    errBox.textContent = err.message || "Could not submit assessment.";
    errBox.classList.add("show");
  }
  btn.disabled = false; btn.textContent = "Submit Assessment";
}

function closeAssessmentModal() {
  document.getElementById("assessmentModal").hidden = true;
  currentAssessmentLoanId = null;
}

async function loadTreasurerHistory() {
  const body = document.getElementById("treasurerHistoryBody");
  if (!body) return;
  try {
    const me = await getMyProfile();
    const { data, error } = await supabaseClient
      .from("loan_assessments")
      .select("*, loans(id, type, amount, profiles(alamanah_no, surname, first_name))")
      .eq("treasurer_id", me.id)
      .order("created_at", { ascending: false })
      .limit(20);
    if (error) throw error;
    if (!data.length) {
      body.innerHTML = `<tr class="empty-row"><td colspan="5">You haven't submitted any assessments yet.</td></tr>`;
      return;
    }
    body.innerHTML = data.map(a => `
      <tr>
        <td>${new Date(a.created_at).toLocaleString()}</td>
        <td>${a.loans?.profiles ? `${a.loans.profiles.first_name} ${a.loans.profiles.surname}` : a.loan_id}</td>
        <td>${a.loans ? `${capitalize(a.loans.type)} — ${formatNaira(a.loans.amount)}` : "—"}</td>
        <td>${eligibilityPillFor(a.eligibility_status)}</td>
        <td>${a.assessment_note}</td>
      </tr>
    `).join("");
  } catch (err) {
    body.innerHTML = `<tr class="empty-row"><td colspan="5">Could not load history: ${err.message}</td></tr>`;
  }
}

function eligibilityPillFor(status) {
  const map = {
    eligible: { cls: "pill-ok", label: "Eligible" },
    not_eligible: { cls: "pill-bad", label: "Not Eligible" },
    needs_more_information: { cls: "pill-wait", label: "Needs Info" },
    on_hold: { cls: "pill-wait", label: "On Hold" }
  };
  const m = map[status] || { cls: "pill-wait", label: status };
  return `<span class="pill ${m.cls}">${m.label}</span>`;
}

// ---------------------------------------------------------
// Manual / offline offset payment confirmations
// ---------------------------------------------------------
let currentManualOffsetId = null;

async function loadManualOffsetQueue() {
  const body = document.getElementById("manualOffsetQueueBody");
  if (!body) return;
  try {
    const requests = await getPendingManualOffsetRequests();
    if (!requests.length) {
      body.innerHTML = `<tr class="empty-row"><td colspan="6">No pending direct-payment requests right now.</td></tr>`;
      return;
    }
    body.innerHTML = requests.map(r => `
      <tr>
        <td>${r.profiles ? `${r.profiles.first_name} ${r.profiles.surname}` : "—"}<div class="hint">${r.profiles?.alamanah_no || ""}</div></td>
        <td>${(r.loan_offset_request_items || []).map(i => capitalize(i.loan_type)).join(", ")}</td>
        <td>${formatNaira(r.total_amount)}</td>
        <td>${new Date(r.created_at).toLocaleString()}</td>
        <td class="mono-cell">${r.request_reference}</td>
        <td><button class="btn btn-primary btn-sm" onclick="openManualOffsetConfirm('${r.id}')">Confirm Payment Received</button></td>
      </tr>
    `).join("");
  } catch (err) {
    body.innerHTML = `<tr class="empty-row"><td colspan="6">Could not load: ${err.message}</td></tr>`;
  }
}

function openManualOffsetConfirm(id) {
  currentManualOffsetId = id;
  document.getElementById("manualOffsetConfirmError").classList.remove("show");
  document.getElementById("manualOffsetConfirmForm").reset();
  document.getElementById("manualOffsetConfirmModal").hidden = false;
}

function closeManualOffsetConfirm() {
  document.getElementById("manualOffsetConfirmModal").hidden = true;
  currentManualOffsetId = null;
}

document.addEventListener("DOMContentLoaded", () => {
  document.getElementById("manualOffsetConfirmForm").addEventListener("submit", async (e) => {
    e.preventDefault();
    const note = document.getElementById("manualOffsetNote").value.trim();
    const errBox = document.getElementById("manualOffsetConfirmError");
    const btn = document.getElementById("manualOffsetConfirmSubmitBtn");
    errBox.classList.remove("show");
    btn.disabled = true; btn.textContent = "Confirming…";
    try {
      await confirmManualOffsetPayment(currentManualOffsetId, note);
      closeManualOffsetConfirm();
      toast("Payment confirmed — loan closed.");
      loadManualOffsetQueue();
    } catch (err) {
      errBox.textContent = err.message || "Could not confirm this payment.";
      errBox.classList.add("show");
    }
    btn.disabled = false; btn.textContent = "Confirm & Close Loan";
  });
});
