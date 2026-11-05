// Insights computed locally from the person's own movements (docs/design/fijos-y-categoria-automatica.md):
// a small decision model for categories and the detection of recurring expenses.
// The same algorithms live in ios/HarinaKit/Sources/HarinaKit/Insights.swift; both are checked
// against tests/fixtures/insights.json. Keep them in step.

const DAY = 86_400_000;

/** Same normalization as the server and the iPhone: case, accents and punctuation do not matter. */
export function merchantKey(name) {
  return (name ?? "")
    .normalize("NFD")
    .replace(/\p{M}/gu, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}

// ---------- decision model for categories ----------

export const SUGGEST_AT = 0.4;
export const TARGET_PRECISION = 0.95;
export const MIN_CALIBRATION_CASES = 20;
const THRESHOLDS = [50, 55, 60, 65, 70, 75, 80, 85, 90, 95, 99].map((x) => x / 100);
const MERCHANT_WEIGHT = 3;

/** The state the model answers about: merchant, card, amount and currency. */
export function features(s) {
  const out = [];
  const m = merchantKey(s.merchant);
  if (m) {
    for (let i = 0; i < MERCHANT_WEIGHT; i++) out.push(`m:${m}`);
    for (const w of m.split(" ")) if (w.length >= 2 && !/^\d+$/.test(w)) out.push(`w:${w}`);
  }
  const c = merchantKey(s.card);
  if (c) out.push(`c:${c}`);
  if (s.currency && Number.isFinite(s.amount_minor) && s.amount_minor >= 0) {
    out.push(`a:${s.currency}:${Math.floor(Math.log2(s.amount_minor / 100 + 1))}`);
  }
  return out;
}

/** Labels the person set or corrected (never the model's own automatic answers). */
export function isLabel(tx, activeIds) {
  return !tx.deleted && tx.kind === "expense" && tx.category_id && activeIds.has(tx.category_id) && (tx.category_auto ?? 0) !== 1;
}

export function emptyModel() {
  return { docs: 0, classes: new Map(), vocab: new Set() };
}

export function learn(model, tx) {
  let c = model.classes.get(tx.category_id);
  if (!c) model.classes.set(tx.category_id, (c = { docs: 0, total: 0, counts: new Map() }));
  c.docs += 1;
  model.docs += 1;
  for (const f of features(tx)) {
    c.counts.set(f, (c.counts.get(f) ?? 0) + 1);
    c.total += 1;
    model.vocab.add(f);
  }
}

// Plain code-point order (not locale collation), so the Swift implementation sorts the same way.
const cmp = (a, b) => (a < b ? -1 : a > b ? 1 : 0);
const byDate = (a, b) => cmp(a.occurred_at, b.occurred_at) || cmp(a.id, b.id);

export function trainCategoryModel(txs, activeIds) {
  const model = emptyModel();
  for (const tx of txs.filter((t) => isLabel(t, activeIds)).sort(byDate)) learn(model, tx);
  return model;
}

/**
 * Probability per category, highest first, and a calibrated-style confidence in [0, 1]:
 * (p_max - 1/n) / (1 - 1/n), n = number of categories the model knows.
 */
export function predict(model, state) {
  const n = model.classes.size;
  const fsAll = features(state);
  const known = model.vocab.has(`m:${merchantKey(state.merchant)}`);
  // Some word of the merchant was seen before; without it the answer is only the prior.
  const merchantSignal = fsAll.some((f) => (f.startsWith("m:") || f.startsWith("w:")) && model.vocab.has(f));
  if (n === 0) return { ranked: [], confidence: 0, knownMerchant: known, merchantSignal };
  const V = model.vocab.size;
  const fs = fsAll.filter((f) => model.vocab.has(f));
  const scores = [];
  for (const [id, c] of model.classes) {
    let lp = Math.log(c.docs / model.docs);
    for (const f of fs) lp += Math.log(((c.counts.get(f) ?? 0) + 1) / (c.total + V));
    scores.push([id, lp]);
  }
  const max = Math.max(...scores.map(([, v]) => v));
  const exp = scores.map(([id, v]) => [id, Math.exp(v - max)]);
  const sum = exp.reduce((a, [, v]) => a + v, 0);
  const ranked = exp.map(([id, v]) => ({ id, p: v / sum })).sort((a, b) => b.p - a.p || cmp(a.id, b.id));
  const confidence = n < 2 ? 0 : Math.max(0, (ranked[0].p - 1 / n) / (1 - 1 / n));
  return { ranked, confidence, knownMerchant: known, merchantSignal };
}

/**
 * Replays the person's labels in date order, each predicted from the earlier ones, and picks the
 * lowest threshold whose predictions were right at least 95 times in 100 (over 20 or more cases).
 */
export function calibrate(txs, activeIds) {
  const labels = txs.filter((t) => isLabel(t, activeIds)).sort(byDate);
  const model = emptyModel();
  const cases = [];
  for (const tx of labels) {
    if (model.classes.size >= 2 && model.docs >= 10) {
      const r = predict(model, tx);
      cases.push({ confidence: r.confidence, correct: r.ranked[0].id === tx.category_id, known: r.knownMerchant });
    }
    learn(model, tx);
  }
  const accuracy = cases.length ? cases.filter((c) => c.correct).length / cases.length : null;
  const known = cases.filter((c) => c.known);
  for (const t of THRESHOLDS) {
    const above = known.filter((c) => c.confidence >= t);
    if (above.length < MIN_CALIBRATION_CASES) continue;
    const precision = above.filter((c) => c.correct).length / above.length;
    if (precision >= TARGET_PRECISION) {
      return { threshold: t, cases: cases.length, accuracy, precision, coverage: known.length ? above.length / known.length : 0 };
    }
  }
  return { threshold: null, cases: cases.length, accuracy, precision: null, coverage: 0 };
}

/** Bands: act (assign automatically), suggest (highlight in review) or ask. */
export function decide(model, calibration, state) {
  const r = predict(model, state);
  const top = r.ranked[0];
  let band = "ask";
  if (top && calibration.threshold !== null && r.knownMerchant && r.confidence >= calibration.threshold) band = "act";
  else if (top && r.merchantSignal && r.confidence >= SUGGEST_AT) band = "suggest";
  return { band, categoryId: top?.id ?? null, confidence: r.confidence, ranked: r.ranked };
}

/** How the automatic categories did in real use: kept versus corrected by the person. */
export function liveStats(txs) {
  const live = txs.filter((t) => !t.deleted);
  const auto = live.filter((t) => t.category_auto === 1).length;
  const corrected = live.filter((t) => t.category_auto === 2).length;
  return { auto, corrected, precision: auto + corrected ? auto / (auto + corrected) : null };
}

// ---------- recurring expenses ----------

export const CADENCES = {
  weekly: { min: 5, max: 9, grace: 2, perMonth: 52 / 12 },
  monthly: { min: 25, max: 35, grace: 5, perMonth: 1 },
  yearly: { min: 350, max: 380, grace: 15, perMonth: 1 / 12 },
};

function median(xs) {
  const s = [...xs].sort((a, b) => a - b);
  const m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}

const same = (a, b) => Math.abs(a - b) / Math.min(a, b) <= 0.02;

/**
 * A fixed price that changed in one of the last two charges, for example 6.99 → 7.99.
 * Bills that vary every month (electricity) never qualify: the price before the change must be stable.
 */
export function priceChange(amounts) {
  const n = amounts.length;
  let i = n - 1;
  while (i > 0 && same(amounts[i], amounts[i - 1])) i--;
  if (i === 0 || i < n - 2) return null;
  const before = amounts.slice(0, i);
  const after = amounts.slice(i);
  const stable = (xs) => xs.every((x) => same(x, xs[0]));
  return stable(before) && stable(after) ? { from: before[before.length - 1], to: after[after.length - 1] } : null;
}

/**
 * Expenses that repeat with the same merchant and currency, a regular cadence and a similar amount.
 * @returns list sorted by the next expected charge
 */
export function detectRecurring(txs, now = new Date()) {
  const groups = new Map();
  for (const t of txs) {
    if (t.deleted || t.kind !== "expense") continue;
    const k = merchantKey(t.merchant);
    if (!k) continue;
    const key = `${k}|${t.currency}`;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(t);
  }
  const out = [];
  for (const [key, list] of groups) {
    if (list.length < 2) continue;
    list.sort(byDate);
    const times = list.map((t) => Date.parse(t.occurred_at));
    const intervals = times.slice(1).map((t, i) => (t - times[i]) / DAY);
    const period = median(intervals);
    const cadence = Object.keys(CADENCES).find((c) => period >= CADENCES[c].min && period <= CADENCES[c].max);
    if (!cadence) continue;
    const { min, max, grace, perMonth } = CADENCES[cadence];
    const inWindow = intervals.filter((d) => d >= min && d <= max).length;
    if (inWindow / intervals.length < 0.75) continue;
    const amounts = list.map((t) => t.amount_minor);
    const lo = Math.min(...amounts);
    if (lo <= 0 || Math.max(...amounts) / lo > 1.35) continue;
    const last = list[list.length - 1];
    const lastTime = times[times.length - 1];
    const sinceLast = (now.getTime() - lastTime) / DAY;
    if (sinceLast > 2.5 * period) continue; // ended
    const next = lastTime + Math.round((period * DAY) / 60_000) * 60_000; // whole minutes
    const daysToNext = (next - now.getTime()) / DAY;
    const status = -daysToNext > grace ? "missed" : daysToNext <= 7 ? "soon" : "scheduled";
    out.push({
      key,
      merchant: last.merchant,
      currency: last.currency,
      amount: last.amount_minor,
      cadence,
      period: Math.round(period),
      count: list.length,
      confidence: list.length >= 3 ? "sure" : "likely",
      last: new Date(lastTime).toISOString(),
      next: new Date(next).toISOString(),
      daysToNext: Math.ceil(daysToNext),
      status,
      priceChange: priceChange(amounts),
      categoryId: last.category_id ?? null,
      monthly: Math.round(last.amount_minor * perMonth),
    });
  }
  return out.sort((a, b) => cmp(a.next, b.next) || cmp(a.key, b.key));
}

/**
 * Month-end estimate for one currency, from day 3 of the current month:
 * spent so far + fixed charges still due this month + daily variable spending times days left.
 */
export function projectMonth(txs, recurring, currency, now = new Date()) {
  const day = now.getDate();
  if (day < 3) return null;
  const start = new Date(now.getFullYear(), now.getMonth(), 1).getTime();
  const end = new Date(now.getFullYear(), now.getMonth() + 1, 1).getTime();
  const daysInMonth = Math.round((end - start) / DAY);
  const fixedKeys = new Set(recurring.filter((r) => r.currency === currency).map((r) => r.key));
  let spent = 0;
  let fixedSoFar = 0;
  for (const t of txs) {
    if (t.deleted || t.kind !== "expense" || t.currency !== currency) continue;
    const at = Date.parse(t.occurred_at);
    if (at < start || at > now.getTime()) continue;
    spent += t.amount_minor;
    if (fixedKeys.has(`${merchantKey(t.merchant)}|${currency}`)) fixedSoFar += t.amount_minor;
  }
  let fixedRemaining = 0;
  for (const r of recurring) {
    if (r.currency !== currency) continue;
    const next = Date.parse(r.next);
    if (next < now.getTime()) {
      // Late: still expected this month if it has not been charged since the month began.
      if (Date.parse(r.last) < start) fixedRemaining += r.amount;
      continue;
    }
    for (let d = next; d < end; d += r.period * DAY) fixedRemaining += r.amount;
  }
  const dailyVariable = (spent - fixedSoFar) / day;
  const projected = Math.round(spent + fixedRemaining + dailyVariable * (daysInMonth - day));
  return { spent, fixedRemaining, dailyVariable: Math.round(dailyVariable), projected };
}
