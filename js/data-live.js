/* =========================================================
   AL-AMANAH CO-OPERATIVE — LIVE DATA LAYER
   Talks to the real Supabase database. Loaded by
   login.html, setup-password.html, dashboard.html,
   apply-loan.html and admin.html (after supabaseClient.js).
   ========================================================= */

const LOAN_TYPES = {
  real: {
    label: "Real Loan",
    mode: "multiplier",          // eligible amount = savings × multiplier
    multiplier: 3,
    duration: 24,                 // fixed term, months
    feeRate: 0,                   // no separate loan fee — covered by the monthly 7.5% admin charge on savings
    feeLabel: null,
    desc: "Up to 3× your savings balance, repayable over a fixed 24 months."
  },
  commodity: {
    label: "Commodity Loan",
    mode: "fixed",                 // eligible amount = flat cap, regardless of savings
    maxAmount: 500000,
    duration: 12,
    feeRate: 0.10,                 // 10% commodity charge added to the loan obligation
    feeLabel: "Commodity loan charge (10%)",
    desc: "Flat maximum of ₦500,000, plus a 10% commodity loan charge, repayable over a fixed 12 months."
  },
  humanitarian: {
    label: "Humanitarian Loan",
    mode: "fixed",
    maxAmount: 100000,
    duration: 8,
    feeRate: 0,
    feeLabel: null,
    desc: "Flat maximum of ₦100,000 for urgent medical, education or bereavement needs, over 8 months."
  }
};

const ADMIN_SAVINGS_CHARGE_RATE = 0.075; // 7.5% deducted from each monthly savings contribution

function loanEligibleAmount(type, savingsBalance) {
  const t = LOAN_TYPES[type];
  return t.mode === "multiplier" ? Math.floor(savingsBalance * t.multiplier) : t.maxAmount;
}

function formatNaira(n) {
  const val = Number(n) || 0;
  return "₦" + val.toLocaleString("en-NG", { maximumFractionDigits: 0 });
}
function formatDate(d) {
  if (!d) return "—";
  return new Date(d).toLocaleDateString("en-GB", { day: "2-digit", month: "short", year: "numeric" });
}
function uid(prefix) {
  return prefix + "-" + Math.floor(1000 + Math.random() * 9000) + Date.now().toString().slice(-4);
}

/* ---------- performance: debounce ----------
   Realtime table subscriptions fire once per row change. A bulk
   upload or a busy few seconds can trigger a burst of events —
   without this, each one independently re-queries the database and
   redraws the whole page, so the site visibly stalls. debounce()
   collapses a burst into a single call, made shortly after the last
   event in the burst, and skips starting a new run while a previous
   run from the same wrapped function is still in flight. */
function debounce(fn, wait) {
  let timer = null;
  let running = false;
  let pending = false;
  const run = async () => {
    if (running) { pending = true; return; }
    running = true;
    try { await fn(); } finally {
      running = false;
      if (pending) { pending = false; run(); }
    }
  };
  return function debounced() {
    clearTimeout(timer);
    timer = setTimeout(run, wait);
  };
}

/* ---------- savings review cycle: fixed, calendar-wide half-year
   windows shared by every member — 5 Jan to 30 Jun, and 5 Jul to
   31 Dec. Not tied to any individual member's own dates; driven
   purely by today's date (or an optional reference date, mainly
   for testing). ---------- */
// Returns the Date the NEXT review cycle begins.
function nextSavingsReviewDate(refDateStr) {
  const ref = refDateStr ? new Date(refDateStr) : new Date();
  const year = ref.getFullYear();
  const h1Start = new Date(year, 0, 5);   // 5 Jan
  const h1End = new Date(year, 5, 30);    // 30 Jun
  const h2Start = new Date(year, 6, 5);   // 5 Jul
  const h2End = new Date(year, 11, 31);   // 31 Dec

  if (ref < h1Start) return h1Start;                   // 1-4 Jan: H1 is about to begin
  if (ref <= h1End) return h2Start;                     // in H1: next cycle is H2
  if (ref < h2Start) return h2Start;                    // 1-4 Jul: H2 is about to begin
  if (ref <= h2End) return new Date(year + 1, 0, 5);    // in H2: next cycle is next year's H1
  return new Date(year + 1, 0, 5);
}
// Human label for the half-year cycle a given date falls in, e.g.
// "5 Jan - 30 Jun 2026".
function savingsReviewPeriodLabel(dateObj) {
  const d = dateObj instanceof Date ? dateObj : new Date(dateObj);
  const year = d.getFullYear();
  const h1Start = new Date(year, 0, 5);
  const h1End = new Date(year, 5, 30);
  const h2Start = new Date(year, 6, 5);
  if (d < h1Start) return `5 Jan - 30 Jun ${year} (begins 5 Jan)`;
  if (d <= h1End) return `5 Jan - 30 Jun ${year}`;
  if (d < h2Start) return `5 Jul - 31 Dec ${year} (begins 5 Jul)`;
  return `5 Jul - 31 Dec ${year}`;
}

