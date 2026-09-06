let adminPollTimer = null;
let adminRealtimeChannels = [];

let currentMembers = [];
let currentApprovedLoans = [];
let currentAllLoans = [];
let selectedMemberIds = new Set();
let selectedLoanIds = new Set();
let editSavingsTarget = null; // { id, name, previous }
let currentMemberDetailTx = []; // transactions currently shown in the open Member Detail modal
let currentMemberDetailLoans = []; // loans currently shown in the open Member Detail modal
let currentMemberDetailOffsetHistory = []; // loan_offset_requests currently shown in the open Member Detail modal
let currentLoanDetailMemberId = null; // memberId behind the currently open Loan Detail modal

function showAdminPanel() {
  document.getElementById("adminSessionChecking").style.display = "none";
  document.getElementById("adminLoginShell").style.display = "none";
  document.getElementById("adminPanel").style.display = "block";
  document.getElementById("adminLogoutBtn").style.display = "inline-flex";
  const vamBtn = document.getElementById("adminViewAsMemberBtn");
  if (vamBtn) vamBtn.style.display = "inline-flex";
  sessionStorage.removeItem("viewAsMember"); // see officer-portal.js showPanel() for why
  if (typeof initReportRange === "function") initReportRange();
  renderAdmin();
  // Members' actions (new applications, savings updates, etc.) happen
  // from another session, so this tab won't hear about them unless we
  // listen. Realtime pushes changes instantly; the poll below is just
  // a safety net in case a realtime event is ever missed.
  adminRealtimeChannels.forEach(ch => supabaseClient.removeChannel(ch));
  // The admin panel legitimately needs to hear about every member's
  // changes, so these stay unfiltered — but debounced, so a burst of
  // events (a bulk member upload, several members saving in the same
  // minute) triggers one full re-render shortly after the burst ends
  // instead of one full re-render PER event, which was the main
  // cause of the admin panel feeling slow.
  const refreshAdmin = debounce(renderAdmin, 600);
  adminRealtimeChannels = [
    subscribeToLoansTable(refreshAdmin),
    subscribeToProfilesTable(refreshAdmin),
    subscribeToTransactionsTable(refreshAdmin),
    subscribeToPayslipOverridesTable(refreshAdmin)
  ];
  if (adminPollTimer) clearInterval(adminPollTimer);
  adminPollTimer = setInterval(renderAdmin, 45000);
}
function showAdminLogin() {
  document.getElementById("adminSessionChecking").style.display = "none";
  document.getElementById("adminLoginShell").style.display = "flex";
  document.getElementById("adminPanel").style.display = "none";
  document.getElementById("adminLogoutBtn").style.display = "none";
  const vamBtn = document.getElementById("adminViewAsMemberBtn");
  if (vamBtn) vamBtn.style.display = "none";
  if (adminPollTimer) { clearInterval(adminPollTimer); adminPollTimer = null; }
  adminRealtimeChannels.forEach(ch => supabaseClient.removeChannel(ch));
  adminRealtimeChannels = [];
}

function switchTab(tab) {
  document.querySelectorAll(".admin-tab").forEach(t => t.classList.toggle("active", t.dataset.tab === tab));
  document.querySelectorAll(".tab-content").forEach(c => c.style.display = "none");
  document.getElementById("tab-" + tab).style.display = "block";
}

async function renderAdmin() {
  const members = await getAllMembers();
  const allLoans = await getAllLoans();

  currentMembers = members;

  const withNames = allLoans.map(l => ({
    ...l,
    memberNo: l.profiles?.alamanah_no || "—",
    memberName: l.profiles ? `${l.profiles.first_name} ${l.profiles.surname}` : "—"
  }));

  const pending = withNames.filter(l => l.status === "pending");
  const decided = withNames.filter(l => l.status === "declined" || l.status === "approved" || l.status === "completed" || l.status === "offset");
  currentAllLoans = withNames;
  currentApprovedLoans = withNames.filter(l => l.status === "approved").map(l => {
    const owner = members.find(m => m.id === l.member_id);
    return { ...l, deductionsPaused: owner ? owner.deductions_paused : false };
  });
  const totalSavings = members.reduce((s, m) => s + Number(m.savings_balance || 0), 0);
  const totalOutstanding = withNames.filter(l => l.status === "approved").reduce((s, l) => s + Number(l.balance || 0), 0);

  document.getElementById("statStrip").innerHTML = `
    <div class="stat-box" style="cursor:pointer;" onclick="switchTab('members')"><strong>${members.length}</strong><span>Registered members</span></div>
    <div class="stat-box" style="cursor:pointer;" onclick="switchTab('pending')"><strong>${pending.length}</strong><span>Pending applications</span></div>
    <div class="stat-box" style="cursor:pointer;" onclick="switchTab('deductions')"><strong>${formatNaira(totalOutstanding)}</strong><span>Outstanding loan balance</span></div>
    <div class="stat-box" style="cursor:pointer;" onclick="switchTab('members')"><strong>${formatNaira(totalSavings)}</strong><span>Total member savings</span></div>
  `;

  renderPendingTable(pending);
  renderMembersTable(members);
  renderPendingDirectory();
  renderDeductionsTable(currentApprovedLoans);
  renderHistoryTable(decided);
  renderManagementOverview();
  renderAutoRuns();
  renderSmsLog();
}

/* ---------- automated monthly processing (savings + loan deductions) ---------- */

async function renderAutoRuns() {
  let runs = [];
  try {
    runs = await getRecentAutoRuns();
  } catch (err) {
    // Table may not exist yet if migration_auto_monthly_processing.sql
    // hasn't been run — fail quietly rather than break the dashboard.
    return;
  }

  const banner = document.getElementById("autoRunBanner");
  const latest = runs[0];
  const latestSkips = latest ? (latest.savings_skipped?.length || 0) + (latest.loans_skipped?.length || 0) : 0;
  if (latest && latestSkips > 0) {
    banner.innerHTML = `
      <div class="auto-run-banner">
        <span>&#9888; The automatic run on <strong>${formatDate(latest.run_date)}</strong> skipped
          <strong>${latest.savings_skipped?.length || 0}</strong> savings contribution(s) and
          <strong>${latest.loans_skipped?.length || 0}</strong> loan deduction(s). Review the reasons before assuming they were completed.</span>
        <button class="btn btn-outline btn-sm" onclick="switchTab('automation')">Review</button>
      </div>`;
  } else {
    banner.innerHTML = "";
  }

  const body = document.getElementById("autoRunsTableBody");
  if (!body) return;
  if (!runs.length) {
    body.innerHTML = `<tr class="empty-row"><td colspan="5">No automatic runs recorded yet.</td></tr>`;
    return;
  }
  body.innerHTML = runs.map((r, i) => `
    <tr style="cursor:pointer;" onclick="showAutoRunDetail(${i})">
      <td>${formatDate(r.run_date)}</td>
      <td class="mono-cell">${r.savings_processed}</td>
      <td class="mono-cell">${r.savings_skipped?.length ? `<span class="pill pill-wait">${r.savings_skipped.length}</span>` : "0"}</td>
      <td class="mono-cell">${r.loans_processed}</td>
      <td class="mono-cell">${r.loans_skipped?.length ? `<span class="pill pill-wait">${r.loans_skipped.length}</span>` : "0"}</td>
    </tr>`).join("");

  window._autoRuns = runs;
  if (runs.length) showAutoRunDetail(0);
}

function showAutoRunDetail(index) {
  const r = (window._autoRuns || [])[index];
  const box = document.getElementById("autoRunsDetail");
  if (!r) { box.innerHTML = ""; return; }

  const memberName = (id) => {
    const m = currentMembers.find(x => x.id === id);
    return m ? `${m.first_name} ${m.surname} (${m.alamanah_no})` : id;
  };

  const savingsRows = (r.savings_skipped || []).map(s => `<tr><td>${memberName(s.member_id)}</td><td>${s.reason}</td></tr>`).join("");
  const loanRows = (r.loans_skipped || []).map(s => `<tr><td class="mono-cell">${s.loan_id}</td><td>${s.reason}</td></tr>`).join("");

  box.innerHTML = `
    <h3 style="margin-bottom:12px;">Details — ${formatDate(r.run_date)}</h3>
    ${savingsRows ? `
      <p style="font-weight:700;margin-bottom:6px;">Savings skipped</p>
      <div class="table-wrap" style="margin-bottom:20px;"><table><thead><tr><th>Member</th><th>Reason</th></tr></thead><tbody>${savingsRows}</tbody></table></div>
    ` : `<p class="hint" style="margin-bottom:20px;">No savings contributions were skipped this run.</p>`}
    ${loanRows ? `
      <p style="font-weight:700;margin-bottom:6px;">Loan deductions skipped</p>
      <div class="table-wrap"><table><thead><tr><th>Loan ID</th><th>Reason</th></tr></thead><tbody>${loanRows}</tbody></table></div>
    ` : `<p class="hint">No loan deductions were skipped this run.</p>`}
  `;
}

// Super Admin's "Management Team" tab — read-only monitoring of
// the Treasurer/President/Secretary workflow. Does not change any
// existing admin function; purely additive.
async function renderManagementOverview() {
  const box = document.getElementById("managementOverviewBody");
  if (!box) return; // tab not present on this page for some reason — fail quietly
  box.innerHTML = `<p class="hint">Loading…</p>`;
  try {
    const { counts, feed } = await getManagementOverview();
    box.innerHTML = `
      <div class="stat-strip" style="margin-bottom:28px;">
        <div class="stat-card"><div class="hint">Bursary &mdash; Awaiting Vetting</div><div style="font-size:1.3rem;font-weight:700;margin-top:6px;">${counts.awaitingBursary}</div></div>
        <div class="stat-card"><div class="hint">Treasurer &mdash; Awaiting Assessment</div><div style="font-size:1.3rem;font-weight:700;margin-top:6px;">${counts.awaitingTreasurer}</div></div>
        <div class="stat-card"><div class="hint">President &mdash; Awaiting Decision</div><div style="font-size:1.3rem;font-weight:700;margin-top:6px;">${counts.awaitingPresident}</div></div>
        <div class="stat-card"><div class="hint">Secretary &mdash; Records Pending</div><div style="font-size:1.3rem;font-weight:700;margin-top:6px;">${counts.recordsPending}</div></div>
        <div class="stat-card"><div class="hint">On Hold</div><div style="font-size:1.3rem;font-weight:700;margin-top:6px;">${counts.onHold}</div></div>
      </div>
      <p class="hint" style="margin-bottom:20px;">${counts.vettingsToday} vetting(s), ${counts.assessmentsToday} assessment(s), and ${counts.decisionsToday} decision(s) recorded today.</p>
      <h3 style="margin-bottom:12px;">Recent Management Activity</h3>
      <div class="table-wrap">
        <table>
          <thead><tr><th>When</th><th>Activity</th></tr></thead>
          <tbody>
            ${feed.length
              ? feed.map(f => `<tr><td class="hint" style="white-space:nowrap;">${new Date(f.created_at).toLocaleString()}</td><td>${f.text}</td></tr>`).join("")
              : `<tr class="empty-row"><td colspan="2">No management activity yet.</td></tr>`}
          </tbody>
        </table>
      </div>

      <h3 style="margin:28px 0 12px;">System Issues</h3>
      <div id="managementIssuesBody"><p class="hint">Loading…</p></div>

      <h3 style="margin:28px 0 12px;">Manage Officer Roles</h3>
      <p class="hint" style="margin-bottom:14px;">Reassign a member to Treasurer, President, or Secretary, or move an officer back to ordinary membership. Changing your own role away from Super Admin is blocked here for safety.</p>
      <div id="roleManagementBody"><p class="hint">Loading…</p></div>
    `;
    renderManagementIssues();
    renderRoleManagement();
  } catch (err) {
    box.innerHTML = `<p class="form-error show">Could not load the management overview: ${err.message}</p>`;
  }
}

