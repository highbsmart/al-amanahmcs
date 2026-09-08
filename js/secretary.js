/* =========================================================
   Secretary portal — professional administrative/accounting
   dashboard. Loaded only on secretary.html. Hooks into
   officer-portal.js via window.onOfficerReady.
   ========================================================= */

let secLoanRegister = [];   // every loan application, from get_secretary_loan_register
let secMemberRegister = []; // every member, from get_secretary_member_register
let currentRecordTarget = null; // { type, id, loanId } — for the Official Record modal

window.onOfficerReady = function () {
  loadSecretaryOverview();
  loadSecretaryFeed();
  loadSecretaryHistory();
};

/* ---------- tab switching ---------- */
function switchSecTab(tab) {
  document.querySelectorAll("[data-sectab]").forEach(t => t.classList.toggle("active", t.dataset.sectab === tab));
  document.querySelectorAll("[id^='sectab-']").forEach(el => { el.style.display = (el.id === "sectab-" + tab) ? "" : "none"; });
}

/* ---------- overview: loads both registers, powers stat strip + all three main tables ---------- */
async function loadSecretaryOverview() {
  try {
    const loans = await getSecretaryLoanRegister();
    const members = await getSecretaryMemberRegister();
    secLoanRegister = loans;
    secMemberRegister = members;

    renderSecretaryStats();
    populateAppMonthFilter();
    renderLoanApplicationsRegister();
    renderApprovedMonthlyRegister();
    renderMemberRegister();
  } catch (err) {
    toast(err.message || "Could not load administrative registers.", "error");
  }
}

function renderSecretaryStats() {
  const activeMembers = secMemberRegister.filter(m => m.status === "active").length;
  const outstanding = secLoanRegister
    .filter(l => l.status === "approved")
    .reduce((s, l) => s + Number(l.balance || 0), 0);
  const pending = secLoanRegister.filter(l => l.status === "pending").length;

  const now = new Date();
  const monthStart = new Date(now.getFullYear(), now.getMonth(), 1).toISOString().slice(0, 10);
  const approvedThisMonth = secLoanRegister.filter(function (l) {
    return l.status !== "pending" && l.status !== "declined" && l.date_decision && l.date_decision >= monthStart;
  });
  const approvedThisMonthTotal = approvedThisMonth.reduce((s, l) => s + Number(l.amount || 0), 0);

  document.getElementById("secStatMembers").textContent = activeMembers;
  document.getElementById("secStatOutstanding").textContent = formatNaira(outstanding);
  document.getElementById("secStatPending").textContent = pending;
  document.getElementById("secStatApprovedMonth").textContent =
    approvedThisMonth.length + " \u00b7 " + formatNaira(approvedThisMonthTotal);
}

/* ===================== LOAN APPLICATIONS REGISTER ===================== */
function currentMonthKey() {
  const now = new Date();
  return now.getFullYear() + "-" + String(now.getMonth() + 1).padStart(2, "0");
}
function monthKeyLabel(monthKey) {
  const parts = monthKey.split("-");
  return new Date(Number(parts[0]), Number(parts[1]) - 1, 1).toLocaleDateString(undefined, { month: "long", year: "numeric" });
}

// Builds the Month dropdown from whatever months actually have
// applications, newest first, defaulting to the current month so the
// register opens ready for this month's meeting without extra clicks.
// If the current month has no applications yet, falls back to "All Months".
function populateAppMonthFilter() {
  const sel = document.getElementById("appFilterMonth");
  if (!sel) return;
  const monthsPresent = new Set(secLoanRegister.map(function (l) { return l.date_applied ? l.date_applied.slice(0, 7) : null; }).filter(Boolean));
  const sortedMonths = Array.from(monthsPresent).sort().reverse();
  const nowKey = currentMonthKey();
  if (!monthsPresent.has(nowKey)) sortedMonths.unshift(nowKey); // still offer current month even if empty

  const previousValue = sel.value;
  sel.innerHTML = '<option value="">All Months</option>' +
    sortedMonths.map(function (mk) { return '<option value="' + mk + '">' + monthKeyLabel(mk) + '</option>'; }).join("");

  // Keep whatever the officer had selected if it still exists; otherwise default to current month.
  sel.value = sortedMonths.includes(previousValue) ? previousValue : nowKey;
}