/* ---------- auth ---------- */
async function memberSignUp(alamanahNo, surname, password) {
  // Prefer the real email on file (if the admin entered one when
  // adding this member) so "Forgot password" can actually reach
  // them later — the generated placeholder domain below doesn't
  // exist and can never receive mail. Falls back to the generated
  // email if no real one was provided, same as before.
  let email = alamanahToEmail(alamanahNo);
  try {
    const { data: directoryEmail, error: lookupError } = await supabaseClient.rpc("contact_email_for_pending_member", { p_alamanah_no: alamanahNo, p_surname: surname });
    if (!lookupError && directoryEmail) email = directoryEmail;
  } catch (e) { /* fall back silently to the generated email above */ }

  const { data, error } = await supabaseClient.auth.signUp({
    email,
    password,
    options: { data: { alamanah_no: alamanahNo.trim(), surname: surname.trim() } }
  });
  if (error) throw error;
  return data;
}

async function memberLogin(alamanahNo, password) {
  // Don't just assume the generated placeholder email format — a
  // member who was previously an officer signs in with whatever real
  // email was set for them via "Set Sign-in Email", not the
  // generated one. Look up whichever email is ACTUALLY on file for
  // this Al-Amanah No. first, and only fall back to the generated
  // format if that lookup fails for any reason (e.g. migration not
  // yet run), so this never breaks the common case.
  let email = alamanahToEmail(alamanahNo);
  try {
    const { data: resolvedEmail, error: lookupError } = await supabaseClient.rpc("email_for_alamanah_no", { p_alamanah_no: alamanahNo });
    if (!lookupError && resolvedEmail) email = resolvedEmail;
  } catch (e) { /* fall back silently to the generated email above */ }

  const { data, error } = await supabaseClient.auth.signInWithPassword({ email, password });
  if (error) throw error;
  return data;
}

// A synthetic placeholder email means no real email was ever set for
// this account — Supabase can generate a reset link, but it can
// never actually be delivered anywhere real. Used to give the member
// an honest message instead of a false "check your email".
function isPlaceholderEmail(email) {
  return !email || /@members\.alamanahmcs\.local$/i.test(email);
}

async function requestMemberPasswordReset(alamanahNo) {
  const { data: email, error } = await supabaseClient.rpc("email_for_alamanah_no", { p_alamanah_no: alamanahNo });
  if (error) throw error;
  if (isPlaceholderEmail(email)) {
    throw new Error("No email is on file for this Al-Amanah number yet, so we can't send a reset link. Contact the society office — an admin can add your email or reset your password for you.");
  }
  const redirectTo = new URL("reset-password.html", window.location.href).href;
  const { error: resetError } = await supabaseClient.auth.resetPasswordForEmail(email, { redirectTo });
  if (resetError) throw resetError;
}

async function adminLogin(email, password) {
  const { data, error } = await supabaseClient.auth.signInWithPassword({ email, password });
  if (error) throw error;
  const profile = await getMyProfile();
  if (!profile || !profile.is_admin) {
    await supabaseClient.auth.signOut();
    throw new Error("This account does not have admin access.");
  }
  return profile;
}

// Same pattern as adminLogin, for the three officer roles
// (treasurer / president / secretary). role must match the
// profile's `role` column exactly or the sign-in is rejected.
async function officerLogin(email, password, role) {
  const { data, error } = await supabaseClient.auth.signInWithPassword({ email, password });
  if (error) throw error;
  const profile = await getMyProfile();
  if (!profile || profile.role !== role) {
    await supabaseClient.auth.signOut();
    throw new Error("This account does not have " + role + " access.");
  }
  return profile;
}

async function logoutUser() {
  sessionStorage.removeItem("viewAsMember"); // don't carry this into the next session
  await supabaseClient.auth.signOut();
}

// ---------------------------------------------------------
// Officer workflow helpers (Treasurer / President / Secretary)
// ---------------------------------------------------------

// Fetches loans sitting at one or more workflow stages, joined
// with the applicant's profile so the queue can show a name.
async function getOfficerQueue(workflowStatuses) {
  const { data, error } = await supabaseClient
    .from("loans")
    .select("*, profiles(alamanah_no, surname, first_name, department)")
    .in("workflow_status", workflowStatuses)
    .order("date_applied", { ascending: true });
  if (error) throw error;
  return data || [];
}

// Read-only preview of a member's financial position for one loan
// application — safe to call before deciding anything.
async function getLoanFinancialSummary(loanId) {
  const { data, error } = await supabaseClient.rpc("get_loan_financial_summary", { p_loan_id: loanId });
  if (error) throw error;
  return data;
}

async function submitTreasurerAssessment(loanId, eligibilityStatus, recommendation, note) {
  const { error } = await supabaseClient.rpc("submit_treasurer_assessment", {
    p_loan_id: loanId,
    p_eligibility_status: eligibilityStatus,
    p_recommendation: recommendation,
    p_assessment_note: note
  });
  if (error) throw error;
}

async function submitPresidentDecision(loanId, decision, note, returnedReason) {
  const { error } = await supabaseClient.rpc("submit_president_decision", {
    p_loan_id: loanId,
    p_decision: decision,
    p_decision_note: note || null,
    p_returned_reason: returnedReason || null
  });
  if (error) throw error;
}

// The Treasurer's assessment for one loan (needed on the
// President's decision screen to show what was recommended).
async function getAssessmentForLoan(loanId) {
  const { data, error } = await supabaseClient
    .from("loan_assessments")
    .select("*")
    .eq("loan_id", loanId)
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();
  if (error) throw error;
  return data;
}

