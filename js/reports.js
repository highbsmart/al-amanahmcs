/* =========================================================
   AL-AMANAH CO-OPERATIVE — ADMIN REPORTS
   Builds three auditing reports for a chosen date range —
   a society financial statement, a full loan-requests log,
   and approved loans grouped by loan type — with PDF and
   Excel export for each. Loaded by admin.html only, after
   admin.js (relies on currentMembers / currentAllLoans /
   LOAN_TYPES / formatNaira / formatDate / toast, all defined
   elsewhere in the admin page).
   ========================================================= */

const SOCIETY_NAME = "Al-Amanah Multi-Purpose Co-operative Society";

let reportData = null; // { from, to, financial, loanRequests, approvedByType }

function defaultReportRange() {
  const now = new Date();
  const from = new Date(now.getFullYear(), now.getMonth(), 1);
  const to = new Date(now.getFullYear(), now.getMonth() + 1, 0);
  return { from: from.toISOString().slice(0, 10), to: to.toISOString().slice(0, 10) };
}
function initReportRange() {
  const fromEl = document.getElementById("reportFrom");
  const toEl = document.getElementById("reportTo");
  if (!fromEl || !toEl || fromEl.value) return; // don't clobber a range the admin already picked
  const { from, to } = defaultReportRange();
  fromEl.value = from;
  toEl.value = to;
}
function setReportRangeThisMonth() {
  const { from, to } = defaultReportRange();
  document.getElementById("reportFrom").value = from;
  document.getElementById("reportTo").value = to;
  generateReports();
}
function setReportRangeThisYear() {
  const now = new Date();
  document.getElementById("reportFrom").value = `${now.getFullYear()}-01-01`;
  document.getElementById("reportTo").value = `${now.getFullYear()}-12-31`;
  generateReports();
}
function getReportRange() {
  return { from: document.getElementById("reportFrom").value, to: document.getElementById("reportTo").value };
}
function inRange(dateStr, from, to) {
  return !!dateStr && dateStr >= from && dateStr <= to;
}
function reportFileLabel() {
  return `${reportData.from}_to_${reportData.to}`;
}

async function generateReports() {
  const { from, to } = getReportRange();
  const box = document.getElementById("reportsOutput");
  if (!from || !to || from > to) { toast("Please choose a valid date range.", "error"); return; }
  box.innerHTML = '<p class="lede">Building reports…</p>';

  try {
    const tx = await getAllTransactionsAdmin();
    const txInRange = tx.filter(t => inRange(t.date, from, to));

    const savingsIn = txInRange.filter(t => t.type === "savings" && Number(t.amount) > 0).reduce((s, t) => s + Number(t.amount || 0), 0);
    const savingsAdjustmentsNet = txInRange.filter(t => t.type === "savings" && Number(t.amount) < 0).reduce((s, t) => s + Number(t.amount || 0), 0);
    const adminChargesCollected = txInRange.filter(t => t.type === "admin_charge").reduce((s, t) => s + Math.abs(Number(t.amount || 0)), 0);
    const loanDisbursed = txInRange.filter(t => t.type === "loan" && Number(t.amount) > 0).reduce((s, t) => s + Number(t.amount || 0), 0);
    const loanRepaid = txInRange.filter(t => t.type === "loan" && Number(t.amount) < 0).reduce((s, t) => s + Math.abs(Number(t.amount || 0)), 0);
    const netMovement = savingsIn + savingsAdjustmentsNet + adminChargesCollected + loanRepaid - loanDisbursed;

    const totalSavingsNow = currentMembers.reduce((s, m) => s + Number(m.savings_balance || 0), 0);
    const totalAdminChargesNow = currentMembers.reduce((s, m) => s + Number(m.total_admin_charges || 0), 0);
    const totalOutstandingNow = currentAllLoans.filter(l => l.status === "approved").reduce((s, l) => s + Number(l.balance || 0), 0);

    const financial = { savingsIn, savingsAdjustmentsNet, adminChargesCollected, loanDisbursed, loanRepaid, netMovement, totalSavingsNow, totalAdminChargesNow, totalOutstandingNow };

    const loanRequests = currentAllLoans
      .filter(l => inRange(l.date_applied, from, to))
      .sort((a, b) => (a.date_applied < b.date_applied ? -1 : a.date_applied > b.date_applied ? 1 : 0));

    const approvedInRange = currentAllLoans.filter(l => l.status !== "pending" && l.status !== "declined" && inRange(l.date_decision, from, to));
    const approvedByType = {};
    Object.keys(LOAN_TYPES).forEach(k => { approvedByType[k] = []; });
    approvedInRange.forEach(l => { (approvedByType[l.type] = approvedByType[l.type] || []).push(l); });

    reportData = { from, to, financial, loanRequests, approvedByType };
    renderReportsPreview();
  } catch (err) {
    box.innerHTML = `<p class="form-error show">${err.message || "Could not build reports."}</p>`;
  }
}