function filteredLoanRegister() {
  const monthEl = document.getElementById("appFilterMonth");
  const statusEl = document.getElementById("appFilterStatus");
  const typeEl = document.getElementById("appFilterType");
  const searchEl = document.getElementById("appFilterSearch");
  const month = monthEl ? monthEl.value : "";
  const status = statusEl ? statusEl.value : "";
  const type = typeEl ? typeEl.value : "";
  const search = (searchEl ? searchEl.value : "").trim().toLowerCase();

  return secLoanRegister.filter(function (l) {
    if (month && (!l.date_applied || l.date_applied.slice(0, 7) !== month)) return false;
    if (status && l.status !== status) return false;
    if (type && l.type !== type) return false;
    if (search && (l.member_name + " " + l.alamanah_no).toLowerCase().indexOf(search) === -1) return false;
    return true;
  });
}

function renderLoanApplicationsRegister() {
  const body = document.getElementById("loanRegisterBody");
  if (!body) return;
  const rows = filteredLoanRegister();
  if (!rows.length) { body.innerHTML = '<tr class="empty-row"><td colspan="8">No applications match this filter.</td></tr>'; return; }

  body.innerHTML = rows.map(function (l) {
    return '<tr>' +
      '<td class="mono-cell">' + l.loan_id + '</td>' +
      '<td>' + l.member_name + '</td>' +
      '<td class="mono-cell">' + l.alamanah_no + '</td>' +
      '<td>' + (LOAN_TYPES[l.type] ? LOAN_TYPES[l.type].label : l.type) + '</td>' +
      '<td class="mono-cell">' + formatNaira(l.amount) + '</td>' +
      '<td>' + formatDate(l.date_applied) + '</td>' +
      '<td>' + statusPill(l.status) + '</td>' +
      '<td><button class="btn btn-outline btn-sm" onclick="printLoanApplicationForm(\'' + l.loan_id + '\')">Print Form</button></td>' +
      '</tr>';
  }).join("");
}

function statusPill(status) {
  const map = {
    pending: '<span class="pill pill-wait">Pending</span>',
    approved: '<span class="pill pill-ok">Approved</span>',
    completed: '<span class="pill pill-ok">Completed</span>',
    offset: '<span class="pill pill-ok">Offset</span>',
    declined: '<span class="pill pill-bad">Declined</span>'
  };
  return map[status] || status;
}

function downloadLoanRegisterPdf() {
  const rows = filteredLoanRegister();
  const monthEl = document.getElementById("appFilterMonth");
  const monthLabel = monthEl && monthEl.value ? monthKeyLabel(monthEl.value) : "All Months";
  const jsPDF = window.jspdf.jsPDF;
  const doc = new jsPDF({ orientation: "landscape" });
  doc.setFontSize(14); doc.text("Al-Amanah Multi-Purpose Co-operative Society", 14, 14);
  doc.setFontSize(11); doc.text("Loan Applications Register \u2014 " + monthLabel, 14, 21);
  doc.setFontSize(9); doc.text("Printed: " + new Date().toLocaleString() + "    Total: " + rows.length + " application(s)", 14, 27);
  doc.autoTable({
    startY: 32,
    head: [["Loan ID", "Member", "Al-Amanah No.", "Type", "Amount", "Purpose", "Applied", "Status"]],
    body: rows.map(function (l) {
      return [l.loan_id, l.member_name, l.alamanah_no,
        LOAN_TYPES[l.type] ? LOAN_TYPES[l.type].label : l.type,
        formatNaira(l.amount), l.purpose, formatDate(l.date_applied), l.status];
    }),
    styles: { fontSize: 8 }
  });
  const fileMonth = monthEl && monthEl.value ? monthEl.value : "all-months";
  doc.save("loan-applications-register_" + fileMonth + ".pdf");
}
function downloadLoanRegisterExcel() {
  const rows = filteredLoanRegister();
  const monthEl = document.getElementById("appFilterMonth");
  const data = [["Loan ID", "Member", "Al-Amanah No.", "Type", "Amount", "Purpose", "Duration (months)", "Date Applied", "Status", "Date Decision"]];
  rows.forEach(function (l) {
    data.push([l.loan_id, l.member_name, l.alamanah_no,
      LOAN_TYPES[l.type] ? LOAN_TYPES[l.type].label : l.type,
      Number(l.amount) || 0, l.purpose, l.duration, l.date_applied, l.status, l.date_decision || ""]);
  });
  const ws = XLSX.utils.aoa_to_sheet(data);
  const wb = XLSX.utils.book_new();
  XLSX.utils.book_append_sheet(wb, ws, "Loan Applications");
  const fileMonth = monthEl && monthEl.value ? monthEl.value : "all-months";
  XLSX.writeFile(wb, "loan-applications-register_" + fileMonth + ".xlsx");
}

