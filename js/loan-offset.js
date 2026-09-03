/* =========================================================
   Loan Offset Payment (Step: Paystack integration).
   Uses the global myLoans array already loaded by dashboard.js.
   ========================================================= */

function openOffsetModal() {
  const eligible = (myLoans || []).filter(l => l.status === "approved" && Number(l.balance) > 0);
  const box = document.getElementById("offsetModalBody");

  if (!eligible.length) {
    box.innerHTML = `<p class="hint">You have no active loans with an outstanding balance to offset right now.</p>`;
    document.getElementById("offsetModal").hidden = false;
    return;
  }

  box.innerHTML = `
    <p class="hint" style="margin-bottom:14px;">Select one or more loans to pay off. The amount shown is your current outstanding balance, fetched live — not an estimate.</p>
    <div class="table-wrap" style="margin-bottom:16px;">
      <table>
        <thead><tr><th></th><th>Loan Type</th><th>Outstanding Balance</th></tr></thead>
        <tbody>
          ${eligible.map(l => `
            <tr>
              <td><input type="checkbox" class="offset-loan-check" value="${l.id}" data-amount="${l.balance}" onchange="updateOffsetTotal()"></td>
              <td>${capitalizeOffset(l.type)} Loan</td>
              <td>${formatNaira(l.balance)}</td>
            </tr>
          `).join("")}
        </tbody>
      </table>
    </div>
    <div class="payslip-grand-total" style="margin-bottom:16px;">
      <span>Total Offset Payment</span><span id="offsetTotalDisplay">₦0</span>
    </div>
    <div class="field" id="offsetEmailField">
      <label for="offsetEmail">Email for payment receipt</label>
      <input type="email" id="offsetEmail" placeholder="you@example.com">
    </div>
    <div class="form-error" id="offsetError"></div>
    <div class="modal-actions" style="flex-wrap:wrap;">
      <button type="button" class="btn btn-ghost" onclick="closeOffsetModal()">Cancel</button>
      <button type="button" class="btn btn-outline" id="offsetManualBtn" onclick="handleManualOffsetRequest()" disabled>Notify Treasurer — I'll Pay Directly</button>
      <button type="button" class="btn btn-primary" id="offsetPayBtn" onclick="handleOffsetPayment()" disabled>Pay Online via Paystack</button>
    </div>
  `;
  document.getElementById("offsetModal").hidden = false;
}

function capitalizeOffset(s) { return s ? s.charAt(0).toUpperCase() + s.slice(1) : s; }

function updateOffsetTotal() {
  const checked = document.querySelectorAll(".offset-loan-check:checked");
  let total = 0;
  checked.forEach(c => total += Number(c.dataset.amount));
  document.getElementById("offsetTotalDisplay").textContent = formatNaira(total);
  document.getElementById("offsetPayBtn").disabled = checked.length === 0;
  document.getElementById("offsetManualBtn").disabled = checked.length === 0;
}

async function handleOffsetPayment() {
  const checked = Array.from(document.querySelectorAll(".offset-loan-check:checked")).map(c => c.value);
  const email = document.getElementById("offsetEmail").value.trim();
  const errBox = document.getElementById("offsetError");
  const btn = document.getElementById("offsetPayBtn");
  errBox.classList.remove("show");

  if (!checked.length) return;
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    errBox.textContent = "Please enter a valid email address to receive your payment receipt.";
    errBox.classList.add("show");
    return;
  }

  btn.disabled = true; btn.textContent = "Preparing payment…";
  try {
    const request = await createOffsetRequest(checked, "paystack");
    const init = await initializeOffsetPayment(request.offset_request_id, email);
    // Send them to Paystack's checkout. When they finish (or cancel),
    // Paystack sends them back to payment-callback.html automatically.
    window.location.href = init.authorization_url;
  } catch (err) {
    errBox.textContent = err.message || "Could not start this payment. Please try again.";
    errBox.classList.add("show");
    btn.disabled = false; btn.textContent = "Proceed to Payment";
  }
}

function closeOffsetModal() {
  document.getElementById("offsetModal").hidden = true;
}