function renderReportsPreview() {
  const { from, to, financial, loanRequests, approvedByType } = reportData;
  const box = document.getElementById("reportsOutput");

  const statusCounts = {};
  loanRequests.forEach(l => { statusCounts[l.status] = (statusCounts[l.status] || 0) + 1; });
  const approvedCount = (statusCounts.approved || 0) + (statusCounts.completed || 0) + (statusCounts.offset || 0);

  const typeRows = Object.entries(LOAN_TYPES).map(([key, t]) => {
    const list = approvedByType[key] || [];
    const total = list.reduce((s, l) => s + Number(l.amount || 0), 0);
    return `<tr><td>${t.label}</td><td>${list.length}</td><td class="mono-cell">${formatNaira(total)}</td></tr>`;
  }).join("");
  const grandCount = Object.values(approvedByType).reduce((s, l) => s + l.length, 0);
  const grandTotal = Object.values(approvedByType).reduce((s, l) => s + l.reduce((ss, x) => ss + Number(x.amount || 0), 0), 0);

  box.innerHTML = `
    <div class="section-heading"><h3>Society Financial Statement</h3><span style="font-size:13px;color:var(--ink-soft);">${formatDate(from)} — ${formatDate(to)}</span></div>
    <div class="card">
      <div class="ledger-rows">
        <div class="ledger-row"><span>Savings contributions received</span><span>${formatNaira(financial.savingsIn)}</span></div>
        <div class="ledger-row"><span>Savings adjustments (net corrections)</span><span>${formatNaira(financial.savingsAdjustmentsNet)}</span></div>
        <div class="ledger-row"><span>Administrative charges collected</span><span>${formatNaira(financial.adminChargesCollected)}</span></div>
        <div class="ledger-row"><span>Loan principal disbursed</span><span>${formatNaira(financial.loanDisbursed)}</span></div>
        <div class="ledger-row"><span>Loan repayments collected</span><span>${formatNaira(financial.loanRepaid)}</span></div>
        <div class="ledger-row"><span><strong>Net cash movement (period)</strong></span><span><strong>${formatNaira(financial.netMovement)}</strong></span></div>
      </div>
      <div class="ledger-rows" style="margin-top:14px;border-top:1px dashed rgba(11,59,35,.15);padding-top:14px;">
        <div class="ledger-row"><span>Total member savings (as of today)</span><span>${formatNaira(financial.totalSavingsNow)}</span></div>
        <div class="ledger-row"><span>Total admin charges accumulated (all-time)</span><span>${formatNaira(financial.totalAdminChargesNow)}</span></div>
        <div class="ledger-row"><span>Total outstanding loan balance (as of today)</span><span>${formatNaira(financial.totalOutstandingNow)}</span></div>
      </div>
      <div style="display:flex;gap:8px;margin-top:16px;flex-wrap:wrap;">
        <button class="btn btn-primary btn-sm" onclick="downloadFinancialPdf()">Download PDF</button>
        <button class="btn btn-outline btn-sm" onclick="downloadFinancialExcel()">Download Excel</button>
      </div>
    </div>

    <div class="section-heading" style="margin-top:36px;"><h3>Loan Requests</h3><span style="font-size:13px;color:var(--ink-soft);">Applications received in period — ${loanRequests.length} total</span></div>
    <div class="card">
      <p style="margin:0 0 14px;font-size:13.5px;">Pending: ${statusCounts.pending || 0} &nbsp;·&nbsp; Approved: ${approvedCount} &nbsp;·&nbsp; Declined: ${statusCounts.declined || 0}</p>
      <div style="display:flex;gap:8px;flex-wrap:wrap;">
        <button class="btn btn-primary btn-sm" onclick="downloadLoanRequestsPdf()">Download PDF</button>
        <button class="btn btn-outline btn-sm" onclick="downloadLoanRequestsExcel()">Download Excel</button>
      </div>
    </div>

    <div class="section-heading" style="margin-top:36px;"><h3>Approved Loans by Type</h3><span style="font-size:13px;color:var(--ink-soft);">Decided in period — ${grandCount} approved, ${formatNaira(grandTotal)} total</span></div>
    <div class="table-wrap">
      <table>
        <thead><tr><th>Loan Type</th><th>Count</th><th>Total Amount</th></tr></thead>
        <tbody>${typeRows}<tr><td><strong>Total</strong></td><td><strong>${grandCount}</strong></td><td class="mono-cell"><strong>${formatNaira(grandTotal)}</strong></td></tr></tbody>
      </table>
    </div>
    <div style="display:flex;gap:8px;margin-top:14px;flex-wrap:wrap;">
      <button class="btn btn-primary btn-sm" onclick="downloadApprovedByTypePdf()">Download PDF</button>
      <button class="btn btn-outline btn-sm" onclick="downloadApprovedByTypeExcel()">Download Excel</button>
    </div>
  `;
}