/* ---------- individual printable Loan Application Form ---------- */
async function printLoanApplicationForm(loanId) {
  try {
    const detail = await getSecretaryLoanDetail(loanId);
    const jsPDF = window.jspdf.jsPDF;
    const doc = new jsPDF();
    const l = detail.loan;
    const m = detail.member;

    doc.setFontSize(14); doc.text("Al-Amanah Multi-Purpose Co-operative Society", 14, 16);
    doc.setFontSize(12); doc.text("Loan Application Form", 14, 24);
    doc.setFontSize(9); doc.text("Loan ID: " + l.id + "    Printed: " + new Date().toLocaleString(), 14, 30);

    doc.autoTable({
      startY: 36,
      head: [["Applicant Details", ""]],
      body: [
        ["Member Name", m.name],
        ["Al-Amanah No.", m.alamanah_no],
        ["Department", m.department || "\u2014"],
        ["Phone", m.phone || "\u2014"]
      ],
      styles: { fontSize: 9 }
    });

    let y = doc.lastAutoTable.finalY + 8;
    doc.autoTable({
      startY: y,
      head: [["Loan Details", ""]],
      body: [
        ["Loan Type", LOAN_TYPES[l.type] ? LOAN_TYPES[l.type].label : l.type],
        ["Amount Requested", formatNaira(l.amount)],
        ["Purpose", l.purpose],
        ["Duration", l.duration + " months"],
        ["Date Applied", formatDate(l.date_applied)],
        ["Current Status", l.status],
        ["Date Decided", l.date_decision ? formatDate(l.date_decision) : "\u2014"]
      ],
      styles: { fontSize: 9 }
    });

    y = doc.lastAutoTable.finalY + 8;
    doc.autoTable({
      startY: y,
      head: [["Bursary Vetting", ""]],
      body: [
        ["Eligibility", detail.bursary_vetting ? detail.bursary_vetting.eligibility_status : "Not yet vetted"],
        ["Note", detail.bursary_vetting ? detail.bursary_vetting.note : "\u2014"]
      ],
      styles: { fontSize: 9 }
    });

    y = doc.lastAutoTable.finalY + 8;
    doc.autoTable({
      startY: y,
      head: [["Treasurer Assessment", ""]],
      body: [
        ["Eligibility", detail.treasurer_assessment ? detail.treasurer_assessment.eligibility_status : "Not yet assessed"],
        ["Recommendation", detail.treasurer_assessment ? (detail.treasurer_assessment.recommendation || "\u2014") : "\u2014"],
        ["Note", detail.treasurer_assessment ? detail.treasurer_assessment.assessment_note : "\u2014"]
      ],
      styles: { fontSize: 9 }
    });

    y = doc.lastAutoTable.finalY + 8;
    doc.autoTable({
      startY: y,
      head: [["President's Decision", ""]],
      body: [
        ["Decision", detail.president_decision ? detail.president_decision.decision : "Not yet decided"],
        ["Note", detail.president_decision ? (detail.president_decision.decision_note || "\u2014") : "\u2014"]
      ],
      styles: { fontSize: 9 }
    });

    y = doc.lastAutoTable.finalY + 20;
    doc.setFontSize(9);
    doc.text("_______________________", 14, y);
    doc.text("_______________________", 110, y);
    doc.text("Secretary's Signature", 14, y + 6);
    doc.text("Date", 110, y + 6);

    doc.save("loan-application_" + l.id + ".pdf");
  } catch (err) {
    toast(err.message || "Could not generate the application form.", "error");
  }
}

