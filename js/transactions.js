async function renderTransactionsPage() {
  const profile = await requireMemberSession();
  if (!profile) return;
  const myTx = await getMyTransactions();

  const body = document.getElementById("txTableBody");
  if (!myTx.length) {
    body.innerHTML = `<tr class="empty-row"><td colspan="4">No transactions yet.</td></tr>`;
    return;
  }
  body.innerHTML = myTx.map(t => {
    const cancelled = !!t.cancelled_at;
    return `
    <tr style="opacity:${cancelled ? '.55' : '1'}">
      <td>${formatDate(t.date)}</td>
      <td>${t.description}${cancelled ? '<div style="font-size:11px;color:var(--ink-soft);">Cancelled by admin</div>' : ''}</td>
      <td style="text-transform:capitalize">${t.type.replace('_',' ')}</td>
      <td class="mono-cell" style="color:${t.amount < 0 ? 'var(--danger)' : 'var(--ok)'}">${t.amount < 0 ? "-" : "+"}${formatNaira(Math.abs(t.amount))}</td>
    </tr>`;
  }).join("");
}

document.addEventListener("DOMContentLoaded", async () => {
  renderTransactionsPage();
  const logoutBtn = document.getElementById("logoutBtn");
  if (logoutBtn) logoutBtn.addEventListener("click", async () => { await logoutUser(); window.location.href = "index.html?loggedout=1"; });
  const refresh = debounce(renderTransactionsPage, 400);
  const user = await getSessionUser();
  if (user) subscribeToTransactionsTable(refresh, `member_id=eq.${user.id}`);
  setInterval(renderTransactionsPage, 45000);
});
