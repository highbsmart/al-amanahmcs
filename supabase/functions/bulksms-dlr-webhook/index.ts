// Receives BulkSMSNigeria's delivery-status callback and records the
// real outcome into notification_log — the BulkSMSNigeria equivalent
// of the termii-dlr-webhook function.
//
// IMPORTANT: BulkSMSNigeria's exact callback field names aren't fully
// documented publicly at the time this was written — this handler is
// deliberately written to try several common field-name patterns
// (status/dlr_status/delivery_status, to/recipient/msisdn/phone,
// message/body/text). Once you can see a REAL sample payload from
// their dashboard (their docs area, or by triggering a test callback),
// send it over and this will be tightened up to match exactly.
//
// Configure this URL as the "callback_url" — either in your
// BulkSMSNigeria account dashboard as a default, or it's already
// passed automatically on every send via the bulksms_webhook_url
// app_setting (see send_bulksms_sms in the SQL migration).

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

function normalizePhone(phone: string): string {
  let digits = (phone || "").replace(/[^0-9]/g, "");
  if (digits.startsWith("0")) digits = "234" + digits.slice(1);
  else if (!digits.startsWith("234")) digits = "234" + digits;
  return digits;
}

// Tries several likely field names since the exact schema isn't
// confirmed yet — returns the first one that's actually present.
function firstDefined(obj: Record<string, unknown>, keys: string[]): unknown {
  for (const key of keys) {
    if (obj[key] !== undefined && obj[key] !== null && obj[key] !== "") return obj[key];
  }
  return undefined;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  let payload: Record<string, unknown>;
  try {
    const rawBody = await req.text();
    // BulkSMSNigeria (like many providers) may send either JSON or
    // form-encoded data — handle both.
    const contentType = req.headers.get("content-type") || "";
    if (contentType.includes("application/json")) {
      payload = JSON.parse(rawBody);
    } else {
      payload = Object.fromEntries(new URLSearchParams(rawBody));
    }
  } catch (err) {
    console.error("BulkSMS webhook: could not parse body", err);
    return new Response("Invalid body", { status: 400 });
  }

  console.log("BulkSMS webhook payload received:", JSON.stringify(payload));

  const rawReceiver = firstDefined(payload, ["to", "recipient", "msisdn", "phone", "number"]);
  const rawStatus = firstDefined(payload, ["status", "dlr_status", "delivery_status", "message_status"]);
  const rawMessageId = firstDefined(payload, ["message_id", "messageId", "id", "unique_id", "batch_id"]);
  const rawMessage = firstDefined(payload, ["body", "message", "text", "sms"]);

  if (!rawReceiver || !rawStatus) {
    // Log it so we can inspect the real shape later, but don't error —
    // an unrecognized payload shouldn't cause BulkSMSNigeria to retry
    // forever.
    console.warn("BulkSMS webhook: payload missing expected fields, logged for review only.");
    return new Response("OK (unrecognized shape, logged)", { status: 200 });
  }

  const receiver = normalizePhone(String(rawReceiver));
  const status = String(rawStatus);
  const messageId = rawMessageId ? String(rawMessageId) : null;
  const messageText = rawMessage ? String(rawMessage) : null;

  let query = supabase
    .from("notification_log")
    .select("id")
    .eq("channel", "sms")
    .eq("sms_provider", "bulksms")
    .eq("recipient", receiver)
    .is("delivery_status", null)
    .order("created_at", { ascending: false })
    .limit(1);

  if (messageText) {
    query = query.eq("body", messageText);
  }

  const { data: matches, error: findError } = await query;

  if (findError) {
    console.error("BulkSMS webhook: lookup error", findError);
    return new Response("Lookup error", { status: 500 });
  }

  if (!matches || matches.length === 0) {
    console.warn("BulkSMS webhook: no matching notification_log row for", receiver);
    return new Response("OK (no match)", { status: 200 });
  }

  const { error: updateError } = await supabase
    .from("notification_log")
    .update({
      delivery_status: status,
      delivered_at: new Date().toISOString(),
      termii_message_id: messageId, // shared column name, used by both providers
    })
    .eq("id", matches[0].id);

  if (updateError) {
    console.error("BulkSMS webhook: update error", updateError);
    return new Response("Update error", { status: 500 });
  }

  return new Response("OK", { status: 200 });
});