/* ===================== APPROVED LOANS \u2014 MONTHLY REGISTER ===================== */
function approvedLoansGroupedByMonth() {
  const approved = secLoanRegister.filter(function (l) {
    return l.status !== "pending" && l.status !== "declined" && l.date_decision;
  });
  const byMonth = new Map();

  approved.forEach(function (l) {
    const monthKey = l.date_decision.slice(0, 7);
    if (!byMonth.has(monthKey)) {
      const parts = monthKey.split("-");
      const label = new Date(Number(parts[0]), Number(parts[1]) - 1, 1).toLocaleDateString(undefined, { month: "long", year: "numeric" });
      byMonth.set(monthKey, { label: label, types: { real: [], commodity: [], humanitarian: [] } });
    }
    const bucket = byMonth.get(monthKey).types[l.type];
    if (bucket) bucket.push(l);
  });

  return Array.from(byMonth.entries()).sort(function (a, b) { return b[0].localeCompare(a[0]); });
}

let collapsedMonths = new Set();

function toggleMonthGroup(monthKey) {
  if (collapsedMonths.has(monthKey)) collapsedMonths.delete(monthKey);
  else collapsedMonths.add(monthKey);
  renderApprovedMonthlyRegister();
}
function toggleTypeGroup(monthKey, type) {
  const key = monthKey + ":" + type;
  if (collapsedMonths.has(key)) collapsedMonths.delete(key);
  else collapsedMonths.add(key);
  renderApprovedMonthlyRegister();
}

function renderApprovedMonthlyRegister() {
  const box = document.getElementById("approvedMonthlyGroups");
  if (!box) return;
  const groups = approvedLoansGroupedByMonth();
  if (!groups.length) { box.innerHTML = '<p class="empty-row" style="padding:16px;">No approved loans recorded yet.</p>'; return; }

  box.innerHTML = groups.map(function (entry, i) {
    const monthKey = entry[0];
    const group = entry[1];
    const monthCollapsed = collapsedMonths.has(monthKey) || (collapsedMonths.size === 0 && i > 0);
    const allLoans = group.types.real.concat(group.types.commodity, group.types.humanitarian);
    const monthTotal = allLoans.reduce(function (s, l) { return s + Number(l.amount || 0); }, 0);
    const monthCount = allLoans.length;

    const typeSections = Object.keys(LOAN_TYPES).map(function (typeKey) {
      const t = LOAN_TYPES[typeKey];
      const list = group.types[typeKey] || [];
      if (!list.length) return "";
      const typeKeyFull = monthKey + ":" + typeKey;
      const typeCollapsed = collapsedMonths.has(typeKeyFull);
      const typeTotal = list.reduce(function (s, l) { return s + Number(l.amount || 0); }, 0);
      const rows = list.map(function (l) {
        return '<tr>' +
          '<td class="mono-cell">' + l.loan_id + '</td>' +
          '<td>' + l.member_name + '</td>' +
          '<td class="mono-cell">' + l.alamanah_no + '</td>' +
          '<td class="mono-cell">' + formatNaira(l.amount) + '</td>' +
          '<td>' + formatDate(l.date_decision) + '</td>' +
          '<td>' + statusPill(l.status) + '</td>' +
          '</tr>';
      }).join("");

      return '<div class="smslog-date-group' + (typeCollapsed ? " collapsed" : "") + '" style="margin-left:16px;">' +
        '<div class="smslog-date-header" onclick="toggleTypeGroup(\'' + monthKey + '\',\'' + typeKey + '\')">' +
        '<span class="chevron">\u25bc</span> ' + t.label + ' <span class="date-count">(' + list.length + ' \u00b7 ' + formatNaira(typeTotal) + ')</span>' +
        '</div>' +
        '<div class="table-wrap"><table><thead><tr><th>Loan ID</th><th>Member</th><th>Al-Amanah No.</th><th>Amount</th><th>Decided</th><th>Status</th></tr></thead><tbody>' + rows + '</tbody></table></div>' +
        '</div>';
    }).join("");

    return '<div class="smslog-date-group' + (monthCollapsed ? " collapsed" : "") + '">' +
      '<div class="smslog-date-header" onclick="toggleMonthGroup(\'' + monthKey + '\')">' +
      '<span class="chevron">\u25bc</span> ' + group.label + ' <span class="date-count">(' + monthCount + ' loan(s) \u00b7 ' + formatNaira(monthTotal) + ')</span>' +
      '</div>' +
      '<div class="table-wrap" style="padding:12px 0;">' + (typeSections || '<p class="empty-row" style="padding:12px;">No approved loans this month.</p>') + '</div>' +
      '</div>';
  }).join("");
}