/* ---------- Financial statement exports ---------- */
function downloadFinancialPdf() {
  const { jsPDF } = window.jspdf;
  const doc = new jsPDF();
  const f = reportData.financial;
  doc.setFontSize(14); doc.text(SOCIETY_NAME, 14, 16);
  doc.setFontSize(11); doc.text("Financial Statement", 14, 24);
  doc.setFontSize(9); doc.text(`Period: ${formatDate(reportData.from)} to ${formatDate(reportData.to)}`, 14, 30);
  doc.autoTable({
    startY: 36,
    head: [["Item", "Amount (NGN)"]],
    body: [
      ["Savings contributions received", formatNaira(f.savingsIn)],
      ["Savings adjustments (net corrections)", formatNaira(f.savingsAdjustmentsNet)],
      ["Administrative charges collected", formatNaira(f.adminChargesCollected)],
      ["Loan principal disbursed", formatNaira(f.loanDisbursed)],
      ["Loan repayments collected", formatNaira(f.loanRepaid)],
      ["Net cash movement (period)", formatNaira(f.netMovement)],
    ],
  });
  const y2 = doc.lastAutoTable.finalY + 10;
  doc.setFontSize(10); doc.text("Balance snapshot (as of report date)", 14, y2);
  doc.autoTable({
    startY: y2 + 4,
    head: [["Item", "Amount (NGN)"]],
    body: [
      ["Total member savings", formatNaira(f.totalSavingsNow)],
      ["Total admin charges accumulated (all-time)", formatNaira(f.totalAdminChargesNow)],
      ["Total outstanding loan balance", formatNaira(f.totalOutstandingNow)],
    ],
  });
  doc.save(`financial-statement_${reportFileLabel()}.pdf`);
}
function downloadFinancialExcel() {
  const f = reportData.financial;
  const rows = [
    [SOCIETY_NAME + " — Financial Statement"],
    [`Period: ${reportData.from} to ${reportData.to}`],
    [],
    ["Item", "Amount (NGN)"],
    ["Savings contributions received", f.savingsIn],
    ["Savings adjustments (net corrections)", f.savingsAdjustmentsNet],
    ["Administrative charges collected", f.adminChargesCollected],
    ["Loan principal disbursed", f.loanDisbursed],
    ["Loan repayments collected", f.loanRepaid],
    ["Net cash movement (period)", f.netMovement],
    [],
    ["Balance snapshot (as of report date)"],
    ["Total member savings", f.totalSavingsNow],
    ["Total admin charges accumulated (all-time)", f.totalAdminChargesNow],
    ["Total outstanding loan balance", f.totalOutstandingNow],
  ];
  const ws = XLSX.utils.aoa_to_sheet(rows);
  const wb = XLSX.utils.book_new();
  XLSX.utils.book_append_sheet(wb, ws, "Financial Statement");
  XLSX.writeFile(wb, `financial-statement_${reportFileLabel()}.xlsx`);
}