// ---------------------------------------------------------
// Bursary Officer workflow helpers — vets a loan applicant's
// financial capacity (1/3 of Gross Pay / Net Pay rule) before the
// application reaches the Treasurer. See
// supabase/migration_bursary_officer_role.sql.
// ---------------------------------------------------------
async function getBursaryFinancialSummary(loanId) {
  const { data, error } = await supabaseClient.rpc("get_bursary_financial_summary", { p_loan_id: loanId });
  if (error) throw error;
  return data;
}

async function submitBursaryVetting(loanId, eligibilityStatus, note, grossPay, otherMonthlyDeductions) {
  const { error } = await supabaseClient.rpc("submit_bursary_vetting", {
    p_loan_id: loanId,
    p_eligibility_status: eligibilityStatus,
    p_note: note,
    p_gross_pay: grossPay ?? null,
    p_other_monthly_deductions: otherMonthlyDeductions ?? null
  });
  if (error) throw error;
}

async function setMemberSalary(memberId, grossPay, otherMonthlyDeductions) {
  const { error } = await supabaseClient.rpc("set_member_salary", { p_member_id: memberId, p_gross_pay: grossPay, p_other_monthly_deductions: otherMonthlyDeductions });
  if (error) throw error;
}

// The Bursary Officer's vetting for one loan (shown on the
// Treasurer's assessment screen so they see the salary-limit check
// that already happened before the application reached them).
async function getVettingForLoan(loanId) {
  const { data, error } = await supabaseClient
    .from("loan_vettings")
    .select("*")
    .eq("loan_id", loanId)
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();
  if (error) throw error;
  return data;
}

// ---------------------------------------------------------
// Loan offset payment (Paystack)
// ---------------------------------------------------------
async function createOffsetRequest(loanIds, paymentMethod) {
  const { data, error } = await supabaseClient.rpc("create_offset_request", {
    p_loan_ids: loanIds,
    p_payment_method: paymentMethod || "paystack"
  });
  if (error) throw error;
  return data; // { offset_request_id, request_reference, total_amount }
}

async function initializeOffsetPayment(offsetRequestId, memberEmail) {
  const { data, error } = await supabaseClient.functions.invoke("initialize-offset-payment", {
    body: { offset_request_id: offsetRequestId, member_email: memberEmail }
  });
  if (error) {
    // supabase-js only gives a generic message here ("Edge Function
    // returned a non-2xx status code") — the real reason is inside
    // the actual response body, which we have to read separately.
    let detail = error.message;
    try {
      if (error.context && typeof error.context.json === "function") {
        const body = await error.context.json();
        if (body?.error) detail = body.error;
      }
    } catch (_) { /* fall back to the generic message below */ }
    throw new Error(detail);
  }
  if (data?.error) throw new Error(data.error);
  return data;
}

async function verifyOffsetPayment(reference) {
  const { data, error } = await supabaseClient.functions.invoke("verify-offset-payment", {
    body: { reference }
  });
  if (error) throw error;
  return data; // { status, message }
}

async function getMyOffsetRequests() {
  const { data, error } = await supabaseClient
    .from("loan_offset_requests")
    .select("*, loan_offset_request_items(*)")
    .order("created_at", { ascending: false });
  if (error) throw error;
  return data || [];
}

async function confirmManualOffsetPayment(offsetRequestId, note) {
  const { error } = await supabaseClient.rpc("confirm_manual_offset_payment", {
    p_offset_request_id: offsetRequestId,
    p_confirmation_note: note
  });
  if (error) throw error;
}

async function getPendingManualOffsetRequests() {
  const { data, error } = await supabaseClient
    .from("loan_offset_requests")
    // Disambiguated with !member_id — loan_offset_requests has TWO
    // foreign keys into profiles (member_id = who requested it,
    // confirmed_by = which officer confirmed it), so PostgREST can't
    // guess which one "profiles(...)" should mean without this hint.
    .select("*, profiles!member_id(alamanah_no, surname, first_name), loan_offset_request_items(*)")
    .eq("payment_method", "manual")
    .eq("payment_status", "pending")
    .order("created_at", { ascending: true });
  if (error) throw error;
  return data || [];
}

// ---------------------------------------------------------
// Problem reporting (Step 13) — used by all three officer
// portals and by the Super Admin's issue-management view.
// ---------------------------------------------------------
async function reportManagementIssue(title, description, severity, relatedLoanId, relatedMemberId) {
  const { error } = await supabaseClient.rpc("report_management_issue", {
    p_title: title,
    p_description: description,
    p_related_member_id: relatedMemberId || null,
    p_related_loan_id: relatedLoanId || null,
    p_severity: severity || "normal"
  });
  if (error) throw error;
}

async function getMyReportedIssues() {
  const { data, error } = await supabaseClient
    .from("management_issues")
    .select("*")
    .order("created_at", { ascending: false });
  if (error) throw error;
  return data || [];
}

async function getAllManagementIssues() {
  const { data, error } = await supabaseClient
    .from("management_issues")
    .select("*")
    .order("created_at", { ascending: false });
  if (error) throw error;
  return data || [];
}

async function resolveManagementIssue(issueId, status, resolutionNote) {
  const { error } = await supabaseClient.rpc("resolve_management_issue", {
    p_issue_id: issueId,
    p_status: status,
    p_resolution_note: resolutionNote || null
  });
  if (error) throw error;
}

async function setProfileRole(profileId, role) {
  const { error } = await supabaseClient.rpc("admin_set_role", { p_profile_id: profileId, p_role: role });
  if (error) throw error;
}