function downloadApprovedMonthlyRegisterPdf() {
  const groups = approvedLoansGroupedByMonth();
  const jsPDF = window.jspdf.jsPDF;
  const doc = new jsPDF({ orientation: "landscape" });
  doc.setFontSize(14); doc.text("Al-Amanah Multi-Purpose Co-operative Society", 14, 14);
  doc.setFontSize(11); doc.text("Approved Loans \u2014 Monthly Register", 14, 21);
  doc.setFontSize(9); doc.text("Printed: " + new Date().toLocaleString(), 14, 27);

  let y = 34;
  groups.forEach(function (entry) {
    const group = entry[1];
    Object.keys(LOAN_TYPES).forEach(function (typeKey) {
      const t = LOAN_TYPES[typeKey];
      const list = group.types[typeKey] || [];
      if (!list.length) return;
      if (y > 180) { doc.addPage(); y = 20; }
      doc.setFontSize(10); doc.text(group.label + " \u2014 " + t.label + " (" + list.length + " loan(s))", 14, y);
      doc.autoTable({
        startY: y + 3,
        head: [["Loan ID", "Member", "Al-Amanah No.", "Amount", "Decided", "Status"]],
        body: list.map(function (l) { return [l.loan_id, l.member_name, l.alamanah_no, formatNaira(l.amount), formatDate(l.date_decision), l.status]; }),
        styles: { fontSize: 8 }
      });
      y = doc.lastAutoTable.finalY + 10;
    });
  });
  doc.save("approved-loans-monthly-register_" + new Date().toISOString().slice(0, 10) + ".pdf");
}
function downloadApprovedMonthlyRegisterExcel() {
  const groups = approvedLoansGroupedByMonth();
  const wb = XLSX.utils.book_new();
  groups.forEach(function (entry) {
    const monthKey = entry[0];
    const group = entry[1];
    const rows = [["Loan ID", "Member", "Al-Amanah No.", "Type", "Amount", "Date Decided", "Status"]];
    Object.keys(LOAN_TYPES).forEach(function (typeKey) {
      const t = LOAN_TYPES[typeKey];
      (group.types[typeKey] || []).forEach(function (l) {
        rows.push([l.loan_id, l.member_name, l.alamanah_no, t.label, Number(l.amount) || 0, l.date_decision, l.status]);
      });
    });
    const ws = XLSX.utils.aoa_to_sheet(rows);
    XLSX.utils.book_append_sheet(wb, ws, monthKey.slice(0, 31));
  });
  if (!groups.length) XLSX.utils.book_append_sheet(wb, XLSX.utils.aoa_to_sheet([["No approved loans yet."]]), "Approved Loans");
  XLSX.writeFile(wb, "approved-loans-monthly-register_" + new Date().toISOString().slice(0, 10) + ".xlsx");
}

