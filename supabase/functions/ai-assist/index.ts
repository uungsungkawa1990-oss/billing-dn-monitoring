// ===========================================================================
// NexusNOC — Edge Function: ai-assist
//
// Tugas tunggal function ini: menerima context operasional (tiket + histori
// koneksi, atau daftar pelanggan) dari client yang SUDAH lolos RLS Supabase,
// mengirimkannya ke model AI, dan mengembalikan hasil terstruktur.
//
// API key model AI (ANTHROPIC_API_KEY) hidup sebagai secret di sini, TIDAK
// PERNAH dikirim ke browser — ini alasan modul AI Automation memakai Edge
// Function alih-alih memanggil API model AI langsung dari index.html.
//
// Function ini TIDAK menulis ke database. Client (dengan JWT user, tunduk
// pada RLS ai_insights) yang menyimpan hasilnya — sehingga audit trail
// "siapa meminta analisis apa, kapan" tetap konsisten dengan pola RLS
// generik per-site yang dipakai tabel lain di proyek ini.
//
// Deploy:
//   supabase functions deploy ai-assist
//   supabase secrets set ANTHROPIC_API_KEY=sk-ant-...
//   (opsional) supabase secrets set ANTHROPIC_MODEL=claude-sonnet-5
// ===========================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY");
const ANTHROPIC_MODEL = Deno.env.get("ANTHROPIC_MODEL") || "claude-sonnet-5";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

// Minta model membalas HANYA JSON valid dengan bentuk yang kita tentukan,
// supaya bisa langsung dirender di UI (kartu ringkasan, tabel skor risiko, dll).
const SCHEMAS: Record<string, string> = {
  ticket_diagnosis: `{
  "summary": string,               // 2-4 kalimat, bahasa Indonesia, untuk teknisi/CS non-teknis-AI
  "risk_score": number,            // 1-100, urgensi/severity gangguan ini
  "detail": {
    "probable_cause": string,      // dugaan penyebab paling mungkin berdasarkan data yang diberikan
    "suggested_steps": string[]    // 2-5 langkah konkret yang bisa dicoba teknisi, urut prioritas
  }
}`,
  churn_prediction: `{
  "summary": string,                 // 2-4 kalimat ringkasan kondisi churn server ini secara umum
  "detail": {
    "top_risk": [
      {
        "customer_id": string,       // WAJIB salah satu dari customer_id yang diberikan di input
        "name": string,
        "risk_score": number,        // 0-100, makin tinggi makin berisiko churn
        "reason": string             // 1 kalimat singkat alasan spesifik pelanggan ini
      }
    ]                                 // maksimal 10 pelanggan berisiko tertinggi, urut skor menurun
  }
}`,
};

function buildPrompt(action: string, payload: unknown): string {
  if (action === "ticket_diagnosis") {
    return `Kamu adalah asisten NOC untuk ISP lokal. Berdasarkan data tiket gangguan berikut, ` +
      `diagnosis kemungkinan penyebab dan sarankan langkah penanganan untuk teknisi lapangan. ` +
      `Jangan mengarang data yang tidak ada di input — kalau data kurang, katakan itu di summary ` +
      `dan tetap beri saran langkah verifikasi awal yang wajar.\n\n` +
      `DATA TIKET (JSON):\n${JSON.stringify(payload, null, 2)}\n\n` +
      `Balas HANYA dengan JSON valid persis bentuk ini, tanpa teks lain, tanpa markdown fence:\n${SCHEMAS.ticket_diagnosis}`;
  }
  if (action === "churn_prediction") {
    return `Kamu adalah analis operasional untuk ISP lokal. Berdasarkan histori tagihan dan tiket ` +
      `gangguan tiap pelanggan berikut, nilai risiko churn (berhenti berlangganan) masing-masing. ` +
      `Pertimbangkan pola seperti: tunggakan berulang, tiket gangguan berulang tanpa selesai, status isolir. ` +
      `Hanya pakai customer_id yang benar-benar ada di input.\n\n` +
      `DATA PELANGGAN (JSON):\n${JSON.stringify(payload, null, 2)}\n\n` +
      `Balas HANYA dengan JSON valid persis bentuk ini, tanpa teks lain, tanpa markdown fence:\n${SCHEMAS.churn_prediction}`;
  }
  throw new Error(`Action tidak dikenal: ${action}`);
}

function extractJson(text: string): unknown {
  // Model kadang membungkus JSON dengan ```json ... ``` walau sudah diminta tidak — jaga-jaga.
  const cleaned = text.trim().replace(/^```json\s*/i, "").replace(/^```\s*/i, "").replace(/```\s*$/i, "");
  return JSON.parse(cleaned);
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });

  if (!ANTHROPIC_API_KEY) {
    return json({ error: "ANTHROPIC_API_KEY belum diset sebagai secret di Supabase (supabase secrets set ANTHROPIC_API_KEY=...)." }, 500);
  }

  // Verifikasi caller adalah user yang sudah login (bukan sekadar anon key bocor).
  // Tidak perlu service_role di sini — cukup validasi JWT lewat auth.getUser().
  const authHeader = req.headers.get("Authorization") || "";
  const jwt = authHeader.replace(/^Bearer\s+/i, "");
  if (!jwt) return json({ error: "Tidak ada token otorisasi." }, 401);

  const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: userData, error: userErr } = await supabase.auth.getUser(jwt);
  if (userErr || !userData.user) {
    return json({ error: "Sesi tidak valid — silakan login ulang." }, 401);
  }

  let body: { action?: string; payload?: unknown };
  try {
    body = await req.json();
  } catch {
    return json({ error: "Body request bukan JSON valid." }, 400);
  }

  const { action, payload } = body;
  if (!action || !SCHEMAS[action]) {
    return json({ error: `Action harus salah satu dari: ${Object.keys(SCHEMAS).join(", ")}` }, 400);
  }

  let prompt: string;
  try {
    prompt = buildPrompt(action, payload);
  } catch (e) {
    return json({ error: e instanceof Error ? e.message : String(e) }, 400);
  }

  try {
    const resp = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-api-key": ANTHROPIC_API_KEY,
        "anthropic-version": "2023-06-01",
      },
      body: JSON.stringify({
        model: ANTHROPIC_MODEL,
        max_tokens: 1200,
        messages: [{ role: "user", content: prompt }],
      }),
    });

    if (!resp.ok) {
      const errText = await resp.text();
      console.error("Anthropic API error:", resp.status, errText);
      return json({ error: `Model AI gagal merespons (HTTP ${resp.status}).` }, 502);
    }

    const data = await resp.json();
    const textBlock = (data.content || []).find((b: { type: string }) => b.type === "text");
    if (!textBlock) return json({ error: "Model AI tidak mengembalikan teks." }, 502);

    let parsed: { summary: string; risk_score?: number; detail?: unknown };
    try {
      parsed = extractJson(textBlock.text) as typeof parsed;
    } catch (e) {
      console.error("Gagal parse JSON dari model:", textBlock.text);
      return json({ error: "Model AI mengembalikan format yang tidak bisa dibaca. Coba lagi." }, 502);
    }

    if (!parsed || typeof parsed.summary !== "string") {
      return json({ error: "Hasil model AI tidak lengkap (tanpa summary). Coba lagi." }, 502);
    }

    return json({ ...parsed, model: ANTHROPIC_MODEL });
  } catch (e) {
    console.error("ai-assist error:", e);
    return json({ error: e instanceof Error ? e.message : "Terjadi kesalahan tak terduga." }, 500);
  }
});
