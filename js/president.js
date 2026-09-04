/* =========================================================
   President portal — real content (Step 9).
   Loaded only on president.html. Hooks into officer-portal.js
   via window.onOfficerReady, which fires once login succeeds.
   ========================================================= */
window.onOfficerReady = function () {
  loadPresidentQueue();
  loadPresidentHistory();
};

let currentDecisionLoanId = null;

async function loadPresidentQueue() {
  const body = document.getElementById("presidentQueueBody");
  body.innerHTML = `<tr class="empty-row"><td colspan="5">Loading…</td></tr>`;
  try {
    const loans = await getOfficerQueue(["awaiting_president"]);
    document.getElementById("presidentQueueCount").textContent = loans.length;
    if (!loans.length) {
      body.innerHTML = `<tr class="empty-row"><td colspan="5">No applications awaiting your decision right now.</td></tr>`;
      return;
    }
    body.innerHTML = loans.map(loan => `
      <tr>
        <td>${(loan.profiles?.first_name || "")} ${(loan.profiles?.surname || "")}<div class="hint">${loan.profiles?.alamanah_no || ""}</div></td>
        <td>${capitalize(loan.type)}</td>
        <td>${formatNaira(loan.amount)}</td>
        <td>${loan.date_applied}</td>
        <td><button class="btn btn-primary btn-sm" onclick="openDecisionModal('${loan.id}')">Review</button></td>
      </tr>
    `).join("");
  } catch (err) {
    body.innerHTML = `<tr class="empty-row"><td colspan="5">Could not load queue: ${err.message}</td></tr>`;
  }
}

function capitalize(s) { return s ? s.charAt(0).toUpperCase() + s.slice(1) : s; }

function eligibilityBadge(status) {
  const map = {
    eligible:                { cls: "pill-ok",  label: "ELIGIBLE" },
    not_eligible:             { cls: "pill-bad", label: "NOT ELIGIBLE" },
    needs_more_information:  { cls: "pill-wait", label: "NEEDS MORE INFORMATION" },
    on_hold:                 { cls: "pill-wait", label: "ON HOLD" }
  };
  const m = map[status] || { cls: "pill-wait", label: status };
  return `<span class="pill ${m.cls}">${m.label}</span>`;
}

async function openDecisionModal(loanId) {
  currentDecisionLoanId = loanId;
  const box = document.getElementById("decisionModalBody");
  box.innerHTML = `<p class="hint">Loading application…</p>`;
  document.getElementById("decisionModal").hidden = false;

  try {
    const [summary, assessment, vetting] = await Promise.all([
      getLoanFinancialSummary(loanId),
      getAssessmentForLoan(loanId),
      getVettingForLoan(loanId)
    ]);

    const eligibilityLabels = {
      eligible: "ELIGIBLE",
      not_eligible: "NOT ELIGIBLE",
      needs_more_information: "NEEDS MORE INFORMATION",
      on_hold: "ON HOLD"
    };

    box.innerHTML = `
      <div class="stat-strip" style="grid-template-columns:1fr 1fr;margin-bottom:20px;">
        <div class="stat-card"><div class="hint">Member</div><div style="font-weight:700;">${summary.member_name}</div><div class="hint">${summary.alamanah_no}</div></div>
        <div class="stat-card"><div class="hint">Request</div><div style="font-weight:700;">${capitalize(summary.loan_type)} Loan — ${formatNaira(summary.amount)}</div><div class="hint">${summary.duration} months</div></div>
        <div class="stat-card"><div class="hint">Savings Balance</div><div style="font-weight:700;">${formatNaira(summary.savings_balance)}</div></div>
        <div class="stat-card"><div class="hint">Projected New Deduction</div><div style="font-weight:700;">${formatNaira(summary.projected_new_deduction)}</div></div>
      </div>

      <div class="form-note" style="margin-bottom:14px;">
        <strong>Bursary Officer's Vetting</strong><br>
        ${vetting
          ? `Result: ${eligibilityBadge(vetting.eligibility_status)}<br>
             Gross Pay: ${formatNaira(vetting.gross_pay)} &middot; Other Deductions: ${formatNaira(vetting.other_monthly_deductions)} &middot; Net Pay (calculated): ${formatNaira(vetting.net_pay)}<br>
             After existing cooperative deductions (${formatNaira(vetting.existing_monthly_deductions)}) and this loan (${formatNaira(vetting.proposed_monthly_deduction)}), ${formatNaira(vetting.net_pay_after_deductions)} would remain — required minimum is 1/3 of Gross Pay (${formatNaira(vetting.one_third_gross_limit)})<br>
             Note: ${vetting.note}`
          : `<span class="pill pill-wait">NOT YET SUBMITTED</span>`}
      </div>

      <div class="form-note" style="margin-bottom:20px;">
        <strong>Treasurer's Assessment</strong><br>
        Eligibility: ${assessment ? eligibilityBadge(assessment.eligibility_status) : `<span class="pill pill-wait">NOT YET SUBMITTED</span>`}<br>
        Recommendation: ${assessment ? assessment.recommendation : "—"}<br>
        Note: ${assessment ? assessment.assessment_note : "—"}
      </div>

      <form id="decisionForm">
        <div class="field">
          <label for="decisionChoice">Your decision</label>
          <select id="decisionChoice" required onchange="toggleReturnReason(this.value)">
            <option value="">— Select —</option>
            <option value="approved">Approve</option>
            <option value="declined">Decline</option>
            <option value="returned_to_treasurer">Return to Treasurer</option>
            <option value="on_hold">Put on Hold</option>
          </select>
        </div>
        <div class="field" id="returnReasonField" style="display:none;">
          <label for="returnReason">Reason for returning to Treasurer</label>
          <textarea id="returnReason" rows="3" placeholder="What needs to be re-checked or clarified?"></textarea>
        </div>
        <div class="field">
          <label for="decisionNote">Note (optional, shown in the decision record)</label>
          <textarea id="decisionNote" rows="3"></textarea>
        </div>
        <div class="form-error" id="decisionError"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-ghost" onclick="closeDecisionModal()">Cancel</button>
          <button type="submit" class="btn btn-primary" id="decisionSubmitBtn">Submit Decision</button>
        </div>
      </form>
    `;
    document.getElementById("decisionForm").addEventListener("submit", handleDecisionSubmit);
  } catch (err) {
    box.innerHTML = `<p class="form-error show">Could not load this application: ${err.message}</p>`;
  }
}