async function renderManagementIssues() {
  const box = document.getElementById("managementIssuesBody");
  if (!box) return;
  try {
    const issues = await getAllManagementIssues();
    if (!issues.length) {
      box.innerHTML = `<p class="hint">No issues reported.</p>`;
      return;
    }
    box.innerHTML = `
      <div class="table-wrap">
        <table>
          <thead><tr><th>Reported</th><th>By</th><th>Title</th><th>Priority</th><th>Status</th><th>Action</th></tr></thead>
          <tbody>
            ${issues.map(i => `
              <tr>
                <td class="hint" style="white-space:nowrap;">${new Date(i.created_at).toLocaleString()}</td>
                <td>${capitalizeFirst(i.reporter_role)}</td>
                <td>${i.title}<div class="hint">${i.description}</div></td>
                <td>${severityBadge(i.severity)}</td>
                <td>${issueStatusBadge(i.status)}</td>
                <td>${
                  i.status === "resolved" || i.status === "closed"
                    ? `<span class="hint">${i.resolution_note || "—"}</span>`
                    : `<button class="btn btn-outline btn-sm" onclick="handleIssueAction('${i.id}','in_progress')">In Progress</button>
                       <button class="btn btn-primary btn-sm" onclick="handleIssueAction('${i.id}','resolved')">Resolve</button>`
                }</td>
              </tr>
            `).join("")}
          </tbody>
        </table>
      </div>
    `;
  } catch (err) {
    box.innerHTML = `<p class="form-error show">Could not load issues: ${err.message}</p>`;
  }
}

function loanStatusPillAdmin(status) {
  if (status === "approved") return '<span class="pill pill-ok">Approved</span>';
  if (status === "declined") return '<span class="pill pill-bad">Declined</span>';
  if (status === "completed") return '<span class="pill pill-ok">Completed</span>';
  if (status === "offset") return '<span class="pill pill-wait">Offset / Closed</span>';
  return '<span class="pill pill-wait">Pending</span>';
}

function offsetStatusPillAdmin(r) {
  if (r.offset_status === "completed") return '<span class="pill pill-ok">Completed</span>';
  if (r.payment_status === "failed" || r.offset_status === "failed") return '<span class="pill pill-bad">Failed</span>';
  return '<span class="pill pill-wait">Pending</span>';
}

function severityBadge(sev) {
  const map = { high: "pill-bad", normal: "pill-wait", low: "pill-ok" };
  return `<span class="pill ${map[sev] || "pill-wait"}">${capitalizeFirst(sev)}</span>`;
}

function issueStatusBadge(status) {
  const map = { open: "pill-bad", in_progress: "pill-wait", resolved: "pill-ok", closed: "pill-ok" };
  return `<span class="pill ${map[status] || "pill-wait"}">${capitalizeFirst(status.replace(/_/g, " "))}</span>`;
}

function capitalizeFirst(s) { return s ? s.charAt(0).toUpperCase() + s.slice(1) : s; }

async function renderRoleManagement() {
  const box = document.getElementById("roleManagementBody");
  if (!box) return;
  try {
    const me = await getMyProfile();
    const officers = (currentMembers || []).filter(m => m.is_admin || (m.role && m.role !== "member"));
    const roleOptions = ["member", "treasurer", "president", "secretary", "bursary", "super_admin"];
    box.innerHTML = `
      <div class="table-wrap" style="margin-bottom:20px;">
        <table>
          <thead><tr><th>Name</th><th>Al-Amanah No.</th><th>Current Role</th><th>Sign-in Email</th><th>Change to</th></tr></thead>
          <tbody>
            ${officers.length ? officers.map(m => `
              <tr>
                <td>${m.first_name} ${m.surname}</td>
                <td class="mono-cell">${m.alamanah_no}${/^AL\//i.test(m.alamanah_no) ? '' : ' <span class="pill pill-wait" style="margin-left:4px;">Placeholder</span>'}</td>
                <td>${roleBadge(m.role)}</td>
                <td class="mono-cell" style="font-size:12px;">${m.contact_email || '<span class="hint">Not set — using generated member email</span>'}</td>
                <td>
                  <div style="display:flex;gap:6px;flex-wrap:wrap;align-items:center;">
                    ${m.id === me.id
                      ? `<span class="hint">Can't change your own role here</span>`
                      : `<select id="roleSelect-${m.id}">
                           ${roleOptions.map(r => `<option value="${r}" ${r === m.role ? "selected" : ""}>${capitalizeFirst(r.replace("_", " "))}</option>`).join("")}
                         </select>
                         <button class="btn btn-primary btn-sm" onclick="handleRoleChange('${m.id}')">Save Role</button>`
                    }
                    <button class="btn btn-outline btn-sm" onclick="handleSetOfficerEmail('${m.id}', '${(m.first_name + ' ' + m.surname).replace(/'/g, "\\'")}', '${(m.contact_email || '').replace(/'/g, "\\'")}')">Set Sign-in Email</button>
                    <button class="btn btn-outline btn-sm" onclick="handleFixAlamanahNo('${m.id}', '${(m.first_name + ' ' + m.surname).replace(/'/g, "\\'")}', '${(m.alamanah_no || '').replace(/'/g, "\\'")}')">Fix Al-Amanah No.</button>
                  </div>
                </td>
              </tr>
            `).join("") : `<tr class="empty-row"><td colspan="5">No officers assigned yet.</td></tr>`}
          </tbody>
        </table>
      </div>

      <div class="field" style="max-width:520px;">
        <label for="promoteAlamanahNo">Assign a role to a member (enter their Al-Amanah No.)</label>
        <p class="hint" style="margin:-2px 0 8px;">This promotes their EXISTING member account — same Al-Amanah No., same savings, same loans — it never creates a separate placeholder account. After assigning the role, use "Set Sign-in Email" above so they have a real email to log in with at their officer portal. If someone's row shows a "Placeholder" tag next to their Al-Amanah No. (e.g. TREAS-001), use "Fix Al-Amanah No." to correct it to their real number — that's what lets them log back in as an ordinary member with it if the role is ever reassigned.</p>
        <div style="display:flex;gap:8px;flex-wrap:wrap;">
          <input type="text" id="promoteAlamanahNo" placeholder="e.g. AL/014" style="flex:1;min-width:140px;">
          <select id="promoteRole" style="flex:1;min-width:140px;">
            <option value="treasurer">Treasurer</option>
            <option value="president">President</option>
            <option value="secretary">Secretary</option>
            <option value="bursary">Bursary Officer</option>
          </select>
          <button class="btn btn-primary btn-sm" onclick="handlePromoteMember()">Assign</button>
        </div>
        <div class="form-error" id="promoteError" style="margin-top:8px;"></div>
      </div>
    `;
  } catch (err) {
    box.innerHTML = `<p class="form-error show">Could not load role management: ${err.message}</p>`;
  }
}

function roleBadge(role) {
  const map = { super_admin: "pill-bad", treasurer: "pill-wait", president: "pill-wait", secretary: "pill-wait", bursary: "pill-wait", member: "pill-ok" };
  return `<span class="pill ${map[role] || "pill-ok"}">${capitalizeFirst((role || "member").replace("_", " "))}</span>`;
}

async function handleRoleChange(profileId) {
  const select = document.getElementById("roleSelect-" + profileId);
  const newRole = select.value;
  if (!window.confirm("Change this account's role to " + newRole.replace("_", " ") + "?")) return;
  try {
    await setProfileRole(profileId, newRole);
    toast("Role updated.");
    await renderAdmin();
  } catch (err) {
    toast(err.message || "Could not update role.", "error");
  }
}

async function handlePromoteMember() {
  const alamanahNo = document.getElementById("promoteAlamanahNo").value.trim();
  const role = document.getElementById("promoteRole").value;
  const errBox = document.getElementById("promoteError");
  errBox.classList.remove("show"); errBox.textContent = "";

  const member = (currentMembers || []).find(m => (m.alamanah_no || "").toLowerCase() === alamanahNo.toLowerCase());
  if (!member) {
    errBox.textContent = "No member found with that Al-Amanah number.";
    errBox.classList.add("show");
    return;
  }
  if (!window.confirm(`Make ${member.first_name} ${member.surname} the ${role}?`)) return;
  try {
    await setProfileRole(member.id, role);
    toast("Role assigned.");
    await renderAdmin();
  } catch (err) {
    errBox.textContent = err.message || "Could not assign role.";
    errBox.classList.add("show");
  }
}

function handleSetOfficerEmail(profileId, name, currentEmail) {
  document.getElementById("setEmailProfileId").value = profileId;
  document.getElementById("setEmailMemberName").textContent = name;
  document.getElementById("setEmailInput").value = currentEmail || "";
  document.getElementById("setEmailError").textContent = "";
  document.getElementById("setEmailError").classList.remove("show");
  document.getElementById("setOfficerEmailModal").hidden = false;
}
function closeSetOfficerEmailModal() {
  document.getElementById("setOfficerEmailModal").hidden = true;
}
async function submitSetOfficerEmail() {
  const profileId = document.getElementById("setEmailProfileId").value;
  const email = document.getElementById("setEmailInput").value.trim();
  const errBox = document.getElementById("setEmailError");
  errBox.classList.remove("show"); errBox.textContent = "";
  if (!email) { errBox.textContent = "Enter an email address."; errBox.classList.add("show"); return; }
  const btn = document.getElementById("setEmailSubmitBtn");
  btn.disabled = true; btn.textContent = "Saving…";
  try {
    await setProfileEmail(profileId, email);
    toast("Sign-in email updated. They can now log in with it at their portal.");
    closeSetOfficerEmailModal();
    await renderAdmin();
  } catch (err) {
    errBox.textContent = err.message || "Could not update sign-in email.";
    errBox.classList.add("show");
  }
  btn.disabled = false; btn.textContent = "Save Email";
}