/* ===================== MEMBERSHIP REGISTER ===================== */
function filteredMemberRegister() {
  const searchEl = document.getElementById("memberRegisterSearch");
  const search = (searchEl ? searchEl.value : "").trim().toLowerCase();
  if (!search) return secMemberRegister;
  return secMemberRegister.filter(function (m) {
    return (m.first_name + " " + m.surname + " " + m.alamanah_no).toLowerCase().indexOf(search) !== -1;
  });
}
function renderMemberRegister() {
  const body = document.getElementById("memberRegisterBody");
  if (!body) return;
  const rows = filteredMemberRegister();
  if (!rows.length) { body.innerHTML = '<tr class="empty-row"><td colspan="7">No members match this search.</td></tr>'; return; }
  body.innerHTML = rows.map(function (m) {
    return '<tr>' +
      '<td class="mono-cell">' + m.alamanah_no + '</td>' +
      '<td>' + m.first_name + ' ' + m.surname + '</td>' +
      '<td>' + (m.department || "\u2014") + '</td>' +
      '<td>' + (m.phone || "\u2014") + '</td>' +
      '<td>' + (m.status === "active" ? '<span class="pill pill-ok">Active</span>' : '<span class="pill pill-wait">' + capitalize(m.status) + '</span>') + '</td>' +
      '<td>' + (m.joined ? formatDate(m.joined) : "\u2014") + '</td>' +
      '<td class="mono-cell">' + formatNaira(m.savings_balance) + '</td>' +
      '</tr>';
  }).join("");
}
function downloadMemberRegisterPdf() {
  const rows = filteredMemberRegister();
  const jsPDF = window.jspdf.jsPDF;
  const doc = new jsPDF({ orientation: "landscape" });
  doc.setFontSize(14); doc.text("Al-Amanah Multi-Purpose Co-operative Society", 14, 14);
  doc.setFontSize(11); doc.text("Membership Register", 14, 21);
  doc.setFontSize(9); doc.text("Printed: " + new Date().toLocaleString() + "    Total: " + rows.length + " member(s)", 14, 27);
  doc.autoTable({
    startY: 32,
    head: [["Al-Amanah No.", "Name", "Department", "Phone", "Status", "Joined", "Savings Balance"]],
    body: rows.map(function (m) {
      return [m.alamanah_no, m.first_name + " " + m.surname, m.department || "\u2014", m.phone || "\u2014",
        m.status, m.joined ? formatDate(m.joined) : "\u2014", formatNaira(m.savings_balance)];
    }),
    styles: { fontSize: 8 }
  });
  doc.save("membership-register_" + new Date().toISOString().slice(0, 10) + ".pdf");
}
function downloadMemberRegisterExcel() {
  const rows = filteredMemberRegister();
  const data = [["Al-Amanah No.", "Name", "Department", "Phone", "Status", "Joined", "Savings Balance"]];
  rows.forEach(function (m) {
    data.push([m.alamanah_no, m.first_name + " " + m.surname, m.department || "", m.phone || "", m.status, m.joined || "", Number(m.savings_balance) || 0]);
  });
  const ws = XLSX.utils.aoa_to_sheet(data);
  const wb = XLSX.utils.book_new();
  XLSX.utils.book_append_sheet(wb, ws, "Membership Register");
  XLSX.writeFile(wb, "membership-register_" + new Date().toISOString().slice(0, 10) + ".xlsx");
}

