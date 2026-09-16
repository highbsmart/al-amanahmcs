/* =========================================================
   Supabase client setup.
   Fill in your project's URL and anon (public) key below —
   find both in Supabase Dashboard -> Project Settings -> API.
   The anon key is safe to expose in frontend code; it only
   works within the row-level-security rules defined in
   supabase/schema.sql.
   ========================================================= */
const SUPABASE_URL = "https://hrxyqrhpwbqdcrxbyakn.supabase.co";
const SUPABASE_ANON_KEY = "sb_publishable_lCYfOr0Ab3943Dhu7Yyt1g_KUSSSXVZ";

const supabaseClient = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

/* Turns an Al-Amanah number into the synthetic email Supabase
   Auth needs internally. Members never see or type this. */
function alamanahToEmail(alamanahNo) {
  const slug = alamanahNo.trim().toLowerCase().replace(/[^a-z0-9]/g, "");
  return `${slug}@members.alamanahmcs.local`;
}

/* Guarantees every Al-Amanah No. is stored the same way: "AL/" +
   whatever the admin typed, with any AL/ they DID type stripped
   first so we never end up with "AL/AL/302". Used everywhere a
   member number is created (single add + bulk CSV upload), so no
   member can ever be saved without the prefix again. */
function normalizeAlamanahNo(raw) {
  const cleaned = String(raw || "").trim().toUpperCase().replace(/^AL\/?/, "");
  if (!cleaned) return "";
  return `AL/${cleaned}`;
}