function openEditMemberDetailsModal(memberId) {
  const member = (currentMembers || []).find(m => m.id === memberId);
  if (!member) { toast("Could not find that member — try refreshing.", "error"); return; }
  document.getElementById("editDetailsProfileId").value = member.id;
  document.getElementById("editDetailsName").textContent = `${member.first_name} ${member.surname} — ${member.alamanah_no}`;
  document.getElementById("editDetailsFirstName").value = member.first_name || "";
  document.getElementById("editDetailsSurname").value = member.surname || "";
  document.getElementById("editDetailsDepartment").value = member.department || "";
  document.getElementById("editDetailsPhone").value = member.phone || "";
  document.getElementById("editDetailsEmail").value = member.contact_email || "";
  document.getElementById("editDetailsError").textContent = "";
  document.getElementById("editDetailsError").classList.remove("show");
  document.getElementById("editMemberDetailsModal").hidden = false;
}
function closeEditMemberDetailsModal() {
  document.getElementById("editMemberDetailsModal").hidden = true;
}
async function submitEditMemberDetails() {
  const profileId = document.getElementById("editDetailsProfileId").value;
  const firstName = document.getElementById("editDetailsFirstName").value.trim();
  const surname = document.getElementById("editDetailsSurname").value.trim();
  const department = document.getElementById("editDetailsDepartment").value.trim();
  const phone = document.getElementById("editDetailsPhone").value.trim();
  const email = document.getElementById("editDetailsEmail").value.trim();
  const errBox = document.getElementById("editDetailsError");
  errBox.classList.remove("show"); errBox.textContent = "";

  if (!firstName || !surname) {
    errBox.textContent = "First name and surname cannot be empty.";
    errBox.classList.add("show");
    return;
  }

  const btn = document.getElementById("editDetailsSubmitBtn");
  btn.disabled = true; btn.textContent = "Saving…";
  try {
    await updateMemberDetails(profileId, firstName, surname, department, phone);
    if (email) await setProfileEmail(profileId, email);
    toast("Member details updated.");
    closeEditMemberDetailsModal();
    await renderAdmin();
    if (!document.getElementById("memberDetailModal").hidden) await openMemberDetail(profileId);
  } catch (err) {
    errBox.textContent = err.message || "Could not update member details.";
    errBox.classList.add("show");
  }
  btn.disabled = false; btn.textContent = "Save Details";
}

function handleFixAlamanahNo(profileId, name, currentNo) {  document.getElementById("fixAlamanahProfileId").value = profileId;
  document.getElementById("fixAlamanahMemberName").textContent = name;
  document.getElementById("fixAlamanahCurrent").textContent = currentNo || "—";
  document.getElementById("fixAlamanahInput").value = "";
  document.getElementById("fixAlamanahError").textContent = "";
  document.getElementById("fixAlamanahError").classList.remove("show");
  document.getElementById("fixAlamanahNoModal").hidden = false;
}
function closeFixAlamanahNoModal() {
  document.getElementById("fixAlamanahNoModal").hidden = true;
}
async function submitFixAlamanahNo() {
  const profileId = document.getElementById("fixAlamanahProfileId").value;
  const newNo = document.getElementById("fixAlamanahInput").value.trim();
  const errBox = document.getElementById("fixAlamanahError");
  errBox.classList.remove("show"); errBox.textContent = "";
  if (!newNo) { errBox.textContent = "Enter their real Al-Amanah No."; errBox.classList.add("show"); return; }
  if (!window.confirm(`Change this member's Al-Amanah No. to "${normalizeAlamanahNo(newNo)}"? This is what they'll use to log back in as a member if their role is ever reassigned.`)) return;
  const btn = document.getElementById("fixAlamanahSubmitBtn");
  btn.disabled = true; btn.textContent = "Saving…";
  try {
    await updateProfileAlamanahNo(profileId, newNo);
    toast("Al-Amanah No. corrected.");
    closeFixAlamanahNoModal();
    await renderAdmin();
  } catch (err) {
    errBox.textContent = err.message || "Could not update Al-Amanah No.";
    errBox.classList.add("show");
  }
  btn.disabled = false; btn.textContent = "Save";
}

async function handleIssueAction(issueId, status) {
  let note = null;
  if (status === "resolved") {
    note = window.prompt("Resolution note (shown to the officer who reported this):", "");
    if (note === null) return; // cancelled
  }
  try {
    await resolveManagementIssue(issueId, status, note);
    toast(status === "resolved" ? "Issue marked resolved." : "Issue marked in progress.");
    renderManagementIssues();
  } catch (err) {
    toast("Could not update issue: " + err.message, "error");
  }
}

function renderPendingTable(pending) {
  const body = document.getElementById("pendingTableBody");
  if (!pending.length) {
    body.innerHTML = `<tr class="empty-row"><td colspan="9">No pending applications. All caught up.</td></tr>`;
    return;
  }
  body.innerHTML = pending.map(l => `
    <tr>
      <td class="mono-cell">${l.id}</td>
      <td>${l.memberName}</td>
      <td class="mono-cell">${l.memberNo}</td>
      <td>${LOAN_TYPES[l.type] ? LOAN_TYPES[l.type].label : l.type}</td>
      <td class="mono-cell">${formatNaira(l.amount)}</td>
      <td>${l.duration} mo.</td>
      <td style="max-width:220px;">${l.purpose}</td>
      <td>${formatDate(l.date_applied)}</td>
      <td style="display:flex;gap:8px;">
        <button class="btn btn-primary btn-sm" onclick="decideLoanClick('${l.id}','approved')">Approve</button>
        <button class="btn btn-danger btn-sm" onclick="decideLoanClick('${l.id}','declined')">Decline</button>
      </td>
    </tr>`).join("");
}

/* ---------- Members tab ---------- */

function filteredMembers(members) {
  const q = (document.getElementById("memberSearchInput")?.value || "").trim().toLowerCase();
  if (!q) return members;
  return members.filter(m =>
    `${m.first_name} ${m.surname}`.toLowerCase().includes(q) ||
    (m.alamanah_no || "").toLowerCase().includes(q)
  );
}

function renderMembersTable(members) {
  const body = document.getElementById("membersTableBody");
  const list = filteredMembers(members);
  if (!list.length) {
    body.innerHTML = `<tr class="empty-row"><td colspan="10">No members match that search.</td></tr>`;
    updateMembersBulkToolbar();
    return;
  }
  body.innerHTML = list.map(m => {
    const nextReview = nextSavingsReviewDate();
    const checked = selectedMemberIds.has(m.id) ? "checked" : "";
    return `<tr>
      <td class="checkbox-cell"><input type="checkbox" ${checked} onchange="toggleMemberSelected('${m.id}', this.checked)"></td>
      <td class="mono-cell">${m.alamanah_no}</td>
      <td>${m.first_name} ${m.surname}</td>
      <td class="mono-cell">${formatNaira(m.savings_balance)}</td>
      <td class="mono-cell">${formatNaira(m.monthly_savings_amount)}</td>
      <td class="mono-cell">${formatNaira(m.total_admin_charges)}</td>
      <td>${m.savings_paused ? '<span class="pill pill-wait">Paused</span>' : '<span class="pill pill-ok">Active</span>'}</td>
      <td>${m.deductions_paused ? '<span class="pill pill-wait">Paused</span>' : '<span class="pill pill-ok">Active</span>'}</td>
      <td>${statusBadge(m.status)}</td>
      <td>${formatDate(nextReview.toISOString().slice(0,10))}</td>
      <td><button class="btn btn-primary btn-sm" onclick="openMemberDetail('${m.id}')">View member</button></td>
    </tr>`;
  }).join("");
  updateMembersBulkToolbar();
}

function toggleSelectAllMembers(checked) {
  const list = filteredMembers(currentMembers);
  if (checked) list.forEach(m => selectedMemberIds.add(m.id));
  else list.forEach(m => selectedMemberIds.delete(m.id));
  renderMembersTable(currentMembers);
}
function toggleMemberSelected(memberId, checked) {
  if (checked) selectedMemberIds.add(memberId); else selectedMemberIds.delete(memberId);
  updateMembersBulkToolbar();
}
function updateMembersBulkToolbar() {
  const bar = document.getElementById("membersBulkToolbar");
  const count = document.getElementById("membersBulkCount");
  if (!bar || !count) return;
  bar.style.display = selectedMemberIds.size ? "flex" : "none";
  count.textContent = `${selectedMemberIds.size} selected`;
}

function statusBadge(status) {
  if (status === "active") return '<span class="pill pill-ok">Active</span>';
  if (status === "retired") return '<span class="pill pill-wait">Retired</span>';
  return '<span class="pill pill-bad">Dismissed</span>';
}

async function recordSavingsClick(memberId, name) {
  const input = window.prompt(`Enter this month's savings contribution for ${name} (₦). This full amount is credited to savings. A separate 7.5% administrative charge is also logged, deducted from salary — it does not reduce savings.`, "2000");
  if (input === null) return;
  const gross = Number(input);
  if (!gross || gross <= 0) { toast("Please enter a valid amount.", "error"); return; }
  try {
    await recordSavingsContribution(memberId, gross);
    const charge = Math.round(gross * 0.075);
    toast(`Recorded ${formatNaira(gross)} credited to savings. ${formatNaira(charge)} admin charge logged separately (from salary).`);
    renderAdmin();
  } catch (err) {
    toast(err.message || "Could not record contribution.", "error");
  }
}

async function setMonthlyAmountClick(memberId, name, current) {
  const input = window.prompt(`Set ${name}'s recurring monthly savings amount (₦). This is the amount used by "Process Monthly Savings for Selected".`, String(current || 0));
  if (input === null) return;
  const amount = Number(input);
  if (isNaN(amount) || amount < 0) { toast("Please enter a valid amount.", "error"); return; }
  try {
    await setMonthlySavingsAmount(memberId, amount);
    toast(`Monthly savings amount set to ${formatNaira(amount)} for ${name}.`);
    renderAdmin();
  } catch (err) {
    toast(err.message || "Could not set the monthly amount.", "error");
  }
}

async function toggleSavingsPausedClick(memberId, currentlyPaused) {
  try {
    await setSavingsPaused(memberId, !currentlyPaused);
    toast(currentlyPaused ? "Savings Deduction Resumed." : "Savings Deduction Paused.");
    renderAdmin();
  } catch (err) {
    toast(err.message || "Could not update savings pause status.", "error");
  }
}

async function undoSavingsClick(memberId, name, amount) {
  const reason = window.prompt(`Reason for undoing ${name}'s ${formatNaira(amount)} savings contribution this month (required):`, "");
  if (reason === null) return;
  if (!reason.trim()) { toast("A reason is required to undo this.", "error"); return; }
  try {
    await undoSavingsContribution(memberId, reason.trim());
    toast(`Undone. ${name} is eligible for savings processing again this month.`);
    renderAdmin();
    await refreshMemberDetailIfOpen();
  } catch (err) {
    toast(err.message || "Could not undo this contribution.", "error");
  }
}

async function toggleDeductionsPausedClick(memberId, currentlyPaused) {
  try {
    await setDeductionsPaused(memberId, !currentlyPaused);
    toast(currentlyPaused ? "Deduction Status: Resumed." : "Deduction Status: Paused.");
    renderAdmin();
  } catch (err) {
    toast(err.message || "Could not update deduction pause status.", "error");
  }
}