/* ===================== ACTIVITY REGISTER (existing, unchanged) ===================== */
async function loadSecretaryFeed() {
  const body = document.getElementById("secretaryFeedBody");
  body.innerHTML = '<tr class="empty-row"><td colspan="4">Loading\u2026</td></tr>';
  try {
    const assessments = await supabaseClient.from("loan_assessments").select("*, loans(id, type, amount, profiles(alamanah_no, surname, first_name))").order("created_at", { ascending: false }).limit(20);
    const decisions = await supabaseClient.from("loan_decisions").select("*, loans(id, type, amount, profiles(alamanah_no, surname, first_name))").order("created_at", { ascending: false }).limit(20);
    const records = await supabaseClient.from("official_records").select("*");
    if (assessments.error) throw assessments.error;
    if (decisions.error) throw decisions.error;
    if (records.error) throw records.error;

    const documentedIds = new Set((records.data || []).map(function (r) { return r.related_entity_id; }));
    document.getElementById("secretaryPendingCount").textContent =
      (records.data || []).filter(function (r) { return r.documentation_status === "pending"; }).length;

    const items = (assessments.data || []).map(function (a) {
      return {
        type: "loan_assessment", id: a.id, loanId: a.loan_id, created_at: a.created_at,
        member: a.loans && a.loans.profiles ? (a.loans.profiles.first_name + " " + a.loans.profiles.surname) : a.loan_id,
        summary: "Treasurer assessment \u2014 " + labelEligibility(a.eligibility_status)
      };
    }).concat((decisions.data || []).map(function (d) {
      return {
        type: "loan_decision", id: d.id, loanId: d.loan_id, created_at: d.created_at,
        member: d.loans && d.loans.profiles ? (d.loans.profiles.first_name + " " + d.loans.profiles.surname) : d.loan_id,
        summary: "President decision \u2014 " + capitalize(d.decision.replace(/_/g, " "))
      };
    })).sort(function (a, b) { return new Date(b.created_at) - new Date(a.created_at); });

    if (!items.length) {
      body.innerHTML = '<tr class="empty-row"><td colspan="4">No management activity yet.</td></tr>';
      return;
    }

    body.innerHTML = items.map(function (item) {
      return '<tr>' +
        '<td>' + new Date(item.created_at).toLocaleString() + '</td>' +
        '<td>' + item.member + '</td>' +
        '<td>' + item.summary + '</td>' +
        '<td>' + (documentedIds.has(item.id)
          ? '<span class="pill pill-ok">Documented</span>'
          : '<button class="btn btn-primary btn-sm" onclick="openRecordModal(\'' + item.type + '\',\'' + item.id + '\',\'' + item.loanId + '\')">Document</button>') +
        '</td></tr>';
    }).join("");
  } catch (err) {
    body.innerHTML = '<tr class="empty-row"><td colspan="4">Could not load activity: ' + err.message + '</td></tr>';
  }
}

function labelEligibility(s) {
  const map = { eligible: "Eligible", not_eligible: "Not Eligible", needs_more_information: "Needs More Information", on_hold: "On Hold" };
  return map[s] || s;
}
function capitalize(s) { return s ? s.charAt(0).toUpperCase() + s.slice(1) : s; }

function openRecordModal(type, id, loanId) {
  currentRecordTarget = { type: type, id: id, loanId: loanId };
  document.getElementById("recordError").classList.remove("show");
  document.getElementById("recordForm").reset();
  document.getElementById("recordModal").hidden = false;
}

function closeRecordModal() {
  document.getElementById("recordModal").hidden = true;
  currentRecordTarget = null;
}

async function loadSecretaryHistory() {
  const body = document.getElementById("secretaryHistoryBody");
  if (!body) return;
  try {
    const me = await getMyProfile();
    const result = await supabaseClient
      .from("official_records")
      .select("*, loans(id, type, amount, profiles(alamanah_no, surname, first_name))")
      .eq("recorded_by", me.id)
      .order("created_at", { ascending: false })
      .limit(20);
    if (result.error) throw result.error;
    const data = result.data;
    if (!data.length) {
      body.innerHTML = '<tr class="empty-row"><td colspan="5">You haven\'t created any official records yet.</td></tr>';
      return;
    }
    body.innerHTML = data.map(function (r) {
      return '<tr>' +
        '<td>' + new Date(r.created_at).toLocaleString() + '</td>' +
        '<td>' + (r.loans && r.loans.profiles ? (r.loans.profiles.first_name + " " + r.loans.profiles.surname) : r.loan_id) + '</td>' +
        '<td>' + (r.reference_number || "\u2014") + '</td>' +
        '<td>' + (r.documentation_status === "complete" ? '<span class="pill pill-ok">Complete</span>' : '<span class="pill pill-wait">Pending</span>') + '</td>' +
        '<td>' + r.official_note + '</td>' +
        '<td>' + (r.documentation_status === "complete"
          ? '<span class="hint">\u2014</span>'
          : '<button class="btn btn-outline btn-sm" onclick="handleMarkComplete(\'' + r.id + '\')">Mark Complete</button>') +
        '</td></tr>';
    }).join("");
  } catch (err) {
    body.innerHTML = '<tr class="empty-row"><td colspan="6">Could not load history: ' + err.message + '</td></tr>';
  }
}