async function handleManualOffsetRequest() {
  const checked = Array.from(document.querySelectorAll(".offset-loan-check:checked")).map(c => c.value);
  const errBox = document.getElementById("offsetError");
  const btn = document.getElementById("offsetManualBtn");
  errBox.classList.remove("show");
  if (!checked.length) return;

  btn.disabled = true; btn.textContent = "Sending request…";
  try {
    const request = await createOffsetRequest(checked, "manual");
    closeOffsetModal();
    toast(`Request sent. Please pay ${formatNaira(request.total_amount)} directly to the cooperative's account, then wait for the Treasurer to confirm it — reference: ${request.request_reference}`);
    loadOffsetHistory();
  } catch (err) {
    errBox.textContent = err.message || "Could not send this request. Please try again.";
    errBox.classList.add("show");
  }
  btn.disabled = false; btn.textContent = "Notify Treasurer — I'll Pay Directly";
}

// ---------------------------------------------------------
// Loan Offset History, Receipt, and Offset Letter
// ---------------------------------------------------------
let myOffsetRequests = [];

async function loadOffsetHistory() {
  const body = document.getElementById("offsetHistoryBody");
  if (!body) return;
  try {
    myOffsetRequests = await getMyOffsetRequests();
    if (!myOffsetRequests.length) {
      body.innerHTML = `<tr class="empty-row"><td colspan="5">No offset payments yet.</td></tr>`;
      return;
    }
    body.innerHTML = myOffsetRequests.map(r => `
      <tr>
        <td>${new Date(r.created_at).toLocaleDateString()}</td>
        <td class="mono-cell">${r.request_reference}</td>
        <td>${formatNaira(r.total_amount)}</td>
        <td>${offsetStatusPill(r)}</td>
        <td>
          ${r.offset_status === "completed"
            ? `<button class="btn btn-outline btn-sm" onclick="openOffsetReceipt('${r.id}')">View Receipt</button>
               <button class="btn btn-outline btn-sm" onclick="openOffsetLetter('${r.id}')">Offset Letter</button>`
            : `<span class="hint">${r.payment_status === "pending" ? (r.payment_method === "manual" ? "Awaiting Treasurer confirmation" : "Awaiting payment") : "—"}</span>`}
        </td>
      </tr>
    `).join("");
  } catch (err) {
    body.innerHTML = `<tr class="empty-row"><td colspan="5">Could not load offset history: ${err.message}</td></tr>`;
  }
}

function offsetStatusPill(r) {
  if (r.offset_status === "completed") return `<span class="pill pill-ok">Completed</span>`;
  if (r.payment_status === "failed" || r.offset_status === "failed") return `<span class="pill pill-bad">Failed</span>`;
  return `<span class="pill pill-wait">Pending</span>`;
}

function findOffsetRequest(id) {
  return (myOffsetRequests || []).find(r => r.id === id);
}

function paymentMethodLabel(r) {
  if (r.payment_method === "paystack") return "Paystack";
  if (r.payment_method === "manual") return "Direct to Cooperative Account (Confirmed by Treasurer)";
  if (r.payment_method === "manual_admin") return "Direct to Cooperative Account (Confirmed by Administrator)";
  return r.payment_method || "—";
}

