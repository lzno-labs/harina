import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { calibrate, decide, detectRecurring, liveStats, predict, priceChange, projectMonth, trainCategoryModel } from "../public/insights.js";
import { NOW, QUERIES, expected, history } from "../scripts/gen-insights-fixture.js";

const txs = history();
const active = new Set(txs.map((t) => t.category_id).filter(Boolean));
const now = new Date(NOW);

test("the fixture shared with the Swift tests matches this implementation", () => {
  const fixture = JSON.parse(readFileSync("tests/fixtures/insights.json", "utf8"));
  assert.deepEqual(fixture.transactions, txs, "regenerate with: TZ=UTC node scripts/gen-insights-fixture.js");
  const got = JSON.parse(JSON.stringify(expected(txs, now)));
  for (const k of ["accuracy", "precision", "coverage"]) if (got.calibration[k] !== null) got.calibration[k] = Number(got.calibration[k].toFixed(6));
  assert.deepEqual(got, fixture.expected);
});

test("known merchants are categorized automatically; new ones are only suggested or asked", () => {
  const model = trainCategoryModel(txs, active);
  const cal = calibrate(txs, active);
  assert.ok(cal.threshold !== null && cal.cases >= 20);
  const [auto, upper, soda, uber, newBranch, unknown] = QUERIES.map((q) => decide(model, cal, q));
  assert.deepEqual([auto.band, auto.categoryId], ["act", "default-groceries"]);
  assert.equal(upper.band, "act", "case and accents do not matter");
  assert.deepEqual([soda.categoryId, uber.categoryId], ["default-food", "default-transport"]);
  assert.deepEqual([newBranch.band, newBranch.categoryId], ["suggest", "default-groceries"], "a word in common is a hint, not a certainty");
  assert.equal(unknown.band, "ask", "no merchant signal: the prior alone is not a suggestion");
});

test("automatic answers never train the model; corrections do", () => {
  const model = trainCategoryModel(txs, active);
  // "Soda Tapia" was auto-labeled as groceries once (category_auto 1): ignored.
  assert.equal(predict(model, QUERIES[2]).ranked[0].id, "default-food");
  assert.deepEqual(liveStats(txs), { auto: 2, corrected: 1, precision: 2 / 3 });
});

test("inconsistent labels make the threshold stricter or switch automation off", () => {
  const noisy = txs.map((t, i) => (t.merchant === "Soda Tapia" && i % 3 === 0 ? { ...t, category_id: "default-entertainment" } : t));
  const cal = calibrate(noisy, active);
  const clean = calibrate(txs, active);
  assert.ok(cal.accuracy < clean.accuracy);
  assert.ok(cal.threshold === null || cal.threshold >= clean.threshold);
  const model = trainCategoryModel(noisy, active);
  assert.notEqual(decide(model, cal, QUERIES[2]).band, "act", "a merchant you categorize two ways is not automated");
});

test("too little history: nothing is automatic yet", () => {
  const few = txs.slice(0, 15);
  assert.equal(calibrate(few, active).threshold, null);
});

test("recurring expenses: cadence, status, price change; irregular and ended ones are left out", () => {
  const rec = detectRecurring(txs, now);
  const by = Object.fromEntries(rec.map((r) => [r.key, r]));
  assert.deepEqual(Object.keys(by).sort(), [
    "cloudflare dominio|USD",
    "feria del agricultor escazu|CRC",
    "gimnasio smart fit|CRC",
    "ice electricidad|CRC",
    "netflix com|USD",
    "spotify|USD",
  ]);
  assert.equal(by["netflix com|USD"].cadence, "monthly");
  assert.equal(by["netflix com|USD"].status, "soon");
  assert.equal(by["feria del agricultor escazu|CRC"].cadence, "weekly");
  assert.equal(by["cloudflare dominio|USD"].cadence, "yearly");
  assert.equal(by["cloudflare dominio|USD"].confidence, "likely");
  assert.equal(by["gimnasio smart fit|CRC"].status, "missed");
  assert.deepEqual(by["spotify|USD"].priceChange, { from: 699, to: 799 });
  assert.equal(by["ice electricidad|CRC"].priceChange, null, "a bill that varies every month is not a price change");
  assert.ok(!("uber|CRC" in by) && !("automercado escazu|CRC" in by) && !("hbo max|USD" in by));
});

test("price change only for a stable price that changed in the last two charges", () => {
  assert.deepEqual(priceChange([699, 699, 699, 799]), { from: 699, to: 799 });
  assert.deepEqual(priceChange([699, 699, 799, 799]), { from: 699, to: 799 });
  assert.equal(priceChange([699, 799, 799, 799]), null, "old news");
  assert.equal(priceChange([2600, 2800, 2700, 2900]), null);
  assert.equal(priceChange([500, 500]), null);
});

test("month projection adds fixed charges still due and variable spending at the current pace", () => {
  const rec = detectRecurring(txs, now);
  const p = projectMonth(txs, rec, "USD", now);
  // Spotify (7.99) already charged; Netflix (15.49) and the domain (14.20) still due.
  assert.deepEqual([p.spent, p.fixedRemaining, p.projected], [799, 1549 + 1420, 799 + 1549 + 1420]);
  const crc = projectMonth(txs, rec, "CRC", now);
  assert.ok(crc.projected > crc.spent + crc.fixedRemaining);
  assert.equal(projectMonth(txs, rec, "CRC", new Date("2026-11-02T12:00:00Z")), null, "too early in the month");
});