async function pauseResumeSelectedSavings(paused) {
  if (!selectedMemberIds.size) { toast("Select at least one member first.", "error"); return; }
  try {
    await setSavingsPausedBulk(Array.from(selectedMemberIds), paused);
    toast(`Savings ${paused ? "paused" : "resumed"} for ${selectedMemberIds.size} member(s).`);
    renderAdmin();
  } catch (err) {
    toast(err.message || "Could not update savings pause status.", "error");
  }
}
async function pauseResumeAllSavings(paused) {
  if (!currentMembers.length) return;
  if (!window.confirm(`${paused ? "Pause" : "Resume"} savings deductions for ALL ${currentMembers.length} members?`)) return;
  try {
    await setSavingsPausedBulk(currentMembers.map(m => m.id), paused);
    toast(`Savings ${paused ? "paused" : "resumed"} for all members.`);
    renderAdmin();
  } catch (err) {
    toast(err.message || "Could not update savings pause status.", "error");
  }
}
async function pauseResumeSelectedDeductions(paused) {
  if (!selectedMemberIds.size) { toast("Select at least one member first.", "error"); return; }
  try {
    await setDeductionsPausedBulk(Array.from(selectedMemberIds), paused);
    toast(`Deductions ${paused ? "paused" : "resumed"} for ${selectedMemberIds.size} member(s).`);
    renderAdmin();
  } catch (err) {
    toast(err.message || "Could not update deduction pause status.", "error");
  }
}

async function processSelectedSavings() {
  if (!selectedMemberIds.size) { toast("Select at least one member first.", "error"); return; }
  try {
    const results = await adminRecordSavingsBulk(Array.from(selectedMemberIds));
    const ok = results.filter(r => r.processed).length;
    const skipped = results.length - ok;
    toast(`Processed savings for ${ok} member(s).${skipped ? ` ${skipped} skipped (see console for reasons).` : ""}`);
    if (skipped) console.log("Skipped members:", results.filter(r => !r.processed));
    renderAdmin();
  } catch (err) {
    toast(err.message || "Could not process the selected members.", "error");
  }
}

async function markReviewedClick(memberId) {
  try {
    await updateMemberReview(memberId);
    toast("Savings review recorded for today.");
    renderAdmin();
    await refreshMemberDetailIfOpen();
  } catch (err) {
    toast(err.message || "Could not update review date.", "error");
  }
}

async function markReviewedBulk() {
  if (!selectedMemberIds.size) { toast("Select at least one member first.", "error"); return; }
  try {
    await updateMemberReviewBulk(Array.from(selectedMemberIds));
    toast(`Savings review recorded today for ${selectedMemberIds.size} member(s).`);
    renderAdmin();
  } catch (err) {
    toast(err.message || "Could not update review dates.", "error");
  }
}

async function statusChangeHandler(memberId, status) {
  if (!status) return;
  try {
    await updateMemberStatus(memberId, status);
    toast(`Member status updated to ${status}.`);
    renderAdmin();
  } catch (err) {
    toast(err.message || "Could not update status.", "error");
  }
}

/* ---------- Edit savings modal ---------- */

function openEditSavingsModal(memberId, name, previous) {
  editSavingsTarget = { id: memberId, name, previous };
  document.getElementById("editSavingsMemberName").textContent = name;
  document.getElementById("editSavingsPrevious").value = formatNaira(previous);
  document.getElementById("editSavingsNew").value = previous;
  document.getElementById("editSavingsReason").value = "";
  document.getElementById("editSavingsModal").hidden = false;
}
function closeEditSavingsModal() {
  document.getElementById("editSavingsModal").hidden = true;
  editSavingsTarget = null;
}
async function submitEditSavings() {
  if (!editSavingsTarget) return;
  const newAmount = Number(document.getElementById("editSavingsNew").value);
  const reason = document.getElementById("editSavingsReason").value.trim();
  if (isNaN(newAmount) || newAmount < 0) { toast("Please enter a valid amount.", "error"); return; }
  if (!reason) { toast("A reason is required for this adjustment.", "error"); return; }
  try {
    await editMemberSavings(editSavingsTarget.id, newAmount, reason);
    toast(`Savings updated for ${editSavingsTarget.name}: ${formatNaira(editSavingsTarget.previous)} → ${formatNaira(newAmount)}.`);
    closeEditSavingsModal();
    renderAdmin();
  } catch (err) {
    toast(err.message || "Could not save this adjustment.", "error");
  }
}

/* ---------- Edit admin charges modal ---------- */
let editChargeTarget = null; // { id, name, previous }

function openEditAdminChargeModal(memberId, name, previous) {
  editChargeTarget = { id: memberId, name, previous };
  document.getElementById("editChargeMemberName").textContent = name;
  document.getElementById("editChargePrevious").value = formatNaira(previous);
  document.getElementById("editChargeNew").value = previous;
  document.getElementById("editChargeReason").value = "";
  document.getElementById("editAdminChargeModal").hidden = false;
}
function closeEditAdminChargeModal() {
  document.getElementById("editAdminChargeModal").hidden = true;
  editChargeTarget = null;
}
async function submitEditAdminCharge() {
  if (!editChargeTarget) return;
  const newAmount = Number(document.getElementById("editChargeNew").value);
  const reason = document.getElementById("editChargeReason").value.trim();
  if (isNaN(newAmount) || newAmount < 0) { toast("Please enter a valid amount.", "error"); return; }
  if (!reason) { toast("A reason is required for this correction.", "error"); return; }
  try {
    await editMemberAdminCharges(editChargeTarget.id, newAmount, reason);
    toast(`Admin charges updated for ${editChargeTarget.name}: ${formatNaira(editChargeTarget.previous)} → ${formatNaira(newAmount)}.`);
    closeEditAdminChargeModal();
    renderAdmin();
    await refreshMemberDetailIfOpen();
  } catch (err) {
    toast(err.message || "Could not save this correction.", "error");
  }
}

/* ---------- Edit payslip modal ---------- */
let editPayslipTarget = null; // { id, name }

function openEditPayslipModal(memberId, name) {
  editPayslipTarget = { id: memberId, name };
  document.getElementById("editPayslipMemberName").textContent = name;
  document.getElementById("editPayslipMonth").value = new Date().toISOString().slice(0, 7);
  document.getElementById("editPayslipNote").value = "";
  document.getElementById("editPayslipModal").hidden = false;
  loadPayslipEditorForMonth();
}
function closeEditPayslipModal() {
  document.getElementById("editPayslipModal").hidden = true;
  editPayslipTarget = null;
}
function addPayslipLoanRow(label, amount) {
  const wrap = document.getElementById("editPayslipLoanRows");
  const row = document.createElement("div");
  row.className = "payslip-loan-row";
  row.style.cssText = "display:flex;gap:8px;margin-bottom:8px;align-items:center;";
  row.innerHTML = `
    <input type="text" class="payslip-loan-label" placeholder="e.g. Real Loan (LN-1234)" value="${label ? String(label).replace(/"/g, "&quot;") : ""}" style="flex:2;">
    <input type="number" class="payslip-loan-amount" placeholder="Amount (₦)" min="0" step="1" value="${amount !== undefined && amount !== null ? amount : ""}" style="flex:1;">
    <button type="button" class="btn btn-ghost btn-sm" onclick="this.parentElement.remove()">Remove</button>`;
  wrap.appendChild(row);
}
function clearPayslipLoanRows() {
  document.getElementById("editPayslipLoanRows").innerHTML = "";
}
function collectPayslipLoanRows() {
  return Array.from(document.querySelectorAll("#editPayslipLoanRows .payslip-loan-row")).map(row => ({
    label: row.querySelector(".payslip-loan-label").value.trim(),
    amount: Number(row.querySelector(".payslip-loan-amount").value) || 0
  })).filter(r => r.label || r.amount);
}

// Computes the same "live" figures dashboard.js would show for this
// member + month, used to pre-fill the editor when there's no saved
// override yet.
async function computeLivePayslipFigures(memberId, month) {
  const member = currentMembers.find(m => m.id === memberId);
  const loans = await getMemberLoans(memberId);
  const savings = Number(member?.monthly_savings_amount) || 0;
  const adminCharge = Math.round(savings * ADMIN_SAVINGS_CHARGE_RATE);
  const activeLoans = loans.filter(l => l.status === "approved");
  const loanRows = activeLoans.map(l => ({
    label: `${LOAN_TYPES[l.type] ? LOAN_TYPES[l.type].label : l.type}`,
    amount: Number(l.monthly_deduction) || 0
  })).filter(r => r.amount > 0);
  return { savings, adminCharge, loanRows };
}

async function loadPayslipEditorForMonth() {
  if (!editPayslipTarget) return;
  const month = document.getElementById("editPayslipMonth").value;
  const status = document.getElementById("editPayslipStatus");
  if (!month) return;
  status.textContent = "Loading…";
  clearPayslipLoanRows();
  try {
    const override = await getPayslipOverride(editPayslipTarget.id, month);
    if (override) {
      status.textContent = `This payslip has been manually edited (last saved ${formatDate(override.updated_at ? override.updated_at.slice(0, 10) : null)}).`;
      document.getElementById("editPayslipSavings").value = Number(override.savings_contribution) || 0;
      document.getElementById("editPayslipAdminCharge").value = Number(override.admin_charge) || 0;
      document.getElementById("editPayslipNote").value = override.note || "";
      (Array.isArray(override.loan_rows) ? override.loan_rows : []).forEach(r => addPayslipLoanRow(r.label, r.amount));
    } else {
      status.textContent = "No manual edit saved for this month yet — showing the standard figures (monthly savings, 7.5% charge, and active loan deductions).";
      const live = await computeLivePayslipFigures(editPayslipTarget.id, month);
      document.getElementById("editPayslipSavings").value = live.savings;
      document.getElementById("editPayslipAdminCharge").value = live.adminCharge;
      document.getElementById("editPayslipNote").value = "";
      live.loanRows.forEach(r => addPayslipLoanRow(r.label, r.amount));
    }
    if (!document.getElementById("editPayslipLoanRows").children.length) addPayslipLoanRow();
  } catch (err) {
    status.textContent = "";
    toast(err.message || "Could not load this member's payslip.", "error");
  }
}

async function submitEditPayslip() {
  if (!editPayslipTarget) return;
  const month = document.getElementById("editPayslipMonth").value;
  const savings = Number(document.getElementById("editPayslipSavings").value);
  const adminCharge = Number(document.getElementById("editPayslipAdminCharge").value);
  const note = document.getElementById("editPayslipNote").value.trim();
  const loanRows = collectPayslipLoanRows();
  if (!month) { toast("Choose a month first.", "error"); return; }
  if (isNaN(savings) || savings < 0 || isNaN(adminCharge) || adminCharge < 0) { toast("Please enter valid, non-negative amounts.", "error"); return; }
  try {
    await savePayslipOverride(editPayslipTarget.id, month, savings, adminCharge, loanRows, note);
    toast(`Payslip saved for ${editPayslipTarget.name} — ${month}. The member will see these figures immediately.`);
    closeEditPayslipModal();
  } catch (err) {
    toast(err.message || "Could not save this payslip.", "error");
  }
}

async function resetPayslipOverrideClick() {
  if (!editPayslipTarget) return;
  const month = document.getElementById("editPayslipMonth").value;
  if (!month) return;
  if (!window.confirm("Remove the manual edit for this month? The member's payslip will go back to being calculated automatically from transactions.")) return;
  try {
    await deletePayslipOverride(editPayslipTarget.id, month);
    toast("Manual edit removed — this payslip is now calculated automatically again.");
    await loadPayslipEditorForMonth();
  } catch (err) {
    toast(err.message || "Could not reset this payslip.", "error");
  }
}

