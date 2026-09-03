/* =========================================================
   Shared logic for the three officer placeholder portals:
   treasurer.html, president.html, secretary.html.

   Each of those pages sets one attribute so this one file can
   serve all three instead of writing near-identical script
   blocks three times:

     <body data-page-role="treasurer" data-officer-title="Treasurer">

   This is a PLACEHOLDER portal only. It proves the login/role
   check works end-to-end and gives each officer a real page to
   bookmark. The actual task queues (loan assessments, decisions,
   official records) are built in the next step, once the
   loan_assessments / loan_decisions / official_records tables
   exist — this file will grow to fetch and render that data
   without changing the login/guard logic below.
   ========================================================= */
function togglePw(id, btn) {
  const input = document.getElementById(id);
  const showing = input.type === "text";
  input.type = showing ? "password" : "text";
  btn.textContent = showing ? "Show" : "Hide";
}

function closeReportProblemModal() {
  document.getElementById("reportProblemModal").hidden = true;
}

document.addEventListener("DOMContentLoaded", async () => {
  const role = document.body.dataset.pageRole; // "treasurer" | "president" | "secretary"
  const title = document.body.dataset.officerTitle; // "Treasurer" | "President" | "Secretary"

  const profile = await (async () => { try { return await getMyProfile(); } catch (e) { return null; } })();
  if (profile && profile.role === role) showPanel(profile); else showLogin();

  document.getElementById("officerLoginForm").addEventListener("submit", async (e) => {
    e.preventDefault();
    const email = document.getElementById("officerUser").value.trim();
    const pass = document.getElementById("officerPass").value;
    const errBox = document.getElementById("officerLoginError");
    const btn = document.getElementById("officerLoginSubmit");
    errBox.classList.remove("show");
    btn.disabled = true; btn.textContent = "Logging in…";
    try {
      const p = await officerLogin(email, pass, role);
      showPanel(p);
      toast("Login successful.");
    } catch (err) {
      errBox.textContent = err.message || "Incorrect email or password.";
      errBox.classList.add("show");
    }
    btn.disabled = false; btn.textContent = "Log in to " + title.toLowerCase() + " portal";
  });

  document.getElementById("officerLogoutBtn").addEventListener("click", async () => {
    await logoutUser();
    showLogin();
    toast("Logged out successfully.");
  });

  const vamBtn = document.getElementById("officerViewAsMemberBtn");
  if (vamBtn) vamBtn.addEventListener("click", () => {
    sessionStorage.setItem("viewAsMember", "1");
    window.location.href = "dashboard.html";
  });

  // Step 13 — "Report Problem" is available on every officer
  // portal via the same shared modal markup (each HTML file
  // includes it once, with these same element IDs).
  const reportBtn = document.getElementById("reportProblemBtn");
  if (reportBtn) {
    reportBtn.addEventListener("click", () => {
      document.getElementById("reportProblemError").classList.remove("show");
      document.getElementById("reportProblemForm").reset();
      document.getElementById("reportProblemModal").hidden = false;
    });
  }
  const reportForm = document.getElementById("reportProblemForm");
  if (reportForm) {
    reportForm.addEventListener("submit", async (e) => {
      e.preventDefault();
      const t = document.getElementById("reportProblemTitle").value.trim();
      const d = document.getElementById("reportProblemDescription").value.trim();
      const sev = document.getElementById("reportProblemSeverity").value;
      const errBox = document.getElementById("reportProblemError");
      const btn = document.getElementById("reportProblemSubmitBtn");
      errBox.classList.remove("show");
      btn.disabled = true; btn.textContent = "Submitting…";
      try {
        await reportManagementIssue(t, d, sev);
        document.getElementById("reportProblemModal").hidden = true;
        toast("Problem reported to Super Admin.");
      } catch (err) {
        errBox.textContent = err.message || "Could not submit this report.";
        errBox.classList.add("show");
      }
      btn.disabled = false; btn.textContent = "Submit Report";
    });
  }

  function showLogin() {
    document.getElementById("officerSessionChecking").style.display = "none";
    document.getElementById("officerLoginShell").style.display = "";
    document.getElementById("officerPanel").style.display = "none";
    document.getElementById("officerLogoutBtn").style.display = "none";
    const vamBtn = document.getElementById("officerViewAsMemberBtn");
    if (vamBtn) vamBtn.style.display = "none";
    const rb = document.getElementById("reportProblemBtn");
    if (rb) rb.style.display = "none";
  }

  function showPanel(p) {
    document.getElementById("officerSessionChecking").style.display = "none";
    document.getElementById("officerLoginShell").style.display = "none";
    document.getElementById("officerPanel").style.display = "";
    document.getElementById("officerLogoutBtn").style.display = "";
    const vamBtn = document.getElementById("officerViewAsMemberBtn");
    if (vamBtn) vamBtn.style.display = "inline-flex";
    const rb = document.getElementById("reportProblemBtn");
    if (rb) rb.style.display = "";
    document.getElementById("officerWelcomeName").textContent = (p.first_name || "") + " " + (p.surname || "");
    // Landing on your own portal (through any path — not just the
    // "Return to Portal" banner button) means you're not currently
    // "viewing as member" anymore, so clear the flag. Otherwise it
    // can go stale: e.g. click View as Member, browse elsewhere via
    // the top nav instead of the banner button, come back later —
    // without this, the banner would reappear on dashboard.html even
    // though you never asked to view it that way this time.
    sessionStorage.removeItem("viewAsMember");
    // Page-specific scripts (treasurer.js, president.js, secretary.js)
    // define window.onOfficerReady to load and render their own
    // queue/content once we know who's logged in. Pages that don't
    // define it (none yet) just show the plain welcome panel.
    if (typeof window.onOfficerReady === "function") window.onOfficerReady(p);
  }
});
