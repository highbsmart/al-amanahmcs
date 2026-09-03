/* =========================================================
   Secretary portal — real content (Step 10).
   Loaded only on secretary.html. Hooks into officer-portal.js
   via window.onOfficerReady, which fires once login succeeds.
   ========================================================= */
window.onOfficerReady = function () {
  loadSecretaryFeed();
  loadSecretaryHistory();
};

let currentRecordTarget = null; // { type, id, loanId }

async function loadSecretaryFeed() {
  const body = document.getElementById("secretaryFeedBody");
  body.innerHTML = `<tr class="empty-row"><td colspan="4">Loading…</td></tr>`;
  try {
    const [assessments, decisions, records] = await Promise.all([
      supabaseClient.from("loan_assessments").select("*, loans(id, type, amount, profiles(alamanah_no, surname, first_name))").order("created_at", { ascending: false }).limit(20),
      supabaseClient.from("loan_decisions").select("*, loans(id, type, amount, profiles(alamanah_no, surname, first_name))").order("created_at", { ascending: false }).limit(20),
      supabaseClient.from("official_records").select("*")
    ]);
    if (assessments.error) throw assessments.error;
    if (decisions.error) throw decisions.error;
    if (records.error) throw records.error;

    const documentedIds = new Set((records.data || []).map(r => r.related_entity_id));
    document.getElementById("secretaryPendingCount").textContent =
      (records.data || []).filter(r => r.documentation_status === "pending").length;

    const items = [
      ...(assessments.data || []).map(a => ({
        type: "loan_assessment", id: a.id, loanId: a.loan_id, created_at: a.created_at,
        member: a.loans?.profiles ? `${a.loans.profiles.first_name} ${a.loans.profiles.surname}` : a.loan_id,
        summary: `Treasurer assessment — ${labelEligibility(a.eligibility_status)}`
      })),
      ...(decisions.data || []).map(d => ({
        type: "loan_decision", id: d.id, loanId: d.loan_id, created_at: d.created_at,
        member: d.loans?.profiles ? `${d.loans.profiles.first_name} ${d.loans.profiles.surname}` : d.loan_id,
        summary: `President decision — ${capitalize(d.decision.replace(/_/g, " "))}`
      }))
    ].sort((a, b) => new Date(b.created_at) - new Date(a.created_at));

    if (!items.length) {
      body.innerHTML = `<tr class="empty-row"><td colspan="4">No management activity yet.</td></tr>`;
      return;
    }

    body.innerHTML = items.map(item => `
      <tr>
        <td>${new Date(item.created_at).toLocaleString()}</td>
        <td>${item.member}</td>
        <td>${item.summary}</td>
        <td>${
          documentedIds.has(item.id)
            ? `<span class="pill pill-ok">Documented</span>`
            : `<button class="btn btn-primary btn-sm" onclick="openRecordModal('${item.type}','${item.id}','${item.loanId}')">Document</button>`
        }</td>
      </tr>
    `).join("");
  } catch (err) {
    body.innerHTML = `<tr class="empty-row"><td colspan="4">Could not load activity: ${err.message}</td></tr>`;
  }
}

function labelEligibility(s) {
  return { eligible: "Eligible", not_eligible: "Not Eligible", needs_more_information: "Needs More Information", on_hold: "On Hold" }[s] || s;
}
function capitalize(s) { return s ? s.charAt(0).toUpperCase() + s.slice(1) : s; }