/* ---------- Deductions tab ---------- */

function renderDeductionsTable(loans) {
  const body = document.getElementById("deductionsTableBody");
  if (!loans.length) {
    body.innerHTML = `<tr class="empty-row"><td colspan="8">No approved loans awaiting deduction.</td></tr>`;
    updateLoansBulkToolbar();
    return;
  }
  body.innerHTML = loans.map(l => {
    const checked = selectedLoanIds.has(l.id) ? "checked" : "";
    return `<tr>
      <td class="checkbox-cell"><input type="checkbox" ${checked} onchange="toggleLoanSelected('${l.id}', this.checked)"></td>
      <td class="mono-cell">${l.id}</td>
      <td>${l.memberName} <span class="mono-cell" style="color:var(--ink-soft);font-size:11.5px;">(${l.memberNo})</span></td>
      <td class="mono-cell">${formatNaira(l.balance)}</td>
      <td class="mono-cell">${formatNaira(Number(l.monthly_deduction) + Number(l.admin_monthly_deduction))}</td>
      <td>${l.months_paid}</td>
      <td>${l.deductionsPaused ? '<span class="pill pill-wait">Paused</span>' : '<span class="pill pill-ok">Active</span>'}</td>
      <td>
        <button class="btn btn-outline btn-sm" ${l.deductionsPaused ? "disabled" : ""} onclick="processSingleLoanDeduction('${l.id}')">Process this month</button>
      </td>
    </tr>`;
  }).join("");
  updateLoansBulkToolbar();
}

function toggleSelectAllLoans(checked) {
  if (checked) currentApprovedLoans.forEach(l => selectedLoanIds.add(l.id));
  else currentApprovedLoans.forEach(l => selectedLoanIds.delete(l.id));
  renderDeductionsTable(currentApprovedLoans);
}
function toggleLoanSelected(loanId, checked) {
  if (checked) selectedLoanIds.add(loanId); else selectedLoanIds.delete(loanId);
  updateLoansBulkToolbar();
}
function updateLoansBulkToolbar() {
  const bar = document.getElementById("loansBulkToolbar");
  const count = document.getElementById("loansBulkCount");
  if (!bar || !count) return;
  bar.style.display = selectedLoanIds.size ? "flex" : "none";
  count.textContent = `${selectedLoanIds.size} selected`;
}

async function processSingleLoanDeduction(loanId) {
  try {
    await adminRecordLoanDeduction(loanId);
    toast(`Recorded this month's deduction for ${loanId}.`);
    renderAdmin();
  } catch (err) {
    toast(err.message || "Could not record this deduction.", "error");
  }
}

async function processSelectedLoanDeductions() {
  if (!selectedLoanIds.size) { toast("Select at least one loan first.", "error"); return; }
  try {
    const results = await adminRecordLoanDeductionsBulk(Array.from(selectedLoanIds));
    const ok = results.filter(r => r.processed).length;
    const skipped = results.length - ok;
    toast(`Processed ${ok} loan deduction(s).${skipped ? ` ${skipped} could not be processed (see console).` : ""}`);
    if (skipped) console.log("Skipped loans:", results.filter(r => !r.processed));
    selectedLoanIds.clear();
    renderAdmin();
  } catch (err) {
    toast(err.message || "Could not process the selected loans.", "error");
  }
}

async function processAllEligibleLoanDeductions() {
  const eligible = currentApprovedLoans.filter(l => !l.deductionsPaused);
  if (!eligible.length) { toast("No eligible loans to process.", "error"); return; }
  if (!window.confirm(`Process this month's deduction for all ${eligible.length} eligible loan(s)?`)) return;
  try {
    const results = await adminRecordLoanDeductionsBulk(eligible.map(l => l.id));
    const ok = results.filter(r => r.processed).length;
    toast(`Processed ${ok} of ${eligible.length} loan deduction(s).`);
    renderAdmin();
  } catch (err) {
    toast(err.message || "Could not process deductions.", "error");
  }
}

/* ---------- Decision history ---------- */

function renderHistoryTable(loans) {
  const body = document.getElementById("historyTableBody");
  if (!loans.length) {
    body.innerHTML = `<tr class="empty-row"><td colspan="7">No decisions recorded yet.</td></tr>`;
    return;
  }
  body.innerHTML = loans.map(l => `
    <tr>
      <td class="mono-cell">${l.id}</td>
      <td>${l.memberName}</td>
      <td>${LOAN_TYPES[l.type] ? LOAN_TYPES[l.type].label : l.type}</td>
      <td class="mono-cell">${formatNaira(l.amount)}</td>
      <td>${l.status === "declined" ? '<span class="pill pill-bad">Declined</span>' : '<span class="pill pill-ok">Approved</span>'}</td>
      <td>${formatDate(l.date_decision)}</td>
      <td style="font-size:12.5px;color:var(--ink-soft)">${l.decline_reason || ""}</td>
    </tr>`).join("");
}

async function decideLoanClick(loanId, decision) {
  let reason = null;
  if (decision === "declined") {
    reason = window.prompt("Reason for declining this application (shown to member):", "Does not meet current eligibility criteria.");
    if (reason === null) return;
  }
  try {
    await decideLoanAdmin(loanId, decision, reason);
    toast(`${loanId} ${decision === "approved" ? "approved" : "declined"}.`);
    await renderAdmin();
  } catch (err) {
    toast(err.message || "Could not update this application.", "error");
  }
}


