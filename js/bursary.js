/* =========================================================
   Bursary Officer portal — the 4th Management Committee seat.
   Loaded only on bursary.html. Hooks into officer-portal.js via
   window.onOfficerReady, which fires once login succeeds.

   Vets a loan applicant's financial capacity against the
   cooperative's 1/3 rule — total monthly deductions (existing
   loans + savings + the new loan) must not exceed one-third of
   Gross Pay OR one-third of Net Pay — BEFORE the application
   reaches the Treasurer. See supabase/migration_bursary_officer_role.sql
   for the server-side enforcement of this rule.
   ========================================================= */
window.onOfficerReady = function () {
  loadBursaryQueue();
  loadBursaryHistory();
};

let currentVettingLoanId = null;

async function loadBursaryQueue() {
  const body = document.getElementById("bursaryQueueBody");
  body.innerHTML = `<tr class="empty-row"><td colspan="6">Loading…</td></tr>`;
  try {
    const loans = await getOfficerQueue(["awaiting_bursary", "returned_to_bursary", "on_hold_bursary"]);
    document.getElementById("bursaryQueueCount").textContent = loans.length;
    if (!loans.length) {
      body.innerHTML = `<tr class="empty-row"><td colspan="6">No applications waiting for vetting right now.</td></tr>`;
      return;
    }
    body.innerHTML = loans.map(loan => `
      <tr>
        <td>${(loan.profiles?.first_name || "")} ${(loan.profiles?.surname || "")}<div class="hint">${loan.profiles?.alamanah_no || ""}</div></td>
        <td>${capitalize(loan.type)}</td>
        <td>${formatNaira(loan.amount)}</td>
        <td>${loan.date_applied}</td>
        <td>${bursaryWorkflowBadge(loan.workflow_status)}</td>
        <td><button class="btn btn-primary btn-sm" onclick="openVettingModal('${loan.id}')">Review</button></td>
      </tr>
    `).join("");
  } catch (err) {
    body.innerHTML = `<tr class="empty-row"><td colspan="6">Could not load queue: ${err.message}</td></tr>`;
  }
}

function bursaryWorkflowBadge(status) {
  const map = {
    awaiting_bursary:   { cls: "pill-wait", label: "Awaiting vetting" },
    returned_to_bursary:{ cls: "pill-bad",  label: "Returned" },
    on_hold_bursary:    { cls: "pill-bad",  label: "On hold" }
  };
  const m = map[status] || { cls: "pill-wait", label: status };
  return `<span class="pill ${m.cls}">${m.label}</span>`;
}

function capitalize(s) { return s ? s.charAt(0).toUpperCase() + s.slice(1) : s; }

