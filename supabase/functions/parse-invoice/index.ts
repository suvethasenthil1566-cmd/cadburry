// Save as: supabase/functions/parse-invoice/index.ts
// Deploy:  supabase functions deploy parse-invoice --no-verify-jwt
//
// Simulates OCR on an uploaded PDF/PNG. Fields are derived from the file's SHA-256 hash,
// so uploading the SAME file twice produces the SAME invoice -> triggers duplicate detection.
// Optional form fields (vendor_name, amount, tax_rate, invoice_id) override the simulated values
// so you can force fraud scenarios live on stage.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const VENDORS = [
  "Acme Industrial Supplies",
  "Globex Logistics",
  "Initech Software",
  "Umbrella Chemicals",
  "Stark Components",
  "Wayne Consulting",
];
const TAX_RATES = [5, 12, 18, 18, 18, 28, 14]; // 14 is non-standard on purpose

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  try {
    const form = await req.formData();
    const file = form.get("file") as File | null;
    if (!file) return json({ error: "No file uploaded (field name: file)" }, 400);

    const ext = file.name.split(".").pop()?.toLowerCase();
    if (!["pdf", "png"].includes(ext ?? "")) {
      return json({ error: "Only PDF or PNG allowed" }, 400);
    }

    // hash the file bytes
    const buf = await file.arrayBuffer();
    const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", buf));
    const hex = Array.from(digest).map((b) => b.toString(16).padStart(2, "0")).join("");

    // simulated OCR (deterministic from hash)
    const simulated = {
      invoice_id: `INV-${(((digest[4] << 8) | digest[5]) % 90000 + 10000)}`,
      vendor_name: VENDORS[digest[0] % VENDORS.length],
      amount: Number((((digest[1] << 8) | digest[2]) % 90000 + 2500) + (digest[3] % 100) / 100),
      tax_rate: TAX_RATES[digest[6] % TAX_RATES.length],
    };

    // optional manual overrides for demos
    const o = (k: string) => (form.get(k) ? String(form.get(k)) : null);
    const invoice_id = o("invoice_id") ?? simulated.invoice_id;
    const vendor_name = o("vendor_name") ?? simulated.vendor_name;
    const amount = o("amount") ? Number(o("amount")) : simulated.amount;
    const tax_rate = o("tax_rate") ? Number(o("tax_rate")) : simulated.tax_rate;

    // fake "scanning" delay so the UI feels alive
    await new Promise((r) => setTimeout(r, 900));

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const { data, error } = await supabase.rpc("process_invoice", {
      p_invoice_id: invoice_id,
      p_vendor_name: vendor_name,
      p_amount: amount,
      p_tax_rate: tax_rate,
      p_file_name: file.name,
      p_file_hash: hex,
    });

    if (error) return json({ error: error.message }, 500);
    return json({ ok: true, result: data });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
