/* Shared UI behaviours across all pages */

function initNavToggle() {
  const btn = document.querySelector(".nav-toggle");
  const links = document.querySelector(".nav-links");
  if (!btn || !links) return;
  btn.addEventListener("click", () => links.classList.toggle("open"));
  links.querySelectorAll("a").forEach(a => a.addEventListener("click", () => links.classList.remove("open")));
}

function initReveal() {
  const items = document.querySelectorAll(".reveal");
  if (!items.length) return;
  const io = new IntersectionObserver((entries) => {
    entries.forEach(e => { if (e.isIntersecting) { e.target.classList.add("in"); io.unobserve(e.target); } });
  }, { threshold: 0.15 });
  items.forEach(i => io.observe(i));
}

function toast(msg, type = "ok") {
  let el = document.querySelector(".toast");
  if (!el) {
    el = document.createElement("div");
    el.className = "toast";
    document.body.appendChild(el);
  }
  el.textContent = msg;
  el.className = "toast" + (type === "error" ? " error" : "");
  requestAnimationFrame(() => el.classList.add("show"));
  clearTimeout(el._t);
  el._t = setTimeout(() => el.classList.remove("show"), 3400);
}

function markActiveNav() {
  const path = location.pathname.split("/").pop() || "index.html";
  document.querySelectorAll(".nav-links a").forEach(a => {
    if (a.getAttribute("href") === path) a.classList.add("active");
  });
}

function showAuthToasts() {
  const params = new URLSearchParams(location.search);
  const hadFlag = params.has("loggedout") || params.has("login");
  if (params.get("loggedout") === "1") toast("Logged out successfully.");
  if (params.get("login") === "1") toast("Login successful.");
  // Strip the flag from the address bar once shown, so refreshing
  // this exact URL later doesn't re-trigger the same toast forever.
  if (hadFlag) history.replaceState(null, "", location.pathname + location.hash);
}

/* ---------- Shared "Actions" dropdown menu ----------
   Used anywhere a row/card has several possible actions, so the UI
   shows one tidy "Actions ▾" button instead of a wall of buttons.
   Markup pattern:
     <div class="action-menu">
       <button class="btn btn-outline btn-sm" onclick="toggleActionMenu(this)">Actions &#9662;</button>
       <div class="action-menu-list" hidden>
         <button onclick="...">Do thing</button>
         <button class="danger" onclick="...">Dangerous thing</button>
       </div>
     </div>
*/
function closeAllActionMenus(exceptEl) {
  document.querySelectorAll(".action-menu-list").forEach(list => {
    if (list !== exceptEl) list.hidden = true;
  });
}
function toggleActionMenu(btn) {
  const list = btn.nextElementSibling;
  if (!list || !list.classList.contains("action-menu-list")) return;
  const willOpen = list.hidden;
  closeAllActionMenus();
  list.hidden = !willOpen;
  if (willOpen) {
    // Close this menu once any button inside it is clicked, since the
    // action itself usually re-renders the page anyway.
    list.querySelectorAll("button").forEach(b => b.addEventListener("click", () => { list.hidden = true; }, { once: true }));
  }
}
document.addEventListener("click", (e) => {
  if (!e.target.closest(".action-menu")) closeAllActionMenus();
});

/* ---------- Click outside a modal to cancel it ----------
   Clicking the dimmed backdrop behind any .modal-overlay acts the
   same as its × button — reuses that modal's own close function
   (via its .modal-close-x button) so any state it resets on close
   still gets reset, instead of just hiding the overlay directly. */
document.addEventListener("click", (e) => {
  if (e.target.classList && e.target.classList.contains("modal-overlay")) {
    const closeBtn = e.target.querySelector(".modal-close-x");
    if (closeBtn) closeBtn.click();
    else e.target.hidden = true;
  }
});

document.addEventListener("DOMContentLoaded", () => {
  initNavToggle();
  initReveal();
  markActiveNav();
  showAuthToasts();
});