// Lets a Super Admin give an existing profile (already promoted via
// setProfileRole above) a real sign-in email, so the officer can log
// in at their portal with an address they actually know — instead of
// the generated placeholder email their member account was created
// with. See migration_set_officer_email.sql.
async function setProfileEmail(profileId, email) {
  const { error } = await supabaseClient.rpc("admin_set_profile_email", { p_profile_id: profileId, p_new_email: email });
  if (error) throw error;
}

// Corrects a profile's Al-Amanah No. — for fixing officer profiles
// set up under the old placeholder pattern (TREAS-001, ADMIN-001…)
// so they show, and can later log back in as a member with, their
// real Al-Amanah No. See migration_fix_officer_alamanah_no.sql.
async function updateProfileAlamanahNo(profileId, newAlamanahNo) {
  const { error } = await supabaseClient.rpc("admin_update_alamanah_no", { p_profile_id: profileId, p_new_alamanah_no: newAlamanahNo });
  if (error) throw error;
}

// Corrects a member's name/department/phone — for fixing details
// left blank or entered incorrectly at registration (e.g. Create New
// Member treats email as optional, so it's easy to miss). Email is
// handled separately by setProfileEmail() since it also has to
// update the underlying Supabase Auth account.
// See migration_member_details_and_password_reset.sql.
async function updateMemberDetails(profileId, firstName, surname, department, phone) {
  const { error } = await supabaseClient.rpc("admin_update_member_details", {
    p_profile_id: profileId, p_first_name: firstName, p_surname: surname, p_department: department, p_phone: phone
  });
  if (error) throw error;
}

// Super Admin's "Management Team" overview: counts of what's
// pending at each stage, plus a merged recent-activity feed across
// Treasurer assessments, President decisions, and Secretary records.
// Recent automatic monthly-processing runs (savings + loan
// deductions), for the admin dashboard's review/notification
// banner. See supabase/migration_auto_monthly_processing.sql.
// "Undo This Month" — reverses a member's most recent savings
// contribution, or a loan's most recent monthly deduction, but
// only if it happened in the current calendar month. See
// supabase/migration_undo_this_month.sql.
async function undoSavingsContribution(memberId, reason) {
  const { error } = await supabaseClient.rpc("admin_undo_savings_contribution", { p_member_id: memberId, p_reason: reason });
  if (error) throw error;
}
async function undoLoanDeduction(loanId, reason) {
  const { error } = await supabaseClient.rpc("admin_undo_loan_deduction", { p_loan_id: loanId, p_reason: reason });
  if (error) throw error;
}

async function getRecentAutoRuns(limit = 12) {
  const { data, error } = await supabaseClient
    .from("auto_processing_runs")
    .select("*")
    .order("run_date", { ascending: false })
    .limit(limit);
  if (error) throw error;
  return data || [];
}

async function getManagementOverview() {
  const [loansRes, vettingsRes, assessmentsRes, decisionsRes, recordsRes] = await Promise.all([
    supabaseClient.from("loans").select("id, workflow_status"),
    supabaseClient.from("loan_vettings").select("*, loans(id, profiles(alamanah_no, surname, first_name))").order("created_at", { ascending: false }).limit(10),
    supabaseClient.from("loan_assessments").select("*, loans(id, profiles(alamanah_no, surname, first_name))").order("created_at", { ascending: false }).limit(10),
    supabaseClient.from("loan_decisions").select("*, loans(id, profiles(alamanah_no, surname, first_name))").order("created_at", { ascending: false }).limit(10),
    supabaseClient.from("official_records").select("*")
  ]);
  if (loansRes.error) throw loansRes.error;
  if (vettingsRes.error) throw vettingsRes.error;
  if (assessmentsRes.error) throw assessmentsRes.error;
  if (decisionsRes.error) throw decisionsRes.error;
  if (recordsRes.error) throw recordsRes.error;

  const loans = loansRes.data || [];
  const vettings = vettingsRes.data || [];
  const assessments = assessmentsRes.data || [];
  const decisions = decisionsRes.data || [];
  const records = recordsRes.data || [];
  const todayStr = new Date().toISOString().slice(0, 10);

  const counts = {
    awaitingBursary: loans.filter(l => ["awaiting_bursary", "returned_to_bursary"].includes(l.workflow_status)).length,
    awaitingTreasurer: loans.filter(l => ["awaiting_treasurer", "returned_to_treasurer"].includes(l.workflow_status)).length,
    awaitingPresident: loans.filter(l => l.workflow_status === "awaiting_president").length,
    onHold: loans.filter(l => ["on_hold", "on_hold_bursary"].includes(l.workflow_status)).length,
    recordsPending: records.filter(r => r.documentation_status === "pending").length,
    vettingsToday: vettings.filter(v => v.created_at.slice(0, 10) === todayStr).length,
    assessmentsToday: assessments.filter(a => a.created_at.slice(0, 10) === todayStr).length,
    decisionsToday: decisions.filter(d => d.created_at.slice(0, 10) === todayStr).length
  };

  const feed = [
    ...vettings.map(v => ({
      created_at: v.created_at,
      text: `Bursary vetting (${v.eligibility_status.replace(/_/g, " ")}) — ${v.loans?.profiles ? v.loans.profiles.first_name + " " + v.loans.profiles.surname : v.loan_id}`
    })),
    ...assessments.map(a => ({
      created_at: a.created_at,
      text: `Treasurer assessment (${a.eligibility_status.replace(/_/g, " ")}) — ${a.loans?.profiles ? a.loans.profiles.first_name + " " + a.loans.profiles.surname : a.loan_id}`
    })),
    ...decisions.map(d => ({
      created_at: d.created_at,
      text: `President ${d.decision.replace(/_/g, " ")} — ${d.loans?.profiles ? d.loans.profiles.first_name + " " + d.loans.profiles.surname : d.loan_id}`
    })),
    ...records.map(r => ({
      created_at: r.created_at,
      text: `Secretary documented a record (${r.documentation_status})${r.reference_number ? " — ref " + r.reference_number : ""}`
    }))
  ].sort((a, b) => new Date(b.created_at) - new Date(a.created_at)).slice(0, 15);

  return { counts, feed };
}