function toggleReturnReason(decision) {
  document.getElementById("returnReasonField").style.display = decision === "returned_to_treasurer" ? "" : "none";
}

async function handleDecisionSubmit(e) {
  e.preventDefault();
  const decision = document.getElementById("decisionChoice").value;
  const note = document.getElementById("decisionNote").value.trim();
  const returnReason = document.getElementById("returnReason") ? document.getElementById("returnReason").value.trim() : "";
  const errBox = document.getElementById("decisionError");
  const btn = document.getElementById("decisionSubmitBtn");
  errBox.classList.remove("show");

  btn.disabled = true; btn.textContent = "Submitting…";
  try {
    await submitPresidentDecision(currentDecisionLoanId, decision, note, returnReason);
    closeDecisionModal();
    toast("Decision recorded.");
    loadPresidentQueue();
  } catch (err) {
    errBox.textContent = err.message || "Could not submit decision.";
    errBox.classList.add("show");
  }
  btn.disabled = false; btn.textContent = "Submit Decision";
}

function closeDecisionModal() {
  document.getElementById("decisionModal").hidden = true;
  currentDecisionLoanId = null;
}

async function loadPresidentHistory() {
  const body = document.getElementById("presidentHistoryBody");
  if (!body) return;
  try {
    const me = await getMyProfile();
    const { data, error } = await supabaseClient
      .from("loan_decisions")
      .select("*, loans(id, type, amount, profiles(alamanah_no, surname, first_name))")
      .eq("president_id", me.id)
      .order("created_at", { ascending: false })
      .limit(20);
    if (error) throw error;
    if (!data.length) {
      body.innerHTML = `<tr class="empty-row"><td colspan="5">You haven't recorded any decisions yet.</td></tr>`;
      return;
    }
    body.innerHTML = data.map(d => `
      <tr>
        <td>${new Date(d.created_at).toLocaleString()}</td>
        <td>${d.loans?.profiles ? `${d.loans.profiles.first_name} ${d.loans.profiles.surname}` : d.loan_id}</td>
        <td>${d.loans ? `${capitalize(d.loans.type)} — ${formatNaira(d.loans.amount)}` : "—"}</td>
        <td>${decisionPillFor(d.decision)}</td>
        <td>${d.decision_note || d.returned_reason || "—"}</td>
      </tr>
    `).join("");
  } catch (err) {
    body.innerHTML = `<tr class="empty-row"><td colspan="5">Could not load history: ${err.message}</td></tr>`;
  }
}

function decisionPillFor(decision) {
  const map = {
    approved: { cls: "pill-ok", label: "Approved" },
    declined: { cls: "pill-bad", label: "Declined" },
    returned_to_treasurer: { cls: "pill-wait", label: "Returned" },
    on_hold: { cls: "pill-wait", label: "On Hold" }
  };
  const m = map[decision] || { cls: "pill-wait", label: decision };
  return `<span class="pill ${m.cls}">${m.label}</span>`;
}