/* ---------- Loan requests exports ---------- */
function downloadLoanRequestsPdf() {
  const { jsPDF } = window.jspdf;
  const doc = new jsPDF({ orientation: "landscape" });
  doc.setFontSize(14); doc.text(SOCIETY_NAME, 14, 14);
  doc.setFontSize(11); doc.text("Loan Requests Report", 14, 21);
  doc.setFontSize(9); doc.text(`Period: ${formatDate(reportData.from)} to ${formatDate(reportData.to)}`, 14, 27);
  doc.autoTable({
    startY: 32,
    head: [["Loan ID", "Member", "Al-Amanah No.", "Type", "Amount", "Duration", "Applied", "Status"]],
    body: reportData.loanRequests.map(l => [
      l.id, l.memberName, l.memberNo, LOAN_TYPES[l.type] ? LOAN_TYPES[l.type].label : l.type,
      formatNaira(l.amount), `${l.duration} mo.`, formatDate(l.date_applied), l.status
    ]),
    styles: { fontSize: 8 },
  });
  doc.save(`loan-requests_${reportFileLabel()}.pdf`);
}
function downloadLoanRequestsExcel() {
  const rows = [
    ["Loan ID", "Member", "Al-Amanah No.", "Type", "Amount", "Duration (months)", "Purpose", "Date Applied", "Status"],
    ...reportData.loanRequests.map(l => [
      l.id, l.memberName, l.memberNo, LOAN_TYPES[l.type] ? LOAN_TYPES[l.type].label : l.type,
      Number(l.amount) || 0, l.duration, l.purpose, l.date_applied, l.status
    ])
  ];
  const ws = XLSX.utils.aoa_to_sheet(rows);
  const wb = XLSX.utils.book_new();
  XLSX.utils.book_append_sheet(wb, ws, "Loan Requests");
  XLSX.writeFile(wb, `loan-requests_${reportFileLabel()}.xlsx`);
}

/* ---------- Approved loans by type exports ---------- */
function downloadApprovedByTypePdf() {
  const { jsPDF } = window.jspdf;
  const doc = new jsPDF({ orientation: "landscape" });
  doc.setFontSize(14); doc.text(SOCIETY_NAME, 14, 14);
  doc.setFontSize(11); doc.text("Approved Loans by Type", 14, 21);
  doc.setFontSize(9); doc.text(`Period: ${formatDate(reportData.from)} to ${formatDate(reportData.to)}`, 14, 27);
  let y = 32;
  Object.entries(LOAN_TYPES).forEach(([key, t]) => {
    const list = reportData.approvedByType[key] || [];
    if (!list.length) return;
    doc.setFontSize(10); doc.text(`${t.label} — ${list.length} loan(s)`, 14, y);
    doc.autoTable({
      startY: y + 3,
      head: [["Loan ID", "Member", "Al-Amanah No.", "Amount", "Decision Date", "Status"]],
      body: list.map(l => [l.id, l.memberName, l.memberNo, formatNaira(l.amount), formatDate(l.date_decision), l.status]),
      styles: { fontSize: 8 },
    });
    y = doc.lastAutoTable.finalY + 10;
  });
  if (y === 32) doc.text("No approved loans in this period.", 14, 36);
  doc.save(`approved-loans-by-type_${reportFileLabel()}.pdf`);
}
function downloadApprovedByTypeExcel() {
  const wb = XLSX.utils.book_new();
  let any = false;
  Object.entries(LOAN_TYPES).forEach(([key, t]) => {
    const list = reportData.approvedByType[key] || [];
    const rows = [
      ["Loan ID", "Member", "Al-Amanah No.", "Amount", "Decision Date", "Status"],
      ...list.map(l => [l.id, l.memberName, l.memberNo, Number(l.amount) || 0, l.date_decision, l.status])
    ];
    const ws = XLSX.utils.aoa_to_sheet(rows);
    XLSX.utils.book_append_sheet(wb, ws, t.label.slice(0, 31));
    any = true;
  });
  if (!any) XLSX.utils.book_append_sheet(wb, XLSX.utils.aoa_to_sheet([["No approved loans in this period."]]), "Approved Loans");
  XLSX.writeFile(wb, `approved-loans-by-type_${reportFileLabel()}.xlsx`);
}