function openOffsetReceipt(id) {
  const r = findOffsetRequest(id);
  const box = document.getElementById("offsetReceiptBody");
  if (!r) { box.innerHTML = `<p class="hint">Could not find this payment.</p>`; document.getElementById("offsetReceiptModal").hidden = false; return; }

  const receiptNo = "RCT-" + r.id.slice(0, 8).toUpperCase();
  box.innerHTML = `
    <div id="offsetReceiptPrintArea" class="payslip-doc">
      <div class="payslip-letterhead">
        <h2>Al-Amanah Multi-Purpose Co-operative Society</h2>
        <p>Loan Offset Payment Receipt</p>
      </div>
      <div class="payslip-meta">
        <div class="payslip-meta-row"><span>Receipt Number</span><span>${receiptNo}</span></div>
        <div class="payslip-meta-row"><span>Reference</span><span>${r.request_reference}</span></div>
        <div class="payslip-meta-row"><span>Member</span><span>${profile.first_name} ${profile.surname}</span></div>
        <div class="payslip-meta-row"><span>Al-Amanah No.</span><span>${profile.alamanah_no}</span></div>
        <div class="payslip-meta-row"><span>Payment Date</span><span>${r.paid_at ? new Date(r.paid_at).toLocaleString() : "—"}</span></div>
        <div class="payslip-meta-row"><span>Payment Method</span><span>${paymentMethodLabel(r)}</span></div>
        ${r.manual_confirmation_note ? `<div class="payslip-meta-row"><span>Confirmation Note</span><span>${r.manual_confirmation_note}</span></div>` : ""}
        <div class="payslip-meta-row"><span>Status</span><span style="color:var(--green-700);font-weight:700;">SUCCESSFUL</span></div>
      </div>
      <div class="payslip-section">
        <div class="payslip-section-title">Loans Offset</div>
        ${(r.loan_offset_request_items || []).map(item => `
          <div class="payslip-line"><span>${capitalizeOffset(item.loan_type)} Loan (${item.loan_id})</span><span>${formatNaira(item.amount_to_offset)}</span></div>
        `).join("")}
      </div>
      <div class="payslip-grand-total"><span>Total Paid</span><span>${formatNaira(r.total_amount)}</span></div>
      <p class="payslip-footer-note">Generated on ${new Date().toLocaleString()}</p>
    </div>
  `;
  document.getElementById("offsetReceiptModal").hidden = false;
}

function closeOffsetReceipt() {
  document.getElementById("offsetReceiptModal").hidden = true;
}

function openOffsetLetter(id) {
  const r = findOffsetRequest(id);
  const box = document.getElementById("offsetLetterBody");
  if (!r) { box.innerHTML = `<p class="hint">Could not find this payment.</p>`; document.getElementById("offsetLetterModal").hidden = false; return; }

  const items = r.loan_offset_request_items || [];
  box.innerHTML = `
    <div id="offsetLetterPrintArea" class="payslip-doc" style="max-width:600px;text-align:left;">
      <p style="text-align:right;">Date: ${new Date().toLocaleDateString()}</p>
      <p><strong>The President</strong><br>Al-Amanah Multi-Purpose Cooperative Society</p>
      <h3 style="text-align:center;text-decoration:underline;margin:20px 0;">APPLICATION FOR LOAN OFFSET</h3>
      <p>Dear Sir,</p>
      <p>I, <strong>${profile.first_name} ${profile.surname}</strong>, with Membership ID <strong>${profile.alamanah_no}</strong>, respectfully write to formally notify the Cooperative of my request and successful payment for the offset of my outstanding loan obligation(s).</p>
      <p>The loan(s) offset are as follows:</p>
      <div class="payslip-section">
        <div class="payslip-section-title">Loan Type — Outstanding Balance — Amount Paid</div>
        ${items.map(item => `
          <div class="payslip-line"><span>${capitalizeOffset(item.loan_type)} Loan</span><span>${formatNaira(item.outstanding_balance_snapshot)} — ${formatNaira(item.amount_to_offset)}</span></div>
        `).join("")}
      </div>
      <p><strong>Total Amount Paid: ${formatNaira(r.total_amount)}</strong></p>
      <p>The payment was successfully completed via ${paymentMethodLabel(r)}.</p>
      <p><strong>Reference:</strong> ${r.request_reference}</p>
      <p>I respectfully request that my loan records be updated accordingly.</p>
      <p>Thank you.</p>
      <p>Yours faithfully,</p>
      <p class="letter-signature">____________________________<br>${profile.first_name} ${profile.surname}<br>Membership ID: ${profile.alamanah_no}</p>
    </div>
  `;
  document.getElementById("offsetLetterModal").hidden = false;
}

function closeOffsetLetter() {
  document.getElementById("offsetLetterModal").hidden = true;
}

document.addEventListener("DOMContentLoaded", () => {
  // Wait briefly for dashboard.js's own DOMContentLoaded to load
  // `profile` and `myLoans` first, then load the offset history.
  const tryLoad = () => {
    if (typeof profile !== "undefined" && profile) loadOffsetHistory();
    else setTimeout(tryLoad, 200);
  };
  tryLoad();
});