async function getSessionUser() {
  // getSession() reads the already-verified session held in memory/
  // local storage — no network round trip. getUser() re-validates
  // with the Auth server every single call, which added a full
  // network round trip to every profile/loans/transactions fetch
  // (several times per render, on every 20s poll and every realtime
  // event site-wide). Real enforcement happens server-side via RLS
  // regardless of which of the two we use, so this is safe.
  const { data } = await supabaseClient.auth.getSession();
  return data?.session?.user || null;
}

/* ---------- member data ---------- */
async function getMyProfile() {
  const user = await getSessionUser();
  if (!user) return null;
  const { data, error } = await supabaseClient.from("profiles").select("*").eq("id", user.id).single();
  if (error) return null;
  return data;
}

async function getMyLoans() {
  const user = await getSessionUser();
  const { data, error } = await supabaseClient.from("loans").select("*").eq("member_id", user.id).order("created_at", { ascending: false });
  if (error) throw error;
  return data;
}

async function getMyTransactions() {
  const user = await getSessionUser();
  const { data, error } = await supabaseClient.from("transactions").select("*").eq("member_id", user.id).is("cleared_at", null).order("date", { ascending: false });
  if (error) throw error;
  return data;
}

function memberSummary(profile, loans) {
  const approvedLoans = loans.filter(l => l.status === "approved");
  const totalMonthlyLoan = approvedLoans.reduce((s, l) => s + (Number(l.monthly_deduction) || 0), 0);
  const totalMonthlyAdmin = approvedLoans.reduce((s, l) => s + (Number(l.admin_monthly_deduction) || 0), 0);
  const totalLoanBalance = approvedLoans.reduce((s, l) => s + (Number(l.balance) || 0), 0);
  const totalAdminBalance = approvedLoans.reduce((s, l) => s + (Number(l.admin_charge_balance) || 0), 0);
  // Total Loan Obligations: the full amount granted across active loans
  // (principal + admin/commodity charge), BEFORE any monthly deductions
  // are taken off. This figure never shrinks on its own — it only
  // changes when a new loan is approved or an existing one is reset.
  const totalOriginalObligation = approvedLoans.reduce((s, l) => s + (Number(l.amount) || 0) + (Number(l.admin_charge) || 0), 0);
  // Available Loan Balance: what's still left to pay across active
  // loans AFTER deductions made so far (principal balance + admin
  // charge balance still outstanding). This shrinks every time a
  // monthly deduction or an offset payment is processed.
  const availableLoanBalance = totalLoanBalance + totalAdminBalance;
  return { approvedLoans, totalMonthlyLoan, totalMonthlyAdmin, totalLoanBalance, totalAdminBalance, totalOriginalObligation, availableLoanBalance };
}

async function applyForLoan({ type, amount, purpose }) {
  const user = await getSessionUser();
  const t = LOAN_TYPES[type];
  const duration = t.duration;
  const adminCharge = Math.round(amount * t.feeRate);
  const { data: existing, error: existingError } = await supabaseClient
    .from("loans").select("id,status").eq("member_id", user.id).eq("type", type)
    .in("status", ["pending", "approved"]).limit(1);
  if (existingError) throw existingError;
  if (existing && existing.length) {
    throw new Error("You already have a pending or active application for this loan type. Complete or offset it before applying again.");
  }
  const totalObligation = amount + adminCharge;
  const { error } = await supabaseClient.from("loans").insert({
    id: uid("LN"),
    member_id: user.id,
    type, amount, purpose, duration,
    admin_charge: adminCharge,
    monthly_deduction: Math.round(totalObligation / duration),
    admin_monthly_deduction: 0
  });
  if (error) throw error;
}

/* ---------- admin data ---------- */
async function getAllMembers() {
  const { data, error } = await supabaseClient.from("profiles").select("*").order("created_at", { ascending: false });
  if (error) throw error;
  return data;
}

/* ---------- admin: add members to the allow-list directly (no edge function / email needed) ----------
   This mirrors exactly what supabase/seed_member_directory.sql does. Adding a row here does NOT create
   a login by itself — the member still has to visit setup-password.html and enter their Al-Amanah No.
   + surname to claim it and create their own password. Until they do that, they won't show up in
   "All Members" (that list reads from `profiles`, which only exists after claiming) but WILL show up
   in "Pending Registration" below the members table. */