async function openVettingModal(loanId) {
  currentVettingLoanId = loanId;
  const box = document.getElementById("vettingModalBody");
  box.innerHTML = `<p class="hint">Loading financial position…</p>`;
  document.getElementById("vettingModal").hidden = false;

  try {
    const summary = await getBursaryFinancialSummary(loanId);
    const hasSalary = summary.gross_pay != null && summary.net_pay != null;

    box.innerHTML = `
      <div class="stat-strip" style="grid-template-columns:1fr 1fr;margin-bottom:20px;">
        <div class="stat-card"><div class="hint">Member</div><div style="font-weight:700;">${summary.member_name}</div><div class="hint">${summary.alamanah_no}${summary.department ? " &middot; " + summary.department : ""}</div></div>
        <div class="stat-card"><div class="hint">Request</div><div style="font-weight:700;">${capitalize(summary.loan_type)} Loan — ${formatNaira(summary.amount)}</div><div class="hint">${summary.duration} months</div></div>
        <div class="stat-card"><div class="hint">Existing Cooperative Deductions (this system's records)</div><div style="font-weight:700;">${formatNaira(summary.existing_monthly_deductions)}</div><div class="hint">Cross-check vs. "Al-Amanah Saving" + "Al-Amanah Ded" on the member's real payslip — already inside their current Net Pay below</div></div>
        <div class="stat-card"><div class="hint">This Loan's Monthly Deduction</div><div style="font-weight:700;">${formatNaira(summary.proposed_monthly_deduction)}</div><div class="hint">The only new amount that further reduces Net Pay</div></div>
        <div class="stat-card"><div class="hint">Current Net Pay (from payslip)</div><div style="font-weight:700;">${summary.net_pay != null ? formatNaira(summary.net_pay) : "—"}</div><div class="hint">Already reflects all current deductions</div></div>
        <div class="stat-card"><div class="hint">Net Pay If This Loan Is Approved</div><div style="font-weight:700;">${summary.net_pay_after_deductions != null ? formatNaira(summary.net_pay_after_deductions) : "—"}</div><div class="hint">Must stay at/above 1/3 of Gross Pay</div></div>
        <div class="stat-card"><div class="hint">Result So Far</div><div style="font-weight:700;">${limitBadge(summary.within_limit)}</div></div>
      </div>
      <p class="hint" style="margin-bottom:16px;"><strong>Purpose:</strong> ${summary.purpose}</p>

      <form id="salaryForm" style="background:var(--green-100);border:1px solid var(--green-500);border-radius:var(--radius-s);padding:16px;margin-bottom:20px;">
        <p style="font-weight:700;margin-bottom:10px;">Salary on file (by rank, from the salary scale)</p>
        <div style="display:grid;grid-template-columns:1fr 1fr;gap:12px;">
          <div class="field" style="margin-bottom:0;">
            <label for="salaryGross">Gross Pay (₦/month)</label>
            <input type="number" id="salaryGross" min="0" step="1" value="${summary.gross_pay ?? ""}" placeholder="e.g. 180000">
          </div>
          <div class="field" style="margin-bottom:0;">
            <label for="salaryNet">Net Pay (₦/month)</label>
            <input type="number" id="salaryNet" min="0" step="1" value="${summary.net_pay ?? ""}" placeholder="e.g. 132000">
          </div>
        </div>
        ${summary.salary_updated_at ? `<p class="hint" style="margin-top:8px;">Last updated ${summary.salary_updated_at}.</p>` : `<p class="hint" style="margin-top:8px;">Not yet on file — enter both figures from the salary scale before vetting.</p>`}
        <div class="form-error" id="salaryError" style="margin-top:8px;"></div>
        <button type="submit" class="btn btn-outline btn-sm" style="margin-top:10px;" id="salarySaveBtn">Save Salary &amp; Recalculate</button>
      </form>

      <form id="vettingForm">
        <div class="field">
          <label for="vettingEligibility">Vetting result</label>
          <select id="vettingEligibility" required>
            <option value="">— Select —</option>
            <option value="eligible">Eligible — within the 1/3 limit</option>
            <option value="not_eligible">Not Eligible — exceeds the 1/3 limit</option>
            <option value="needs_more_information">Needs More Information</option>
            <option value="on_hold">Put on Hold</option>
          </select>
        </div>
        <div class="field">
          <label for="vettingNote">Vetting note</label>
          <textarea id="vettingNote" rows="4" required placeholder="Explain the basis for this result — reference the salary figures and any other consideration…"></textarea>
        </div>
        <div class="form-error" id="vettingError"></div>
        <div class="modal-actions">
          <button type="button" class="btn btn-ghost" onclick="closeVettingModal()">Cancel</button>
          <button type="submit" class="btn btn-primary" id="vettingSubmitBtn">Submit Vetting</button>
        </div>
      </form>
    `;

    document.getElementById("salaryForm").addEventListener("submit", handleSalarySave);
    document.getElementById("vettingForm").addEventListener("submit", handleVettingSubmit);

    if (!hasSalary) {
      document.getElementById("vettingEligibility").value = "needs_more_information";
    }
  } catch (err) {
    box.innerHTML = `<p class="form-error show">Could not load this application: ${err.message}</p>`;
  }
}

function limitBadge(withinLimit) {
  if (withinLimit === null || withinLimit === undefined) return `<span class="pill pill-wait">Salary not on file</span>`;
  return withinLimit
    ? `<span class="pill pill-ok">Net pay stays at/above 1/3 of gross</span>`
    : `<span class="pill pill-bad">Net pay would fall below 1/3 of gross</span>`;
}

