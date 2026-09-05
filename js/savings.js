async function renderSavingsPage() {
  const profile = await requireMemberSession();
  if (!profile) return;
  const myTx = await getMyTransactions();

  const monthlyCharge = Math.round((Number(profile.monthly_savings_amount) || 0) * ADMIN_SAVINGS_CHARGE_RATE);
  const nextReview = nextSavingsReviewDate();

  document.getElementById("savingsSubtext").textContent = `${profile.first_name} ${profile.surname} — ${profile.alamanah_no}`;
  document.getElementById("savingsSummary").innerHTML = `
    <div class="ledger-row"><span>Current savings balance</span><span><strong>${formatNaira(profile.savings_balance)}</strong></span></div>
    <div class="ledger-row"><span>Member since</span><span>${formatDate(profile.joined)}</span></div>
    <div class="ledger-row"><span>Monthly savings amount</span><span>${formatNaira(profile.monthly_savings_amount)}</span></div>
    <div class="ledger-row"><span>Last month savings</span><span>${profile.last_savings_date ? `${formatNaira(profile.last_savings_amount)} on ${formatDate(profile.last_savings_date)}` : "—"}</span></div>
    <div class="ledger-row"><span>Next month savings</span><span>${profile.next_savings_date ? `${formatNaira(profile.next_savings_amount)} due ${formatDate(profile.next_savings_date)}` : "—"}</span></div>
    <div class="ledger-row"><span>Monthly administrative charge (7.5%)</span><span>${monthlyCharge ? formatNaira(monthlyCharge) : "—"}</span></div>
    <div class="ledger-row"><span>Administrative charges (total)</span><span>${formatNaira(profile.total_admin_charges)}</span></div>
    <div class="ledger-row"><span>Next savings review</span><span>${formatDate(nextReview.toISOString().slice(0, 10))}</span></div>
    <div class="ledger-row"><span>Savings status</span><span>${profile.savings_paused ? '<span class="pill pill-wait">Paused</span>' : '<span class="pill pill-ok">Active</span>'}</span></div>
  `;

  const savingsTx = myTx.filter(t => t.type === "savings" || t.type === "admin_charge");
  const body = document.getElementById("savingsHistoryBody");
  body.innerHTML = savingsTx.length
    ? savingsTx.map(t => {
        const cancelled = !!t.cancelled_at;
        return `<tr style="opacity:${cancelled ? '.55' : '1'}">
        <td>${formatDate(t.date)}</td>
        <td>${t.description}${cancelled ? '<div style="font-size:11px;color:var(--ink-soft);">Cancelled by admin</div>' : ''}</td>
        <td style="text-transform:capitalize">${t.type.replace('_',' ')}</td>
        <td class="mono-cell" style="color:${t.amount < 0 ? 'var(--danger)' : 'var(--ok)'}">${t.amount < 0 ? "-" : "+"}${formatNaira(Math.abs(t.amount))}</td>
      </tr>`;
      }).join("")
    : '<tr class="empty-row"><td colspan="4">No savings activity recorded yet.</td></tr>';
}

document.addEventListener("DOMContentLoaded", async () => {
  renderSavingsPage();
  const logoutBtn = document.getElementById("logoutBtn");
  if (logoutBtn) logoutBtn.addEventListener("click", async () => { await logoutUser(); window.location.href = "index.html?loggedout=1"; });
  const refresh = debounce(renderSavingsPage, 400);
  const user = await getSessionUser();
  if (user) {
    subscribeToProfilesTable(refresh, `id=eq.${user.id}`);
    subscribeToTransactionsTable(refresh, `member_id=eq.${user.id}`);
  }
  setInterval(renderSavingsPage, 45000);
});