async function createMemberDirectoryEntry(m) {
  const alamanah_no = normalizeAlamanahNo(m.alamanah_no);
  const first_name = (m.first_name || "").trim();
  const surname = (m.surname || "").trim();
  if (!alamanah_no || !first_name || !surname) throw new Error("Al-Amanah No., First Name and Surname are required.");
  const { error } = await supabaseClient.from("member_directory").insert({
    alamanah_no,
    first_name,
    surname,
    department: (m.department || "").trim() || null,
    phone: (m.phone || "").trim() || null,
    contact_email: (m.contact_email || "").trim() || null,
    savings_balance: Number(m.savings_balance) || 0,
    monthly_savings_amount: Number(m.monthly_savings_amount) || 0,
    total_admin_charges: Number(m.total_admin_charges) || 0
  });
  if (error) {
    if (error.code === "23505") throw new Error(`Al-Amanah No. "${alamanah_no}" already exists.`);
    throw error;
  }
}

async function bulkCreateMemberDirectoryEntries(rows) {
  const cleanRows = [];
  const errors = [];
  rows.forEach((r, i) => {
    const alamanah_no = normalizeAlamanahNo(r.alamanah_no);
    const first_name = (r.first_name || "").trim();
    const surname = (r.surname || "").trim();
    if (!alamanah_no || !first_name || !surname) {
      errors.push(`Row ${i + 2}: missing alamanah_no, first_name or surname — skipped.`);
      return;
    }
    cleanRows.push({
      alamanah_no, first_name, surname,
      department: (r.department || "").trim() || null,
      phone: (r.phone || "").trim() || null,
      contact_email: (r.email || "").trim() || null,
      savings_balance: Number(r.savings_balance) || 0,
      monthly_savings_amount: Number(r.monthly_savings_amount) || 0,
      total_admin_charges: Number(r.total_admin_charges) || 0
    });
  });
  if (!cleanRows.length) return { created: 0, failed: rows.length, errors };
  // Insert one at a time so one bad/duplicate row (e.g. an Al-Amanah No. already used)
  // doesn't block the rest of a genuinely bulk upload.
  let created = 0;
  for (const row of cleanRows) {
    const { error } = await supabaseClient.from("member_directory").insert(row);
    if (error) {
      errors.push(error.code === "23505" ? `${row.alamanah_no}: already exists — skipped.` : `${row.alamanah_no}: ${error.message}`);
    } else {
      created++;
    }
  }
  return { created, failed: rows.length - created, errors };
}

async function getPendingDirectoryMembers() {
  const { data, error } = await supabaseClient.from("member_directory").select("*").eq("claimed", false).order("created_at", { ascending: false });
  if (error) throw error;
  return data || [];
}

async function deletePendingDirectoryMember(alamanahNo) {
  const { error } = await supabaseClient.from("member_directory").delete().eq("alamanah_no", alamanahNo).eq("claimed", false);
  if (error) throw error;
}

// Permanently deletes a registered member's login and every record tied
// to them (loans, transactions, savings/admin-charge history, payslip
// overrides, and more) and frees their Al-Amanah No. for reuse. This is
// IRREVERSIBLE — unlike "Clear History" elsewhere, there is nothing to
// restore afterwards. See supabase/migration_expunge_member.sql.
async function expungeMemberAdmin(memberId, reason) {
  const { error } = await supabaseClient.rpc("admin_expunge_member", { p_member_id: memberId, p_reason: reason });
  if (error) throw error;
}

async function getAllLoans() {
  const { data, error } = await supabaseClient
    .from("loans")
    .select("*, profiles!loans_member_id_fkey(alamanah_no, first_name, surname)")
    .order("created_at", { ascending: false });
  if (error) throw error;
  return data;
}

async function recordSavingsContribution(memberId, grossAmount) {
  const { error } = await supabaseClient.rpc("record_savings_contribution", { p_member_id: memberId, p_gross_amount: grossAmount });
  if (error) throw error;
}

async function updateMemberReview(memberId) {
  const { error } = await supabaseClient.rpc("mark_savings_reviewed", { p_member_id: memberId });
  if (error) throw error;
}
async function updateMemberReviewBulk(memberIds) {
  const { error } = await supabaseClient.rpc("mark_savings_reviewed_bulk", { p_member_ids: memberIds });
  if (error) throw error;
}

async function updateMemberStatus(memberId, status) {
  const { error } = await supabaseClient.from("profiles").update({ status }).eq("id", memberId);
  if (error) throw error;
}

async function decideLoanAdmin(loanId, decision, reason) {
  const { error } = await supabaseClient.rpc("decide_loan", { p_loan_id: loanId, p_decision: decision, p_reason: reason || null });
  if (error) throw error;
}

/* ---------- admin: deduction management (only an admin can ever call these) ---------- */

// Loan repayment deductions
async function adminRecordLoanDeduction(loanId) {
  const { error } = await supabaseClient.rpc("admin_record_loan_deduction", { p_loan_id: loanId });
  if (error) throw error;
}
async function adminRecordLoanDeductionsBulk(loanIds) {
  const { data, error } = await supabaseClient.rpc("record_loan_deductions_bulk", { p_loan_ids: loanIds });
  if (error) throw error;
  return data; // [{loan_id, processed, message}]
}

// Savings contributions
async function adminRecordSavingsBulk(memberIds) {
  const { data, error } = await supabaseClient.rpc("record_savings_bulk", { p_member_ids: memberIds });
  if (error) throw error;
  return data; // [{member_id, processed, message}]
}
async function setMonthlySavingsAmount(memberId, amount) {
  const { error } = await supabaseClient.rpc("set_monthly_savings_amount", { p_member_id: memberId, p_amount: amount });
  if (error) throw error;
}