async function handleMarkComplete(recordId) {
  try {
    const result = await supabaseClient.rpc("mark_official_record_complete", { p_record_id: recordId });
    if (result.error) throw result.error;
    toast("Marked as complete.");
    loadSecretaryHistory();
  } catch (err) {
    toast(err.message || "Could not update this record.", "error");
  }
}

async function downloadOfficialRecordsPdf() {
  try {
    const me = await getMyProfile();
    const result = await supabaseClient
      .from("official_records")
      .select("*, loans(id, type, amount, profiles(alamanah_no, surname, first_name))")
      .eq("recorded_by", me.id)
      .order("created_at", { ascending: false });
    if (result.error) throw result.error;
    const data = result.data;

    const jsPDF = window.jspdf.jsPDF;
    const doc = new jsPDF({ orientation: "landscape" });
    doc.setFontSize(14); doc.text("Al-Amanah Multi-Purpose Co-operative Society", 14, 14);
    doc.setFontSize(11); doc.text("Official Records \u2014 Cooperative Decision Register", 14, 21);
    doc.setFontSize(9); doc.text("Secretary: " + me.first_name + " " + me.surname + "    Printed: " + new Date().toLocaleString(), 14, 27);

    doc.autoTable({
      startY: 33,
      head: [["Date", "Member", "Al-Amanah No.", "Reference", "Meeting Ref.", "Status", "Note"]],
      body: (data || []).map(function (r) {
        return [
          new Date(r.created_at).toLocaleDateString(),
          r.loans && r.loans.profiles ? (r.loans.profiles.first_name + " " + r.loans.profiles.surname) : r.loan_id,
          (r.loans && r.loans.profiles && r.loans.profiles.alamanah_no) || "\u2014",
          r.reference_number || "\u2014",
          r.meeting_reference || "\u2014",
          r.documentation_status === "complete" ? "Complete" : "Pending",
          r.official_note
        ];
      }),
      styles: { fontSize: 8 }
    });

    doc.save("official-records_" + me.surname + "_" + new Date().toISOString().slice(0, 10) + ".pdf");
  } catch (err) {
    toast(err.message || "Could not generate the PDF.", "error");
  }
}

document.addEventListener("DOMContentLoaded", function () {
  document.getElementById("recordForm").addEventListener("submit", async function (e) {
    e.preventDefault();
    const note = document.getElementById("recordNote").value.trim();
    const ref = document.getElementById("recordReference").value.trim();
    const meeting = document.getElementById("recordMeeting").value.trim();
    const errBox = document.getElementById("recordError");
    const btn = document.getElementById("recordSubmitBtn");
    errBox.classList.remove("show");

    btn.disabled = true; btn.textContent = "Saving\u2026";
    try {
      const result = await supabaseClient.rpc("create_official_record", {
        p_related_entity_type: currentRecordTarget.type,
        p_related_entity_id: currentRecordTarget.id,
        p_loan_id: currentRecordTarget.loanId,
        p_official_note: note,
        p_reference_number: ref || null,
        p_meeting_reference: meeting || null
      });
      if (result.error) throw result.error;
      closeRecordModal();
      toast("Official record saved.");
      loadSecretaryFeed();
      loadSecretaryHistory();
    } catch (err) {
      errBox.textContent = err.message || "Could not save this record.";
      errBox.classList.add("show");
    }
    btn.disabled = false; btn.textContent = "Save Official Record";
  });
});
