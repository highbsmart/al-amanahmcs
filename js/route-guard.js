/* =========================================================
   Central route guard — keeps Member, Officer, and Public
   areas properly separated.

   Every page that wants enforcement sets one attribute on its
   <body> tag:

     data-page-role="public"      index.html / about.html
                                   Open to everyone, signed in or
                                   not. A signed-in user (member,
                                   officer, or admin) is free to
                                   browse these pages and stays
                                   signed in — nav links just
                                   adjust to show their portal
                                   instead of "Login".

     data-page-role="auth"        login.html
                                   Same redirect if already
                                   signed in.

     data-page-role="member"      dashboard.html / profile.html /
                                   apply-loan.html
                                   No session -> login.html.
                                   Signed in as SUPER ADMIN or an
                                   OFFICER -> their own portal
                                   (an officer/admin account
                                   doesn't browse the member area
                                   as a member; that would need a
                                   deliberate "view as member"
                                   feature, which this file leaves
                                   room for via
                                   sessionStorage.viewAsMember but
                                   nothing in the UI sets today).

     data-page-role="admin"       admin.html
                                   Only a SUPER ADMIN may stay.
                                   Anyone else signed in (member or
                                   another officer) is sent to
                                   their own home page. No session
                                   at all just falls through to
                                   admin.html's own login form, as
                                   before.

     data-page-role="treasurer"   treasurer.html
     data-page-role="president"   president.html
     data-page-role="secretary"   secretary.html
     data-page-role="bursary"     bursary.html
                                   Same pattern as "admin" above,
                                   but for that specific officer
                                   role. Only a matching role may
                                   stay; everyone else (including
                                   Super Admin, for now) is sent to
                                   their own home page. No session
                                   at all lets the page show its
                                   own login form.

   Pages with no data-page-role (loan-info.html, setup-password.html)
   are intentionally left alone — loan-info.html is meant to be
   readable by anyone including logged-in members, and
   setup-password.html relies on a temporary Supabase session set up
   by the invite/reset link, which this guard must not redirect away.

   IMPORTANT: this is the client-side half of access control only.
   Hiding a link does not protect data — the real protection is the
   row-level security policies in supabase/schema.sql, which already
   scope every table to auth.uid() and public.is_admin(). This file
   just keeps people out of screens that don't apply to them and
   stops the UI offering navigation they shouldn't use.
   ========================================================= */
(function () {
  const OFFICER_HOME = { treasurer: "treasurer.html", president: "president.html", secretary: "secretary.html", bursary: "bursary.html" };

  // Where should this signed-in profile land? Mirrors the priority
  // that already existed (super admin beats everything), then adds
  // the three officer roles, then falls back to the member dashboard.
  function homeFor(profile) {
    if (profile.is_admin) return "admin.html";
    if (OFFICER_HOME[profile.role]) return OFFICER_HOME[profile.role];
    return "dashboard.html";
  }

  // Human-readable label for the banner below — "Super Admin",
  // "Treasurer", "President", "Secretary".
  function officerLabel(profile) {
    if (profile.is_admin) return "Super Admin";
    if (profile.role === "treasurer") return "Treasurer";
    if (profile.role === "president") return "President";
    if (profile.role === "secretary") return "Secretary";
    if (profile.role === "bursary") return "Bursary Officer";
    return "Management Committee";
  }

  // Shown at the very top of a member page when a signed-in officer
  // has deliberately switched here via "View as Member" — this is
  // their own membership account, being viewed the same way any
  // other member sees it. One click sends them back to their
  // officer/admin portal; leaving the tab or logging out does the
  // same, since the flag lives only in sessionStorage.
  function showViewAsMemberBanner(profile) {
    if (document.querySelector(".view-as-banner")) return; // already inserted
    const bar = document.createElement("div");
    bar.className = "view-as-banner";
    bar.innerHTML = `<span>You're viewing the member area as ${profile.first_name} ${profile.surname} — this is your own membership account, separate from your ${officerLabel(profile)} role.</span>`;
    const btn = document.createElement("button");
    btn.type = "button";
    btn.textContent = `Return to ${officerLabel(profile)} Portal`;
    btn.addEventListener("click", () => {
      sessionStorage.removeItem("viewAsMember");
      window.location.href = homeFor(profile);
    });
    bar.appendChild(btn);
    document.body.insertBefore(bar, document.body.firstChild);
  }

  async function enforceRouteAccess() {
    const role = document.body.dataset.pageRole;
    if (!role) return;

    let profile = null;
    try { profile = await getMyProfile(); } catch (err) { profile = null; }

    const viewAsMember = sessionStorage.getItem("viewAsMember") === "1";

    if (role === "auth") {
      // login.html: a signed-in user doesn't need the login form —
      // send them to their own portal.
      if (profile) { window.location.replace(homeFor(profile)); return; }
    } else if (role === "public") {
      // index.html / about.html: everyone may browse these freely,
      // signed in or not. No redirect — just adjust the nav below.
    } else if (role === "member") {
      if (!profile) { window.location.replace("login.html"); return; }
      if (!viewAsMember && (profile.is_admin || OFFICER_HOME[profile.role])) {
        window.location.replace(homeFor(profile)); return;
      }
      if (viewAsMember && (profile.is_admin || OFFICER_HOME[profile.role])) {
        showViewAsMemberBanner(profile);
      }
    } else if (role === "admin") {
      if (profile && !profile.is_admin) { window.location.replace(homeFor(profile)); return; }
      // no profile at all: let admin.html show its own login form
    } else if (role === "treasurer" || role === "president" || role === "secretary" || role === "bursary") {
      if (profile && profile.role !== role) { window.location.replace(homeFor(profile)); return; }
      // no profile at all: let this page show its own login form
    }

    applyNavVisibility(profile);
  }

  // Toggles nav links tagged with data-nav="..." to match who's
  // signed in. Values used across the site's pages:
  //   "home"        - the public Home link on member/officer portal
  //                   pages. Always shown — members and officers can
  //                   freely visit the homepage/public pages without
  //                   being signed out or bounced back.
  //   "guest-only"  - links only useful to someone signed out
  //                   (Admin / Member Login shortcuts on public pages)
  function applyNavVisibility(profile) {
    const signedIn = !!profile;
    document.querySelectorAll('[data-nav="guest-only"]').forEach(el => {
      el.style.display = signedIn ? "none" : "";
    });
    // "member-only": a "My Portal" link on public pages, shown only
    // once we know who's signed in, and pointed at their own home
    // page (dashboard / admin / officer portal as appropriate).
    document.querySelectorAll('[data-nav="member-only"]').forEach(el => {
      el.style.display = signedIn ? "" : "none";
      if (signedIn) el.setAttribute("href", homeFor(profile));
    });
  }

  document.addEventListener("DOMContentLoaded", enforceRouteAccess);
})();