// Pause / resume savings
async function setSavingsPaused(memberId, paused) {
  const { error } = await supabaseClient.rpc("set_savings_paused", { p_member_id: memberId, p_paused: paused });
  if (error) throw error;
}
async function setSavingsPausedBulk(memberIds, paused) {
  const { error } = await supabaseClient.rpc("set_savings_paused_bulk", { p_member_ids: memberIds, p_paused: paused });
  if (error) throw error;
}

// Pause / resume loan deductions
async function setDeductionsPaused(memberId, paused) {
  const { error } = await supabaseClient.rpc("set_deductions_paused", { p_member_id: memberId, p_paused: paused });
  if (error) throw error;
}
async function setDeductionsPausedBulk(memberIds, paused) {
  const { error } = await supabaseClient.rpc("set_deductions_paused_bulk", { p_member_ids: memberIds, p_paused: paused });
  if (error) throw error;
}

async function getAllTransactionsAdmin() {
  const { data, error } = await supabaseClient.from("transactions").select("*").order("date", { ascending: true });
  if (error) throw error;
  return data || [];
}

// Manual savings edit (audited)
async function editMemberSavings(memberId, newAmount, reason) {
  const { error } = await supabaseClient.rpc("edit_member_savings", { p_member_id: memberId, p_new_amount: newAmount, p_reason: reason });
  if (error) throw error;
}

// Manual total admin charges correction (audited)
async function editMemberAdminCharges(memberId, newAmount, reason) {
  const { error } = await supabaseClient.rpc("edit_total_admin_charges", { p_member_id: memberId, p_new_amount: newAmount, p_reason: reason });
  if (error) throw error;
}


// Loan offset/reset (admin only)
async function offsetLoanAdmin(loanId, reason) {
  const { error } = await supabaseClient.rpc("offset_loan", { p_loan_id: loanId, p_reason: reason || null });
  if (error) throw error;
}
async function resetLoanAdmin(loanId, reason) {
  const { error } = await supabaseClient.rpc("reset_loan", { p_loan_id: loanId, p_reason: reason || null });
  if (error) throw error;
}
async function getMemberLoans(memberId) {
  const { data, error } = await supabaseClient.from("loans").select("*").eq("member_id", memberId).order("created_at", { ascending: false });
  if (error) throw error;
  return data;
}

/* ---------- Payslip overrides (admin-editable) ---------- */
// Returns the saved override for this member + month ("YYYY-MM"), or null
// if the admin hasn't edited that month's payslip.
async function getPayslipOverride(memberId, month) {
  const { data, error } = await supabaseClient.from("payslip_overrides")
    .select("*").eq("member_id", memberId).eq("month", month).maybeSingle();
  if (error) throw error;
  return data;
}
// options can be a boolean (legacy: includeCancelled) or an object:
//   { includeCancelled=false, includeCleared=false, onlyCleared=false }
// Cleared rows are excluded by default everywhere — they belong only in
// the admin's separate "Cleared/Archived Records" view (onlyCleared).
async function getMemberTransactions(memberId, options = {}) {
  const opts = typeof options === "boolean" ? { includeCancelled: options } : (options || {});
  const { includeCancelled = false, includeCleared = false, onlyCleared = false } = opts;
  let query = supabaseClient.from("transactions").select("*").eq("member_id", memberId);
  if (onlyCleared) query = query.not("cleared_at", "is", null);
  else if (!includeCleared) query = query.is("cleared_at", null);
  if (!includeCancelled) query = query.is("cancelled_at", null);
  const { data, error } = await query.order("date", { ascending: false });
  if (error) throw error;
  return data || [];
}
async function getMemberClearedTransactions(memberId) {
  return getMemberTransactions(memberId, { onlyCleared: true, includeCancelled: true });
}
async function clearTransactionAdmin(transactionId, reason) {
  const { error } = await supabaseClient.rpc("admin_clear_transaction", { p_transaction_id: transactionId, p_reason: reason || null });
  if (error) throw error;
}
async function restoreTransactionAdmin(transactionId) {
  const { error } = await supabaseClient.rpc("admin_restore_transaction", { p_transaction_id: transactionId });
  if (error) throw error;
}
async function deleteTransactionPermanentlyAdmin(transactionId) {
  const { error } = await supabaseClient.rpc("admin_delete_transaction_permanently", { p_transaction_id: transactionId });
  if (error) throw error;
}
// Permanently delete ONE loan — only allowed once it's declined,
// offset, or completed (an active/pending loan can't be deleted this
// way). See supabase/migration_permanent_delete_loans.sql.
async function deleteLoanPermanentlyAdmin(loanId) {
  const { error } = await supabaseClient.rpc("admin_delete_loan_permanently", { p_loan_id: loanId });
  if (error) throw error;
}
// Permanently delete every eligible (declined/offset/completed) loan
// for a member in one call — backs "Delete All Permanently" on the
// Loans view. Still-active loans are left untouched.
async function deleteAllLoansPermanentlyAdmin(memberId) {
  const { data, error } = await supabaseClient.rpc("admin_delete_all_loans_permanently", { p_member_id: memberId });
  if (error) throw error;
  return data || []; // [{loan_id, processed, message}]
}
// Permanently delete every already-cleared transaction for a member
// in one call — backs "Delete All Permanently" on the Cleared/
// Archived Records table (the single-record version is
// deleteTransactionPermanentlyAdmin above).
async function deleteAllClearedTransactionsAdmin(memberId) {
  const { data, error } = await supabaseClient.rpc("admin_delete_all_cleared_transactions", { p_member_id: memberId });
  if (error) throw error;
  return data; // number deleted
}
// Fetch a member's Loan Offset History for the admin panel — the
// same table the member sees on their own dashboard (loans.html),
// read here via the "management reads all offset requests" RLS
// policy rather than a dedicated RPC.
async function getMemberOffsetHistoryAdmin(memberId) {
  const { data, error } = await supabaseClient
    .from("loan_offset_requests")
    .select("*, loan_offset_request_items(*)")
    .eq("member_id", memberId)
    .order("created_at", { ascending: false });
  if (error) throw error;
  return data || [];
}
// Permanently delete ONE offset-history request (and its line
// items). No status gate — a pending/in-progress request can be
// deleted too.
async function deleteOffsetRequestPermanentlyAdmin(requestId) {
  const { error } = await supabaseClient.rpc("admin_delete_offset_request_permanently", { p_request_id: requestId });
  if (error) throw error;
}
// Permanently delete every offset-history request for a member in
// one call — backs "Delete All Permanently" on the Loan Offset
// History section.
async function deleteAllOffsetRequestsPermanentlyAdmin(memberId) {
  const { data, error } = await supabaseClient.rpc("admin_delete_all_offset_requests_for_member", { p_member_id: memberId });
  if (error) throw error;
  return data; // number deleted
}
async function clearMemberHistoryAdmin(memberId, category, reason) {
  const { data, error } = await supabaseClient.rpc("admin_clear_member_history", { p_member_id: memberId, p_category: category, p_reason: reason || null });
  if (error) throw error;
  return data || [];
}
async function clearPayslipHistoryAdmin(memberId) {
  const { data, error } = await supabaseClient.rpc("admin_clear_payslip_history", { p_member_id: memberId });
  if (error) throw error;
  return data; // number of overrides removed
}
// loanRows: [{ label, amount }, ...]
async function savePayslipOverride(memberId, month, savings, adminCharge, loanRows, note) {
  const { error } = await supabaseClient.rpc("admin_save_payslip_override", {
    p_member_id: memberId, p_month: month, p_savings: savings, p_admin_charge: adminCharge,
    p_loan_rows: loanRows || [], p_note: note || null
  });
  if (error) throw error;
}
async function deletePayslipOverride(memberId, month) {
  const { error } = await supabaseClient.rpc("admin_delete_payslip_override", { p_member_id: memberId, p_month: month });
  if (error) throw error;
}