async function openMemberDetail(memberId) {
  const member = currentMembers.find(m => m.id === memberId);
  if (!member) return;
  document.getElementById("memberDetailModal").hidden = false;
  document.getElementById("memberDetailTitle").textContent = `${member.first_name} ${member.surname} — ${member.alamanah_no}`;
  const box = document.getElementById("memberDetailContent");
  box.textContent = "Loading member records…";
  try {
    const [loans, transactions, clearedTx, offsetHistory] = await Promise.all([
      getMemberLoans(memberId),
      getMemberTransactions(memberId, true),
      getMemberClearedTransactions(memberId),
      getMemberOffsetHistoryAdmin(memberId)
    ]);
    currentMemberDetailTx = transactions;
    currentMemberDetailLoans = loans;
    currentMemberDetailOffsetHistory = offsetHistory;
    currentLoanDetailMemberId = memberId;
    const active = loans.filter(l => l.status === "approved");
    const savingsTx = transactions.filter(t => t.type === "savings" || t.type === "admin_charge");
    const loanTx = transactions.filter(t => t.type === "loan");
    const cancellableCount = savingsTx.filter(t => !t.cancelled_at).length;
    const renderTxRow = (t, canCancel) => {
      const cancelled = !!t.cancelled_at;
      return `<tr style="opacity:${cancelled ? '.55' : '1'}"><td>${formatDate(t.date)}</td><td>${t.description}${cancelled ? `<div style="font-size:11px;color:var(--ink-soft);">Cancelled${t.cancel_reason ? ': ' + t.cancel_reason : ''}</div>` : ''}</td><td style="text-transform:capitalize">${t.type.replace('_',' ')}</td><td>${formatNaira(t.amount)}</td><td>${cancelled ? 'Cancelled' : 'Active'}</td><td style="white-space:nowrap;">${canCancel && !cancelled ? `<button class="btn btn-danger btn-sm" onclick="cancelTransactionClick('${t.id}','${memberId}')">Cancel</button> ` : ''}<button class="btn btn-outline btn-sm" onclick="clearTransactionClick('${t.id}','${memberId}')">Clear</button></td></tr>`;
    };
    const savingsTxRows = savingsTx.length ? savingsTx.map(t => renderTxRow(t, true)).join('') : '<tr><td colspan="6">No savings or admin-charge activity yet.</td></tr>';
    const loanTxRows = loanTx.length ? loanTx.map(t => renderTxRow(t, false)).join('') : '<tr><td colspan="6">No loan-related transactions yet.</td></tr>';
    const clearedRows = clearedTx.length ? clearedTx.map(t => `<tr>
        <td>${formatDate(t.date)}</td><td>${t.description}</td><td style="text-transform:capitalize">${t.type.replace('_',' ')}</td><td>${formatNaira(t.amount)}</td>
        <td>${t.clear_reason || '—'}</td>
        <td style="white-space:nowrap;"><button class="btn btn-outline btn-sm" onclick="restoreTransactionClick('${t.id}','${memberId}')">Restore</button> <button class="btn btn-danger btn-sm" onclick="deleteTransactionPermanentlyClick('${t.id}','${memberId}')">Delete permanently</button></td>
      </tr>`).join('') : '<tr><td colspan="6">No cleared records.</td></tr>';
    const offsetHistoryRows = offsetHistory.length ? offsetHistory.map(r => `<tr>
        <td>${formatDate(r.created_at)}</td><td class="mono-cell">${r.request_reference}</td><td>${formatNaira(r.total_amount)}</td>
        <td>${offsetStatusPillAdmin(r)}</td>
        <td style="white-space:nowrap;"><button class="btn btn-danger btn-sm" onclick="deleteOffsetRequestPermanentlyClick('${r.id}','${memberId}')">Delete permanently</button></td>
      </tr>`).join('') : '<tr><td colspan="5">No offset payment history for this member.</td></tr>';
    const monthlyAdminCharge = Math.round((Number(member.monthly_savings_amount) || 0) * ADMIN_SAVINGS_CHARGE_RATE);
    const deletableLoanCount = loans.filter(l => ["declined","offset","completed"].includes(l.status)).length;
    // Compact, clickable list — click a loan to open its full detail
    // in a dedicated modal instead of scrolling through every loan's
    // full ledger inline here.
    const loanRows = loans.length ? loans.map(l => `
      <div class="card" style="margin:10px 0;padding:16px 20px;cursor:pointer;display:flex;justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap;" onclick="openLoanDetail('${l.id}','${memberId}')">
        <div><strong>${LOAN_TYPES[l.type]?.label || l.type} — ${l.id}</strong>
          <div style="font-size:12.5px;color:var(--ink-soft);margin-top:2px;">Outstanding: ${formatNaira(l.balance)}</div>
        </div>
        <div style="display:flex;align-items:center;gap:10px;">${loanStatusPillAdmin(l.status)}<span aria-hidden="true" style="color:var(--ink-soft);">&#8250;</span></div>
      </div>`).join('') : '<p class="lede">No loan records for this member.</p>';
    const nextReview = nextSavingsReviewDate();
    const monthStart = new Date(); monthStart.setDate(1); monthStart.setHours(0,0,0,0);
    const canUndoSavings = member.last_savings_date && new Date(member.last_savings_date) >= monthStart;
    box.innerHTML = `<div class="dash-grid"><div class="card"><h4>Identity &amp; contact</h4>
      <p><strong>Department:</strong> ${member.department || '<span class="hint">Not set</span>'}</p>
      <p><strong>Phone:</strong> ${member.phone || '<span class="hint">Not set</span>'}</p>
      <p><strong>Email:</strong> ${member.contact_email || '<span class="hint">Not set — Forgot Password will not work for this member until one is added</span>'}</p>
      <button class="btn btn-outline btn-sm" onclick="openEditMemberDetailsModal('${member.id}')">Edit Details</button>
    </div>
    <div class="card"><h4>Savings & deductions</h4>
      <p><strong>Savings balance:</strong> ${formatNaira(member.savings_balance)}</p>
      <p><strong>Monthly savings amount:</strong> ${formatNaira(member.monthly_savings_amount)}</p>
      <p><strong>Monthly administrative charge (7.5%):</strong> ${formatNaira(monthlyAdminCharge)} <span style="font-size:11.5px;color:var(--ink-soft);">— charged on top of savings, deducted from salary separately, never reduces savings</span></p>
      <p><strong>Total administrative charges (lifetime):</strong> ${formatNaira(member.total_admin_charges)}</p>
      <p><strong>Savings status:</strong> ${member.savings_paused ? 'Paused' : 'Active'}</p>
      <p><strong>Loan deduction status:</strong> ${member.deductions_paused ? 'Paused' : 'Active'}</p>
      <p><strong>Next savings review:</strong> ${formatDate(nextReview.toISOString().slice(0,10))}</p>
      <div class="action-menu">
        <button class="btn btn-primary btn-sm" onclick="toggleActionMenu(this)">Manage Savings &amp; Deductions &#9662;</button>
        <div class="action-menu-list" hidden>
          <div class="action-menu-label">Savings</div>
          <button onclick="recordSavingsClick('${member.id}','${member.first_name} ${member.surname}')">Record savings</button>
          <button onclick="setMonthlyAmountClick('${member.id}','${member.first_name} ${member.surname}', ${Number(member.monthly_savings_amount)||0})">Set monthly savings amount</button>
          <button onclick="openEditSavingsModal('${member.id}','${member.first_name} ${member.surname}', ${Number(member.savings_balance)||0})">Edit savings balance</button>
          <button onclick="markReviewedClick('${member.id}')">Mark savings review complete</button>
          <button onclick="toggleSavingsPausedClick('${member.id}', ${!!member.savings_paused})">${member.savings_paused ? 'Resume savings' : 'Pause savings'}</button>
          ${canUndoSavings ? `<button onclick="undoSavingsClick('${member.id}','${member.first_name} ${member.surname}', ${Number(member.last_savings_amount)||0})">Undo this month's savings (${formatNaira(member.last_savings_amount)})</button>` : ''}
          <div class="action-menu-divider"></div>
          <div class="action-menu-label">Charges &amp; payslip</div>
          <button onclick="openEditAdminChargeModal('${member.id}','${member.first_name} ${member.surname}', ${Number(member.total_admin_charges)||0})">Edit admin charges</button>
          <button onclick="openEditPayslipModal('${member.id}','${member.first_name} ${member.surname}')">Edit payslip</button>
          <div class="action-menu-divider"></div>
          <div class="action-menu-label">Loan deductions</div>
          <button onclick="toggleDeductionsPausedClick('${member.id}', ${!!member.deductions_paused})">${member.deductions_paused ? 'Resume deductions' : 'Pause deductions'}</button>
        </div>
      </div></div>
      <div class="card"><h4>Loan summary</h4><p><strong>Active loans:</strong> ${active.length}</p><p><strong>Outstanding:</strong> ${formatNaira(active.reduce((sum,l)=>sum+Number(l.balance||0),0))}</p></div></div>
      <div class="section-heading" style="margin-top:24px;display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:8px;">
        <div><h3>Loans</h3><span class="lede">Click a loan to view its full ledger and actions.</span></div>
        <button class="btn btn-danger btn-sm" ${deletableLoanCount ? "" : "disabled"} onclick="deleteAllLoansPermanentlyClick('${memberId}')" title="Permanently deletes every declined, offset, or completed loan below — active/pending loans are left untouched">Delete All Permanently${deletableLoanCount ? ` (${deletableLoanCount})` : ""}</button>
      </div>${loanRows}

      <div class="section-heading" style="margin-top:24px;display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:8px;">
        <div><h3>History Management</h3><span class="lede">Clearing removes records from what the member sees with no trace — it does not touch any balance. Cleared items move to the archive below and can be restored any time.</span></div>
      </div>
      <div class="action-menu" style="margin-bottom:8px;">
        <button class="btn btn-outline btn-sm" onclick="toggleActionMenu(this)">Clear History &#9662;</button>
        <div class="action-menu-list" hidden>
          <button onclick="clearCategoryClick('${memberId}','savings')">Clear savings history</button>
          <button onclick="clearCategoryClick('${memberId}','admin_charge')">Clear admin charge history</button>
          <button onclick="clearCategoryClick('${memberId}','loan')">Clear loan history</button>
          <button onclick="clearPayslipHistoryClick('${memberId}')">Clear payslip history</button>
          <div class="action-menu-divider"></div>
          <button class="danger" onclick="clearCategoryClick('${memberId}','all')">Clear all member history</button>
        </div>
      </div>

      <div class="section-heading" style="margin-top:24px;display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:8px;">
        <div><h3>My Savings Details</h3><span class="lede">Savings contributions and administrative-charge entries for this member — the same records they see under "My Savings" on their own dashboard.</span></div>
        <button class="btn btn-danger btn-sm" ${cancellableCount ? "" : "disabled"} onclick="cancelAllTransactionsClick('${memberId}')" title="Reverses every active savings/admin-charge entry below and restores the balances to before they were recorded">Reset all (${cancellableCount})</button>
      </div>
      <div class="table-wrap"><table><thead><tr><th>Date</th><th>Description</th><th>Type</th><th>Amount</th><th>Status</th><th>Action</th></tr></thead><tbody>${savingsTxRows}</tbody></table></div>

      <div class="section-heading" style="margin-top:24px;"><h3>Loan Deduction History</h3><span class="lede">Balances here are corrected with "Offset" or "Reset" on the loan's detail view above — "Clear" only hides the log entry from the member's view.</span></div>
      <div class="table-wrap"><table><thead><tr><th>Date</th><th>Description</th><th>Type</th><th>Amount</th><th>Status</th><th>Action</th></tr></thead><tbody>${loanTxRows}</tbody></table></div>

      <div class="section-heading" style="margin-top:24px;display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:8px;">
        <div><h3>Cleared / Archived Records</h3><span class="lede">Admin-only. These are completely invisible to the member unless restored.</span></div>
        <button class="btn btn-danger btn-sm" ${clearedTx.length ? "" : "disabled"} onclick="deleteAllClearedPermanentlyClick('${memberId}')" title="Permanently deletes every record below — this cannot be undone">Delete All Permanently${clearedTx.length ? ` (${clearedTx.length})` : ""}</button>
      </div>
      <div class="table-wrap"><table><thead><tr><th>Date</th><th>Description</th><th>Type</th><th>Amount</th><th>Reason</th><th>Action</th></tr></thead><tbody>${clearedRows}</tbody></table></div>

      <div class="section-heading" style="margin-top:24px;display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:8px;">
        <div><h3>Loan Offset History</h3><span class="lede">The same payment history this member sees on their own dashboard. No status gate here — a pending/unconfirmed request can be deleted too.</span></div>
        <button class="btn btn-danger btn-sm" ${offsetHistory.length ? "" : "disabled"} onclick="deleteAllOffsetHistoryPermanentlyClick('${memberId}')" title="Permanently deletes every offset request below — this cannot be undone">Delete All Permanently${offsetHistory.length ? ` (${offsetHistory.length})` : ""}</button>
      </div>
      <div class="table-wrap"><table><thead><tr><th>Date</th><th>Reference</th><th>Amount</th><th>Status</th><th>Action</th></tr></thead><tbody>${offsetHistoryRows}</tbody></table></div>

      <div class="section-heading" style="margin-top:24px;"><h3 style="color:var(--danger);">Danger Zone</h3><span class="lede">Permanently deletes this member's login and every record tied to them — loans, transactions, savings and admin-charge history, payslip records, everything. Unlike "Clear History" above, this cannot be undone and there is nothing to restore afterwards. Their Al-Amanah No. becomes available for reuse.</span></div>
      <div style="margin-bottom:8px;">
        <button class="btn btn-danger btn-sm" onclick="openExpungeMemberModal('${member.id}','${member.first_name} ${member.surname}','${member.alamanah_no}')">Expunge Member</button>
      </div>`;
  } catch (err) { box.innerHTML = `<p class="form-error show">${err.message || 'Could not load member details.'}</p>`; }
}
function closeMemberDetail(){ document.getElementById("memberDetailModal").hidden = true; closeLoanDetail(); }

/* ---------- Expunge Member (Danger Zone) ----------
   Irreversible: permanently deletes the member's login and every
   record tied to them. Guarded by a typed confirmation of their
   exact Al-Amanah No. (not just a click-through confirm dialog)
   plus a required reason, since there is nothing to restore after. */
let expungeTarget = null; // { id, name, alamanahNo }
function openExpungeMemberModal(memberId, memberName, alamanahNo) {
  expungeTarget = { id: memberId, name: memberName, alamanahNo };
  document.getElementById("expungeMemberName").textContent = `${memberName} — ${alamanahNo}`;
  document.getElementById("expungeConfirmNo").value = "";
  document.getElementById("expungeConfirmNo").placeholder = alamanahNo;
  document.getElementById("expungeReason").value = "";
  document.getElementById("expungeSubmitBtn").disabled = true;
  document.getElementById("expungeError").classList.remove("show");
  document.getElementById("expungeMemberModal").hidden = false;
}
function closeExpungeMemberModal() {
  document.getElementById("expungeMemberModal").hidden = true;
  expungeTarget = null;
}
function checkExpungeConfirmMatch() {
  const typed = document.getElementById("expungeConfirmNo").value.trim();
  document.getElementById("expungeSubmitBtn").disabled = !(expungeTarget && typed === expungeTarget.alamanahNo);
}
async function submitExpungeMember() {
  if (!expungeTarget) return;
  const reason = document.getElementById("expungeReason").value.trim();
  const errBox = document.getElementById("expungeError");
  errBox.classList.remove("show");
  if (!reason) { errBox.textContent = "A reason is required."; errBox.classList.add("show"); return; }
  const btn = document.getElementById("expungeSubmitBtn");
  btn.disabled = true; btn.textContent = "Expunging…";
  try {
    await expungeMemberAdmin(expungeTarget.id, reason);
    toast(`${expungeTarget.name} has been permanently expunged.`);
    closeExpungeMemberModal();
    closeMemberDetail();
    renderAdmin();
  } catch (err) {
    errBox.textContent = err.message || "Could not expunge this member.";
    errBox.classList.add("show");
    btn.disabled = false;
  }
  btn.textContent = "Permanently Expunge";
}
async function cancelTransactionClick(transactionId, memberId) {
  const reason = window.prompt("Reason for cancelling this transaction (optional):") || "";
  if (!window.confirm("Cancel this transaction? It will be removed from the member's active histories and the related savings/admin-charge balance will be reversed.")) return;
  try { await cancelTransactionAdmin(transactionId, reason); toast("Transaction cancelled and member records synchronised."); await renderAdmin(); await openMemberDetail(memberId); }
  catch (err) { toast(err.message || "Could not cancel transaction.", "error"); }
}
async function cancelAllTransactionsClick(memberId) {
  const eligible = currentMemberDetailTx.filter(t => !t.cancelled_at && t.type !== "loan");
  if (!eligible.length) { toast("Nothing eligible to cancel for this member.", "error"); return; }
  const reason = window.prompt(`Reason for cancelling all ${eligible.length} active savings/admin-charge record(s) for this member (optional):`) || "";
  if (!window.confirm(`Cancel all ${eligible.length} active record(s)? Each will be reversed from the member's savings/admin-charge balance and marked cancelled — loan entries are left untouched.`)) return;
  try {
    const results = await cancelAllMemberTransactionsAdmin(memberId, reason);
    const ok = results.filter(r => r.processed).length;
    const skipped = results.length - ok;
    toast(`Cancelled ${ok} record(s).${skipped ? ` ${skipped} could not be cancelled (see console).` : ""}`);
    if (skipped) console.log("Skipped transactions:", results.filter(r => !r.processed));
    await renderAdmin();
    await openMemberDetail(memberId);
  } catch (err) {
    toast(err.message || "Could not cancel these transactions.", "error");
  }
}
async function clearTransactionClick(transactionId, memberId) {
  const reason = window.prompt("Internal note for clearing this record (admin-only, optional):") || "";
  if (!window.confirm("Clear this record? It will disappear completely from the member's dashboard/history/payslip with no trace, and no balance is changed. You can restore it later from Cleared/Archived Records.")) return;
  try { await clearTransactionAdmin(transactionId, reason); toast("Record cleared."); await openMemberDetail(memberId); }
  catch (err) { toast(err.message || "Could not clear this record.", "error"); }
}
async function restoreTransactionClick(transactionId, memberId) {
  if (!window.confirm("Restore this record? The member will see it again exactly as before.")) return;
  try { await restoreTransactionAdmin(transactionId); toast("Record restored."); await openMemberDetail(memberId); }
  catch (err) { toast(err.message || "Could not restore this record.", "error"); }
}
async function deleteTransactionPermanentlyClick(transactionId, memberId) {
  if (!window.confirm("Permanently delete this record? This cannot be undone — there will be no way to restore it afterwards.")) return;
  try { await deleteTransactionPermanentlyAdmin(transactionId); toast("Record permanently deleted."); await openMemberDetail(memberId); }
  catch (err) { toast(err.message || "Could not delete this record.", "error"); }
}
const CLEAR_CATEGORY_LABELS = { savings: "Savings History", admin_charge: "Administrative Charge History", loan: "Loan History", all: "ALL member history" };
async function clearCategoryClick(memberId, category) {
  const label = CLEAR_CATEGORY_LABELS[category] || category;
  const reason = window.prompt(`Internal note for clearing ${label} (admin-only, optional):`) || "";
  if (!window.confirm(`Clear ${label} for this member? Every matching record disappears completely from their dashboard/history/payslip with no trace, and no balance is changed. Everything cleared can be restored later from Cleared/Archived Records.`)) return;
  try {
    const results = await clearMemberHistoryAdmin(memberId, category, reason);
    const ok = results.filter(r => r.processed).length;
    toast(`Cleared ${ok} record(s) from ${label}.`);
    await openMemberDetail(memberId);
  } catch (err) { toast(err.message || "Could not clear history.", "error"); }
}
async function clearPayslipHistoryClick(memberId) {
  if (!window.confirm("Clear all saved payslip corrections for this member? Every month reverts to the standard, automatically calculated payslip. This cannot be undone (there is nothing to restore — the member simply goes back to the live figures).")) return;
  try {
    const count = await clearPayslipHistoryAdmin(memberId);
    toast(`Cleared ${count} saved payslip correction(s).`);
  } catch (err) { toast(err.message || "Could not clear payslip history.", "error"); }
}
async function offsetLoanClick(loanId) {
  const reason = window.prompt("Reason for loan offset (optional):", "Loan settled/offset by administrator.");
  if (reason === null) return;
  const memberId = currentLoanDetailMemberId;
  try {
    await offsetLoanAdmin(loanId, reason);
    toast("Loan offset successfully.");
    closeLoanDetail();
    await renderAdmin();
    if (memberId) await openMemberDetail(memberId);
  } catch(err){ toast(err.message || "Could not offset loan.", "error"); }
}
async function resetLoanClick(loanId) {
  if (!window.confirm("Reset this loan to its original full obligation? This does not delete history.")) return;
  const reason = window.prompt("Reason for reset:", "Administrative correction");
  if (reason === null) return;
  const memberId = currentLoanDetailMemberId;
  try {
    await resetLoanAdmin(loanId, reason);
    toast("Loan reset successfully.");
    closeLoanDetail();
    await renderAdmin();
    if (memberId) await openMemberDetail(memberId);
  } catch(err){ toast(err.message || "Could not reset loan.", "error"); }
}
async function refreshMemberDetailIfOpen(){ /* renderAdmin refreshes list; close to avoid stale duplicate actions */ closeMemberDetail(); }

/* ---------- Loan Detail modal ----------
   Clicking a loan in the member modal's Loans list opens its full
   ledger and actions here, instead of every loan's card being shown
   inline (which meant scrolling through them all). */
function openLoanDetail(loanId, memberId) {
  const loan = currentMemberDetailLoans.find(l => l.id === loanId);
  if (!loan) { toast("Could not find that loan — try refreshing.", "error"); return; }
  currentLoanDetailMemberId = memberId;
  const total = Number(loan.amount || 0) + Number(loan.admin_charge || 0);
  const deletable = ["declined", "offset", "completed"].includes(loan.status);
  const monthStart = new Date(); monthStart.setDate(1); monthStart.setHours(0,0,0,0);
  const canUndoDeduction = loan.last_deduction_date && new Date(loan.last_deduction_date) >= monthStart;
  const lastDeductionTotal = (Number(loan.last_deduction_loan_cut) || 0) + (Number(loan.last_deduction_admin_cut) || 0);
  const undoButton = canUndoDeduction ? `<button class="btn btn-outline btn-sm" onclick="undoLoanDeductionClick('${loan.id}', ${lastDeductionTotal})">Undo this month's deduction (${formatNaira(lastDeductionTotal)})</button>` : '';
  const actions = (loan.status === "approved" ? `
    <button class="btn btn-outline btn-sm" onclick="processLoanDeductionFromDetail('${loan.id}')">Process deduction</button>
    <button class="btn btn-outline btn-sm" onclick="offsetLoanClick('${loan.id}')">Offset loan</button>
    <button class="btn btn-outline btn-sm" onclick="resetLoanClick('${loan.id}')">Reset loan</button>` : '') + undoButton;
  document.getElementById("loanDetailTitle").textContent = `${LOAN_TYPES[loan.type]?.label || loan.type} — ${loan.id}`;
  document.getElementById("loanDetailContent").innerHTML = `
    <div class="ledger-rows">
      <div class="ledger-row"><span>Loan amount</span><span>${formatNaira(loan.amount)}</span></div>
      <div class="ledger-row"><span>Commodity charge</span><span>${formatNaira(loan.admin_charge)}</span></div>
      <div class="ledger-row"><span>Total obligation</span><span>${formatNaira(total)}</span></div>
      <div class="ledger-row"><span>Outstanding balance</span><span>${formatNaira(loan.balance)}</span></div>
      <div class="ledger-row"><span>Status</span><span>${loanStatusPillAdmin(loan.status)}</span></div>
    </div>
    <div style="display:flex;gap:8px;flex-wrap:wrap;margin-top:16px;">${actions}</div>
    <div style="margin-top:20px;padding-top:16px;border-top:1px solid rgba(11,59,35,.12);">
      <button class="btn btn-danger btn-sm" ${deletable ? "" : "disabled"} onclick="deleteLoanPermanentlyClick('${loan.id}')">Delete Permanently</button>
      ${deletable ? "" : '<div class="hint" style="margin-top:6px;">Only a declined, offset, or completed loan can be permanently deleted.</div>'}
    </div>`;
  document.getElementById("loanDetailModal").hidden = false;
}
function closeLoanDetail() { document.getElementById("loanDetailModal").hidden = true; }

async function processLoanDeductionFromDetail(loanId) {
  const memberId = currentLoanDetailMemberId;
  try {
    await adminRecordLoanDeduction(loanId);
    toast(`Recorded this month's deduction for ${loanId}.`);
    closeLoanDetail();
    await renderAdmin();
    if (memberId) await openMemberDetail(memberId);
  } catch (err) { toast(err.message || "Could not record this deduction.", "error"); }
}

async function undoLoanDeductionClick(loanId, amount) {
  const reason = window.prompt(`Reason for undoing the ${formatNaira(amount)} deduction recorded this month for ${loanId} (required):`, "");
  if (reason === null) return;
  if (!reason.trim()) { toast("A reason is required to undo this.", "error"); return; }
  const memberId = currentLoanDetailMemberId;
  try {
    await undoLoanDeduction(loanId, reason.trim());
    toast(`Undone. ${loanId} is eligible for deduction processing again this month.`);
    closeLoanDetail();
    await renderAdmin();
    if (memberId) await openMemberDetail(memberId);
  } catch (err) { toast(err.message || "Could not undo this deduction.", "error"); }
}

async function deleteLoanPermanentlyClick(loanId) {
  if (!window.confirm("Permanently delete this loan? This removes the loan and its related log entries with no trace, and cannot be undone.")) return;
  const memberId = currentLoanDetailMemberId;
  try {
    await deleteLoanPermanentlyAdmin(loanId);
    toast("Loan permanently deleted.");
    closeLoanDetail();
    await renderAdmin();
    if (memberId) await openMemberDetail(memberId);
  } catch (err) { toast(err.message || "Could not delete this loan.", "error"); }
}

async function deleteAllLoansPermanentlyClick(memberId) {
  const eligible = currentMemberDetailLoans.filter(l => ["declined", "offset", "completed"].includes(l.status));
  if (!eligible.length) { toast("No eligible loans to delete for this member.", "error"); return; }
  if (!window.confirm(`Permanently delete all ${eligible.length} declined/offset/completed loan(s) for this member? This cannot be undone — active or pending loans are left untouched.`)) return;
  try {
    const results = await deleteAllLoansPermanentlyAdmin(memberId);
    const ok = results.filter(r => r.processed).length;
    const skipped = results.length - ok;
    toast(`Permanently deleted ${ok} loan(s).${skipped ? ` ${skipped} could not be deleted (see console).` : ""}`);
    if (skipped) console.log("Skipped loans:", results.filter(r => !r.processed));
    await renderAdmin();
    await openMemberDetail(memberId);
  } catch (err) { toast(err.message || "Could not delete these loans.", "error"); }
}

async function deleteAllClearedPermanentlyClick(memberId) {
  if (!window.confirm("Permanently delete every cleared/archived record for this member? This cannot be undone — there will be no way to restore them afterwards.")) return;
  try {
    const count = await deleteAllClearedTransactionsAdmin(memberId);
    toast(`Permanently deleted ${count} record(s).`);
    await openMemberDetail(memberId);
  } catch (err) { toast(err.message || "Could not delete these records.", "error"); }
}

async function deleteOffsetRequestPermanentlyClick(requestId, memberId) {
  if (!window.confirm("Permanently delete this offset payment record? This cannot be undone — there will be no way to restore it afterwards.")) return;
  try {
    await deleteOffsetRequestPermanentlyAdmin(requestId);
    toast("Offset payment record permanently deleted.");
    await openMemberDetail(memberId);
  } catch (err) { toast(err.message || "Could not delete this record.", "error"); }
}

async function deleteAllOffsetHistoryPermanentlyClick(memberId) {
  if (!currentMemberDetailOffsetHistory.length) { toast("No offset history to delete for this member.", "error"); return; }
  if (!window.confirm(`Permanently delete all ${currentMemberDetailOffsetHistory.length} offset payment record(s) for this member? This cannot be undone.`)) return;
  try {
    const count = await deleteAllOffsetRequestsPermanentlyAdmin(memberId);
    toast(`Permanently deleted ${count} offset record(s).`);
    await openMemberDetail(memberId);
  } catch (err) { toast(err.message || "Could not delete these records.", "error"); }
}

document.addEventListener("DOMContentLoaded", async () => {
  const profile = await getMyProfile();
  if (profile && profile.is_admin) showAdminPanel(); else showAdminLogin();

  document.getElementById("adminLoginForm").addEventListener("submit", async (e) => {
    e.preventDefault();
    const email = document.getElementById("adminUser").value.trim();
    const pass = document.getElementById("adminPass").value;
    const errBox = document.getElementById("adminLoginError");
    const btn = document.getElementById("adminLoginSubmit");
    errBox.classList.remove("show");
    btn.disabled = true; btn.textContent = "Logging in…";
    try {
      await adminLogin(email, pass);
      showAdminPanel();
      toast("Login successful.");
    } catch (err) {
      errBox.textContent = err.message || "Incorrect email or password.";
      errBox.classList.add("show");
    }
    btn.disabled = false; btn.textContent = "Log in to admin panel";
  });

  document.getElementById("adminLogoutBtn").addEventListener("click", async () => {
    await logoutUser();
    showAdminLogin();
    toast("Logged out successfully.");
  });

  const vamBtn = document.getElementById("adminViewAsMemberBtn");
  if (vamBtn) vamBtn.addEventListener("click", () => {
    sessionStorage.setItem("viewAsMember", "1");
    window.location.href = "dashboard.html";
  });
});


function openCreateMemberModal(){ document.getElementById("createMemberModal").hidden=false; }
function closeCreateMemberModal(){ document.getElementById("createMemberModal").hidden=true; document.getElementById("createMemberForm").reset(); cmAdminChargeTouched = false; }
function openBulkMemberModal(){ document.getElementById("bulkMemberModal").hidden=false; }
function closeBulkMemberModal(){ document.getElementById("bulkMemberModal").hidden=true; }
// Whether the admin has manually edited the admin-charge field for
// the member currently being created. Once true, typing in Monthly
// Savings Amount no longer overwrites their entry — the suggestion
// only fills the field in until they've touched it themselves.
let cmAdminChargeTouched = false;
function suggestCmAdminCharge(){
  if (cmAdminChargeTouched) return;
  const monthly = Number(document.getElementById("cmMonthly").value) || 0;
  document.getElementById("cmAdminCharge").value = Math.round(monthly * ADMIN_SAVINGS_CHARGE_RATE);
}
async function submitCreateMember(e){
  e.preventDefault(); const msg=document.getElementById("createMemberMsg"); msg.textContent="Adding member…";
  try{
    const member={alamanah_no:cmNo.value.trim(),first_name:cmFirst.value.trim(),surname:cmSurname.value.trim(),department:cmDept.value.trim(),phone:cmPhone.value.trim(),contact_email:cmEmail.value.trim(),monthly_savings_amount:Number(cmMonthly.value||0),savings_balance:Number(cmSavings.value||0),total_admin_charges:Number(cmAdminCharge.value||0)};
    await createMemberDirectoryEntry(member);
    msg.textContent=`Added. Give ${member.first_name} their Al-Amanah No. (${member.alamanah_no}) and surname (${member.surname}) — they set up their own password at Member Login → "Set up your password".`;
    e.target.reset(); cmAdminChargeTouched = false; renderAdmin();
  }catch(err){ msg.textContent="Error: "+(err.message||"Could not add member"); }
}
async function submitBulkMembers(){
  const file=document.getElementById("bulkMemberFile").files[0], msg=document.getElementById("bulkMemberMsg");
  if(!file){ msg.textContent="Please choose a CSV file first."; return; }
  msg.textContent="Reading file…";
  try{
    const text=await file.text(); const lines=text.trim().split(/\r?\n/); const headers=lines.shift().split(",").map(x=>x.trim());
    const rows=lines.filter(Boolean).map(line=>{ const v=line.split(",").map(x=>x.trim()); const o={}; headers.forEach((h,i)=>o[h]=v[i]||""); return o; });
    if(!rows.length) throw new Error("The CSV contains no member rows.");
    msg.textContent="Uploading "+rows.length+" members…";
    const d=await bulkCreateMemberDirectoryEntries(rows);
    msg.textContent=`Completed: ${d.created||0} added, ${d.failed||0} failed.${d.errors?.length?" "+d.errors.join(" | "):""} Each member sets up their own password at Member Login → "Set up your password" using their Al-Amanah No. and surname.`;
    renderAdmin();
  }catch(err){ msg.textContent="Error: "+(err.message||"Bulk upload failed"); }
}

/* ---------- pending (not-yet-claimed) member directory entries ---------- */
let selectedPendingDirectory = new Set();

async function renderPendingDirectory(){
  const box = document.getElementById("pendingDirectoryBody");
  if (!box) return;
  selectedPendingDirectory.clear();
  updatePendingBulkToolbar();
  try{
    const rows = await getPendingDirectoryMembers();
    document.getElementById("pendingDirectoryCount").textContent = rows.length;
    if (!rows.length){ box.innerHTML = `<tr class="empty-row"><td colspan="8">No members waiting to register.</td></tr>`; return; }
    box.innerHTML = rows.map(r => `<tr>
      <td class="checkbox-cell"><input type="checkbox" class="pending-row-checkbox" value="${r.alamanah_no}" onchange="togglePendingSelection('${r.alamanah_no}', this.checked)"></td>
      <td class="mono-cell">${r.alamanah_no}</td>
      <td>${r.first_name} ${r.surname}</td>
      <td>${r.department || "—"}</td>
      <td class="mono-cell">${formatNaira(r.savings_balance)}</td>
      <td class="mono-cell">${formatNaira(r.monthly_savings_amount)}</td>
      <td class="mono-cell">${formatNaira(r.total_admin_charges)}</td>
      <td><button class="btn btn-danger btn-sm" onclick="deletePendingDirectoryClick('${r.alamanah_no}')">Remove</button></td>
    </tr>`).join("");
  }catch(err){ box.innerHTML = `<tr class="empty-row"><td colspan="8">${err.message || "Could not load."}</td></tr>`; }
}
async function deletePendingDirectoryClick(alamanahNo){
  if (!window.confirm(`Remove ${alamanahNo} from the pending list? They will no longer be able to register.`)) return;
  try{ await deletePendingDirectoryMember(alamanahNo); toast("Removed."); renderPendingDirectory(); }
  catch(err){ toast(err.message || "Could not remove.", "error"); }
}
function togglePendingSelection(alamanahNo, checked){
  if (checked) selectedPendingDirectory.add(alamanahNo);
  else selectedPendingDirectory.delete(alamanahNo);
  const selectAll = document.getElementById("pendingSelectAll");
  if (selectAll) selectAll.checked = selectedPendingDirectory.size > 0 &&
    selectedPendingDirectory.size === document.querySelectorAll(".pending-row-checkbox").length;
  updatePendingBulkToolbar();
}
function toggleSelectAllPending(checked){
  selectedPendingDirectory.clear();
  document.querySelectorAll(".pending-row-checkbox").forEach(cb => {
    cb.checked = checked;
    if (checked) selectedPendingDirectory.add(cb.value);
  });
  updatePendingBulkToolbar();
}
function updatePendingBulkToolbar(){
  const toolbar = document.getElementById("pendingBulkToolbar");
  const count = document.getElementById("pendingBulkCount");
  if (!toolbar || !count) return;
  const n = selectedPendingDirectory.size;
  toolbar.style.display = n > 0 ? "flex" : "none";
  count.textContent = `${n} selected`;
}
async function deletePendingDirectoryBulkClick(){
  const alamanahNos = Array.from(selectedPendingDirectory);
  if (!alamanahNos.length) return;
  if (!window.confirm(`Remove ${alamanahNos.length} pending ${alamanahNos.length === 1 ? "entry" : "entries"} (${alamanahNos.slice(0,5).join(", ")}${alamanahNos.length > 5 ? ", …" : ""})? They will no longer be able to register with these details. This cannot be undone.`)) return;
  try{
    await deletePendingDirectoryMembersBulk(alamanahNos);
    toast(`Removed ${alamanahNos.length} pending ${alamanahNos.length === 1 ? "entry" : "entries"}.`);
    renderPendingDirectory();
  }catch(err){ toast(err.message || "Could not remove selected entries.", "error"); }
}

/* ---------- SMS notification log + manual channel resend ---------- */
async function renderSmsLog(){
  const box = document.getElementById("smsLogBody");
  if (!box) return;
  try{
    const rows = await getRecentSmsLog();
    if (!rows.length){ box.innerHTML = `<tr class="empty-row"><td colspan="6">No SMS attempts recorded yet.</td></tr>`; return; }
    box.innerHTML = rows.map(r => {
      const sentAt = r.created_at ? new Date(r.created_at).toLocaleString() : "—";
      const channel = r.termii_channel || "—";
      const statusBadge = r.success
        ? `<span class="pill pill-ok">Queued (${channel})</span>`
        : `<span class="pill pill-bad">Failed</span>`;
      const msgPreview = (r.body || "").length > 60 ? r.body.slice(0, 60) + "…" : (r.body || "—");
      return `<tr>
        <td class="mono-cell" style="white-space:nowrap;">${sentAt}</td>
        <td class="mono-cell">${r.recipient || "—"}</td>
        <td class="mono-cell">${channel}</td>
        <td>${statusBadge}</td>
        <td title="${(r.body || "").replace(/"/g, '&quot;')}">${msgPreview}</td>
        <td><button class="btn btn-outline btn-sm" onclick="resendSmsAlternateChannelClick('${r.id}', '${channel}')">Resend on other channel</button></td>
      </tr>`;
    }).join("");
  }catch(err){ box.innerHTML = `<tr class="empty-row"><td colspan="6">${err.message || "Could not load SMS log."}</td></tr>`; }
}
async function resendSmsAlternateChannelClick(logId, currentChannel){
  const altChannel = currentChannel === "dnd" ? "generic" : "dnd";
  if (!window.confirm(`Resend this message via the ${altChannel} channel?`)) return;
  try{
    await resendSmsAlternateChannel(logId);
    toast(`Resend via ${altChannel} queued.`);
    renderSmsLog();
  }catch(err){ toast(err.message || "Could not resend message.", "error"); }
}
