// Writes tests/fixtures/insights.json: a realistic, deterministic history and the expected
// answers from public/insights.js. The Swift implementation must produce the same answers.
// Run after a deliberate change to the algorithms: TZ=UTC node scripts/gen-insights-fixture.js
import { writeFileSync } from "node:fs";
import { calibrate, decide, detectRecurring, projectMonth, trainCategoryModel } from "../public/insights.js";

export const NOW = "2026-11-10T15:00:00.000Z";

function rng(seed) {
  return () => {
    seed |= 0;
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export function history() {
  const r = rng(42);
  const txs = [];
  let n = 0;
  const add = (date, merchant, amount, category, extra = {}) =>
    txs.push({
      id: `f${String(++n).padStart(4, "0")}`,
      kind: "expense",
      amount_minor: Math.round(amount * 100),
      currency: "CRC",
      category_id: category ? `default-${category}` : null,
      merchant,
      card: "BAC Visa",
      source: "apple_pay",
      occurred_at: date,
      category_auto: 0,
      updated_at: 1,
      ...extra,
    });
  const at = (y, m, d, h = 12) => new Date(Date.UTC(y, m - 1, d, h, 0, 0)).toISOString();
  // Everyday spending, July 1 to November 10, 2026: irregular, so never "fixed".
  for (let day = Date.UTC(2026, 6, 1); day <= Date.UTC(2026, 10, 10); day += 86_400_000) {
    const d = new Date(day);
    const date = (h) => new Date(day + h * 3_600_000).toISOString();
    if (r() < 0.22) add(date(9), r() < 0.7 ? "Automercado Escazú" : "Walmart Escazú", 15000 + r() * 50000, "groceries");
    if (r() < 0.35) add(date(13), r() < 0.6 ? "Soda Tapia" : "Restaurante Silvestre", 4500 + r() * 20000, "food");
    if (r() < 0.3) add(date(18), "Uber", 2500 + r() * 6000, "transport");
    if (r() < 0.06) add(date(17), "Farmacia Fischel", 3000 + r() * 15000, "health");
    if (r() < 0.05) add(date(20), "Cinépolis", 4000 + r() * 6000, "entertainment");
    if (d.getUTCDay() === 6) add(date(8), "Feria del Agricultor Escazú", 10500 + r() * 3000, "groceries");
  }
  // Fixed charges.
  for (const [m, d] of [[7, 14], [8, 14], [9, 14], [10, 14]]) add(at(2026, m, d, 6), "NETFLIX.COM", 15.49, "entertainment", { currency: "USD" });
  for (const [m, d, a] of [[7, 3, 6.99], [8, 3, 6.99], [9, 3, 6.99], [10, 3, 7.99], [11, 3, 7.99]]) add(at(2026, m, d, 6), "Spotify", a, "entertainment", { currency: "USD" });
  for (const [m, a] of [[7, 26450], [8, 28100], [9, 27300], [10, 29050]]) add(at(2026, m, 15, 10), "ICE Electricidad", a, "home", { source: "manual" });
  for (const m of [7, 8, 9]) add(at(2026, m, 5, 7), "Gimnasio Smart Fit", 30000, "health");
  for (const m of [4, 5, 6]) add(at(2026, m, 20, 6), "HBO Max", 9.99, "entertainment", { currency: "USD" });
  add(at(2024, 11, 12, 6), "Cloudflare dominio", 14.2, "other", { currency: "USD" });
  add(at(2025, 11, 12, 6), "Cloudflare dominio", 14.2, "other", { currency: "USD" });
  // A few automatic answers and corrections: automatic ones never train the model.
  add(at(2026, 11, 9, 9), "Automercado Escazú", 21000, "groceries", { category_auto: 1 });
  add(at(2026, 11, 9, 13), "Soda Tapia", 6000, "groceries", { category_auto: 1 });
  add(at(2026, 11, 8, 13), "Restaurante Silvestre", 9000, "food", { category_auto: 2 });
  return txs;
}

export const QUERIES = [
  { merchant: "Automercado Escazú", card: "BAC Visa", amount_minor: 2500000, currency: "CRC" },
  { merchant: "AUTOMERCADO ESCAZU", card: "BAC Visa", amount_minor: 900000, currency: "CRC" },
  { merchant: "Soda Tapia", card: "BAC Visa", amount_minor: 650000, currency: "CRC" },
  { merchant: "Uber", card: "BAC Visa", amount_minor: 420000, currency: "CRC" },
  { merchant: "Automercado Santa Ana", card: "BAC Visa", amount_minor: 3000000, currency: "CRC" },
  { merchant: "Ferretería EPA", card: "BAC Visa", amount_minor: 1800000, currency: "CRC" },
];

export function expected(txs, now = new Date(NOW)) {
  const active = new Set(txs.map((t) => t.category_id).filter(Boolean));
  const model = trainCategoryModel(txs, active);
  const calibration = calibrate(txs, active);
  const recurring = detectRecurring(txs, now);
  return {
    calibration,
    predictions: QUERIES.map((q) => {
      const d = decide(model, calibration, q);
      return { band: d.band, categoryId: d.categoryId, confidence: Number(d.confidence.toFixed(6)) };
    }),
    recurring: recurring.map(({ key, cadence, period, count, confidence, next, status, priceChange, amount, monthly, daysToNext }) => ({
      key, cadence, period, count, confidence, next, status, priceChange, amount, monthly, daysToNext,
    })),
    projection: { CRC: projectMonth(txs, recurring, "CRC", now), USD: projectMonth(txs, recurring, "USD", now) },
  };
}

if (process.argv[1] && import.meta.url.endsWith(process.argv[1].split("/").pop())) {
  if (process.env.TZ !== "UTC") throw new Error("run with TZ=UTC so month boundaries match the Swift tests");
  const txs = history();
  const out = { now: NOW, transactions: txs, expected: expected(txs) };
  if (out.expected.calibration.threshold !== null) out.expected.calibration.precision = Number(out.expected.calibration.precision.toFixed(6));
  out.expected.calibration.accuracy = Number(out.expected.calibration.accuracy.toFixed(6));
  out.expected.calibration.coverage = Number(out.expected.calibration.coverage.toFixed(6));
  writeFileSync("tests/fixtures/insights.json", `${JSON.stringify(out, null, 1)}\n`);
  console.log(JSON.stringify(out.expected, null, 1));
}