function openRecordModal(type, id, loanId) {
  currentRecordTarget = { type, id, loanId };
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
    const { data, error } = await supabaseClient
      .from("official_records")
      .select("*, loans(id, type, amount, profiles(alamanah_no, surname, first_name))")
      .eq("recorded_by", me.id)
      .order("created_at", { ascending: false })
      .limit(20);
    if (error) throw error;
    if (!data.length) {
      body.innerHTML = `<tr class="empty-row"><td colspan="5">You haven't created any official records yet.</td></tr>`;
      return;
    }
    body.innerHTML = data.map(r => `
      <tr>
        <td>${new Date(r.created_at).toLocaleString()}</td>
        <td>${r.loans?.profiles ? `${r.loans.profiles.first_name} ${r.loans.profiles.surname}` : r.loan_id}</td>
        <td>${r.reference_number || "—"}</td>
        <td>${r.documentation_status === "complete" ? `<span class="pill pill-ok">Complete</span>` : `<span class="pill pill-wait">Pending</span>`}</td>
        <td>${r.official_note}</td>
        <td>${
          r.documentation_status === "complete"
            ? `<span class="hint">—</span>`
            : `<button class="btn btn-outline btn-sm" onclick="handleMarkComplete('${r.id}')">Mark Complete</button>`
        }</td>
      </tr>
    `).join("");
  } catch (err) {
    body.innerHTML = `<tr class="empty-row"><td colspan="6">Could not load history: ${err.message}</td></tr>`;
  }
}

async function handleMarkComplete(recordId) {
  try {
    const { error } = await supabaseClient.rpc("mark_official_record_complete", { p_record_id: recordId });
    if (error) throw error;
    toast("Marked as complete.");
    loadSecretaryHistory();
  } catch (err) {
    toast(err.message || "Could not update this record.", "error");
  }
}

// Prints/downloads a PDF of every official record the Secretary
// has created, for the official cooperative decision register.
// Reuses the same jsPDF/autoTable pattern already used in
// js/reports.js — same library, same look.
async function downloadOfficialRecordsPdf() {
  try {
    const me = await getMyProfile();
    const { data, error } = await supabaseClient
      .from("official_records")
      .select("*, loans(id, type, amount, profiles(alamanah_no, surname, first_name))")
      .eq("recorded_by", me.id)
      .order("created_at", { ascending: false });
    if (error) throw error;

    const { jsPDF } = window.jspdf;
    const doc = new jsPDF({ orientation: "landscape" });
    doc.setFontSize(14); doc.text("Al-Amanah Multi-Purpose Co-operative Society", 14, 14);
    doc.setFontSize(11); doc.text("Official Records — Cooperative Decision Register", 14, 21);
    doc.setFontSize(9); doc.text(`Secretary: ${me.first_name} ${me.surname}    Printed: ${new Date().toLocaleString()}`, 14, 27);

    doc.autoTable({
      startY: 33,
      head: [["Date", "Member", "Al-Amanah No.", "Reference", "Meeting Ref.", "Status", "Note"]],
      body: (data || []).map(r => [
        new Date(r.created_at).toLocaleDateString(),
        r.loans?.profiles ? `${r.loans.profiles.first_name} ${r.loans.profiles.surname}` : r.loan_id,
        r.loans?.profiles?.alamanah_no || "—",
        r.reference_number || "—",
        r.meeting_reference || "—",
        r.documentation_status === "complete" ? "Complete" : "Pending",
        r.official_note
      ]),
      styles: { fontSize: 8 }
    });

    doc.save(`official-records_${me.surname}_${new Date().toISOString().slice(0, 10)}.pdf`);
  } catch (err) {
    toast(err.message || "Could not generate the PDF.", "error");
  }
}

document.addEventListener("DOMContentLoaded", () => {
  document.getElementById("recordForm").addEventListener("submit", async (e) => {
    e.preventDefault();
    const note = document.getElementById("recordNote").value.trim();
    const ref = document.getElementById("recordReference").value.trim();
    const meeting = document.getElementById("recordMeeting").value.trim();
    const errBox = document.getElementById("recordError");
    const btn = document.getElementById("recordSubmitBtn");
    errBox.classList.remove("show");

    btn.disabled = true; btn.textContent = "Saving…";
    try {
      const { error } = await supabaseClient.rpc("create_official_record", {
        p_related_entity_type: currentRecordTarget.type,
        p_related_entity_id: currentRecordTarget.id,
        p_loan_id: currentRecordTarget.loanId,
        p_official_note: note,
        p_reference_number: ref || null,
        p_meeting_reference: meeting || null
      });
      if (error) throw error;
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