async function handleSalarySave(e) {
  e.preventDefault();
  const gross = Number(document.getElementById("salaryGross").value);
  const net = Number(document.getElementById("salaryNet").value);
  const errBox = document.getElementById("salaryError");
  const btn = document.getElementById("salarySaveBtn");
  errBox.classList.remove("show");

  if (!gross || gross <= 0 || !net || net <= 0) {
    errBox.textContent = "Enter both Gross Pay and Net Pay as positive amounts.";
    errBox.classList.add("show");
    return;
  }
  if (net > gross) {
    errBox.textContent = "Net Pay cannot be greater than Gross Pay.";
    errBox.classList.add("show");
    return;
  }

  btn.disabled = true; btn.textContent = "Saving…";
  try {
    const memberId = await resolveMemberIdForLoan(currentVettingLoanId);
    await setMemberSalary(memberId, gross, net);
    toast("Salary saved.");
    openVettingModal(currentVettingLoanId); // reload with fresh figures
  } catch (err) {
    errBox.textContent = err.message || "Could not save salary.";
    errBox.classList.add("show");
  }
  btn.disabled = false; btn.textContent = "Save Salary & Recalculate";
}

async function handleVettingSubmit(e) {
  e.preventDefault();
  const eligibility = document.getElementById("vettingEligibility").value;
  const note = document.getElementById("vettingNote").value.trim();
  const grossInput = document.getElementById("salaryGross").value;
  const netInput = document.getElementById("salaryNet").value;
  const errBox = document.getElementById("vettingError");
  const btn = document.getElementById("vettingSubmitBtn");
  errBox.classList.remove("show");

  btn.disabled = true; btn.textContent = "Submitting…";
  try {
    await submitBursaryVetting(
      currentVettingLoanId,
      eligibility,
      note,
      grossInput ? Number(grossInput) : null,
      netInput ? Number(netInput) : null
    );
    closeVettingModal();
    toast("Vetting submitted.");
    loadBursaryQueue();
    loadBursaryHistory();
  } catch (err) {
    errBox.textContent = err.message || "Could not submit this vetting.";
    errBox.classList.add("show");
  }
  btn.disabled = false; btn.textContent = "Submit Vetting";
}

function closeVettingModal() {
  document.getElementById("vettingModal").hidden = true;
  currentVettingLoanId = null;
}

async function loadBursaryHistory() {
  const body = document.getElementById("bursaryHistoryBody");
  if (!body) return;
  try {
    const me = await getMyProfile();
    const { data, error } = await supabaseClient
      .from("loan_vettings")
      .select("*, loans(id, type, amount, profiles(alamanah_no, surname, first_name))")
      .eq("bursary_officer_id", me.id)
      .order("created_at", { ascending: false })
      .limit(20);
    if (error) throw error;
    if (!data.length) {
      body.innerHTML = `<tr class="empty-row"><td colspan="6">You haven't submitted any vettings yet.</td></tr>`;
      return;
    }
    body.innerHTML = data.map(v => `
      <tr>
        <td>${new Date(v.created_at).toLocaleString()}</td>
        <td>${v.loans?.profiles ? `${v.loans.profiles.first_name} ${v.loans.profiles.surname}` : v.loan_id}</td>
        <td>${v.loans ? `${capitalize(v.loans.type)} — ${formatNaira(v.loans.amount)}` : "—"}</td>
        <td>${eligibilityPillFor(v.eligibility_status)}</td>
        <td class="mono-cell" style="font-size:12px;">Net after: ${formatNaira(v.net_pay_after_deductions)} / needs ≥ ${formatNaira(v.one_third_gross_limit)}</td>
        <td>${v.note}</td>
      </tr>
    `).join("");
  } catch (err) {
    body.innerHTML = `<tr class="empty-row"><td colspan="6">Could not load history: ${err.message}</td></tr>`;
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

// The financial-summary RPC doesn't return the raw member id (it's
// not needed for display), so saving a salary looks it up directly
// from the loan.
async function resolveMemberIdForLoan(loanId) {
  const { data, error } = await supabaseClient.from("loans").select("member_id").eq("id", loanId).single();
  if (error) throw error;
  return data.member_id;
}
