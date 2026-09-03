let applicant = null;
let selectedType = null;

function renderTypePicker() {
  const picker = document.getElementById("typePicker");
  picker.innerHTML = Object.entries(LOAN_TYPES).map(([key, t]) => `
    <div class="type-option" data-type="${key}" onclick="selectType('${key}')">
      <h4>${t.label}</h4>
      <p>${t.desc}</p>
    </div>`).join("");
}

function selectType(key) {
  selectedType = key;
  document.querySelectorAll(".type-option").forEach(el => el.classList.toggle("selected", el.dataset.type === key));
  const t = LOAN_TYPES[key];
  const max = loanEligibleAmount(key, applicant.savings_balance);
  const capNote = t.mode === "multiplier"
    ? `3× your ${formatNaira(applicant.savings_balance)} savings`
    : `flat maximum for this loan type`;
  document.getElementById("amountHint").textContent = `Maximum eligible for ${t.label}: ${formatNaira(max)} (${capNote}).`;
  document.getElementById("amount").max = max;
  document.getElementById("amount").value = "";

  document.getElementById("durationField").style.display = "block";
  document.getElementById("durationDisplay").value = `${t.duration} months (fixed)`;

  updatePreview();
}

function updatePreview() {
  const errBox = document.getElementById("applyError");
  errBox.classList.remove("show");
  const amount = Number(document.getElementById("amount").value);
  const preview = document.getElementById("previewCard");
  if (!selectedType || !amount) { preview.style.display = "none"; return; }
  const t = LOAN_TYPES[selectedType];
  const duration = t.duration;
  const fee = Math.round(amount * t.feeRate);
  const totalRepayable = amount + fee;
  const monthly = Math.round(totalRepayable / duration);
  const feeMonthly = 0;

  const feeRow = document.getElementById("prevFeeRow");
  const adminMonthlyRow = document.getElementById("prevAdminMonthlyRow");
  if (t.feeRate > 0) {
    feeRow.style.display = "flex";
    adminMonthlyRow.style.display = "flex";
    document.getElementById("prevFeeLabel").textContent = t.feeLabel;
    document.getElementById("prevAdminCharge").textContent = formatNaira(fee);
    document.getElementById("prevAdminMonthly").textContent = "Included in total obligation";
  } else {
    feeRow.style.display = "none";
    adminMonthlyRow.style.display = "none";
  }

  document.getElementById("prevTotalRepayable").textContent = formatNaira(totalRepayable);
  document.getElementById("prevMonthly").textContent = formatNaira(monthly);
  document.getElementById("prevTotal").textContent = formatNaira(monthly + feeMonthly);
  preview.style.display = "block";
}

document.addEventListener("DOMContentLoaded", async () => {
  applicant = await requireMemberSession();
  if (!applicant) return;

  document.getElementById("eligibilityNote").innerHTML =
    `Your current savings balance is <strong>${formatNaira(applicant.savings_balance)}</strong>. Choose a loan type below to see your eligible amount.`;

  renderTypePicker();
  document.getElementById("amount").addEventListener("input", updatePreview);

  document.getElementById("logoutBtn").addEventListener("click", async () => { await logoutUser(); window.location.href = "index.html?loggedout=1"; });

  document.getElementById("loanForm").addEventListener("submit", async (e) => {
    e.preventDefault();
    const errBox = document.getElementById("applyError");
    const amount = Number(document.getElementById("amount").value);
    const purpose = document.getElementById("purpose").value.trim();
    const submitBtn = e.target.querySelector("button[type=submit]");

    if (!selectedType) { errBox.textContent = "Please select a loan type."; errBox.classList.add("show"); return; }
    const t = LOAN_TYPES[selectedType];
    const max = loanEligibleAmount(selectedType, applicant.savings_balance);
    if (!amount || amount <= 0) { errBox.textContent = "Please enter a valid loan amount."; errBox.classList.add("show"); return; }
    if (amount > max) { errBox.textContent = `Amount exceeds your eligible maximum of ${formatNaira(max)} for this loan type.`; errBox.classList.add("show"); return; }
    if (!purpose) { errBox.textContent = "Please state the purpose of this loan."; errBox.classList.add("show"); return; }

    submitBtn.disabled = true; submitBtn.textContent = "Submitting…";
    try {
      await applyForLoan({ type: selectedType, amount, purpose });
      window.location.href = "dashboard.html?applied=1";
    } catch (err) {
      errBox.textContent = err.message || "Could not submit application. Please try again.";
      errBox.classList.add("show");
      submitBtn.disabled = false; submitBtn.textContent = "Submit application for review";
    }
  });
});