/* ---------- page guards ---------- */
async function requireMemberSession() {
  const profile = await getMyProfile();
  if (!profile) { window.location.href = "login.html"; return null; }
  return profile;
}
async function requireAdminSession() {
  const profile = await getMyProfile();
  if (!profile || !profile.is_admin) { window.location.href = "admin.html"; return null; }
  return profile;
}

/* ---------- realtime: push updates instantly instead of waiting on a poll ----------
   Each helper takes an optional `filter` (Postgres realtime filter
   string, e.g. "member_id=eq.<uuid>"). Member-facing pages pass their
   own member id so they only hear about their own rows instead of
   every member's row changing across the whole co-operative — that
   fan-out (every member's browser re-querying and redrawing on every
   other member's change) was the main cause of site-wide slowness.
   Admin/officer views legitimately need every row, so they omit the
   filter and get the unfiltered stream as before. */
function subscribeToLoansTable(onChange, filter) {
  const config = { event: "*", schema: "public", table: "loans" };
  if (filter) config.filter = filter;
  return supabaseClient
    .channel("loans-table-changes-" + Math.random().toString(36).slice(2))
    .on("postgres_changes", config, onChange)
    .subscribe();
}
function subscribeToTransactionsTable(onChange, filter) {
  const config = { event: "*", schema: "public", table: "transactions" };
  if (filter) config.filter = filter;
  return supabaseClient.channel("transactions-table-changes-" + Math.random().toString(36).slice(2))
    .on("postgres_changes", config, onChange).subscribe();
}
function subscribeToPayslipOverridesTable(onChange, filter) {
  const config = { event: "*", schema: "public", table: "payslip_overrides" };
  if (filter) config.filter = filter;
  return supabaseClient.channel("payslip-overrides-changes-" + Math.random().toString(36).slice(2))
    .on("postgres_changes", config, onChange).subscribe();
}
async function cancelTransactionAdmin(transactionId, reason) {
  const { error } = await supabaseClient.rpc("cancel_transaction", { p_transaction_id: transactionId, p_reason: reason || null });
  if (error) throw error;
}
// Cancel every still-active, cancellable (non-loan) transaction for one
// member in a single call — backs the "Cancel all" button.
async function cancelAllMemberTransactionsAdmin(memberId, reason) {
  const { data, error } = await supabaseClient.rpc("cancel_all_member_transactions", { p_member_id: memberId, p_reason: reason || null });
  if (error) throw error;
  return data || []; // [{transaction_id, processed, message}]
}
function subscribeToProfilesTable(onChange, filter) {
  const config = { event: "*", schema: "public", table: "profiles" };
  if (filter) config.filter = filter;
  return supabaseClient
    .channel("profiles-table-changes-" + Math.random().toString(36).slice(2))
    .on("postgres_changes", config, onChange)
    .subscribe();
}
