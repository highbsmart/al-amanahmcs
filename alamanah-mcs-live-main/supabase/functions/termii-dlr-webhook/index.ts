// Receives Termii's Delivery Report (DLR) webhook and records the REAL
// outcome of a previously-sent SMS — DELIVERED, DND Active on Phone
// Number, Message Failed, Rejected, or Expired — into notification_log.
//
// Configure this URL in Termii's dashboard: Settings -> Webhook
// (https://termii.com/account/webhook/config)
//
// Optional (recommended): set a TERMII_WEBHOOK_SECRET function secret
// matching the signing key Termii gives you, so this endpoint can
// verify the request really came from Termii (via the X-Termii-Signature
// header, HMAC-SHA512). If not set, verification is skipped — the
// function still works, just without that extra check.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const WEBHOOK_SECRET = Deno.env.get("TERMII_WEBHOOK_SECRET"); // optional

const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

function toHex(buffer: ArrayBuffer): string {
  return Array.from(new Uint8Array(buffer))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

async function verifySignature(rawBody: string, signature: string | null): Promise<boolean> {
  if (!WEBHOOK_SECRET) return true; // no secret configured yet — accept, but less secure
  if (!signature) return false;
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(WEBHOOK_SECRET),
    { name: "HMAC", hash: "SHA-512" },
    false,
    ["sign"]
  );
  const sigBuffer = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(rawBody));
  return toHex(sigBuffer).toLowerCase() === signature.toLowerCase();
}

// Same normalization used on the sending side, so a webhook's "receiver"
// (which Termii may return in a slightly different format) still matches
// what's stored in notification_log.recipient.
function normalizePhone(phone: string): string {
  let digits = (phone || "").replace(/[^0-9]/g, "");
  if (digits.startsWith("0")) digits = "234" + digits.slice(1);
  else if (!digits.startsWith("234")) digits = "234" + digits;
  return digits;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  const rawBody = await req.text();
  const signature = req.headers.get("x-termii-signature");

  if (!(await verifySignature(rawBody, signature))) {
    console.error("Termii webhook: signature verification failed.");
    return new Response("Invalid signature", { status: 401 });
  }

  let payload: Record<string, unknown>;
  try {
    payload = JSON.parse(rawBody);
  } catch {
    return new Response("Invalid JSON", { status: 400 });
  }

  // Device-offline pings and anything without the delivery-report shape
  // are outside what we track here — accept and ignore quietly so
  // Termii doesn't retry them as failures.
  if (!payload.receiver || !payload.status) {
    return new Response("OK (ignored)", { status: 200 });
  }

  const receiver = normalizePhone(String(payload.receiver));
  const status = String(payload.status);
  const messageId = payload.message_id ? String(payload.message_id) : null;
  const messageText = payload.message ? String(payload.message) : null;

  // Best-effort match back to the row we logged when the message was
  // sent: same phone number, same message text, not already resolved.
  // (We don't yet capture Termii's own message_id at send time — that
  // would need a separate reconciliation step against pg_net's async
  // response table — so text+phone is what ties the two together for now.)
  let query = supabase
    .from("notification_log")
    .select("id")
    .eq("channel", "sms")
    .eq("recipient", receiver)
    .is("delivery_status", null)
    .order("created_at", { ascending: false })
    .limit(1);

  if (messageText) {
    query = query.eq("body", messageText);
  }

  const { data: matches, error: findError } = await query;

  if (findError) {
    console.error("Termii webhook: lookup error", findError);
    return new Response("Lookup error", { status: 500 });
  }

  if (!matches || matches.length === 0) {
    console.warn("Termii webhook: no matching notification_log row for", receiver);
    return new Response("OK (no match)", { status: 200 });
  }

  const { error: updateError } = await supabase
    .from("notification_log")
    .update({
      delivery_status: status,
      delivered_at: new Date().toISOString(),
      termii_message_id: messageId,
    })
    .eq("id", matches[0].id);

  if (updateError) {
    console.error("Termii webhook: update error", updateError);
    return new Response("Update error", { status: 500 });
  }

  return new Response("OK", { status: 200 });
});
