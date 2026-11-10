// SPDX-License-Identifier: AGPL-3.0-only
// Hosted category decision for devices without Apple Intelligence
// (docs/design/hosted-decision-model.md). Every call goes through `categorize`, which checks the
// person's consent, counts tokens per month and stops at the cap (AGENTS.md §5 of the deployer).
import { merchantKey } from "../public/insights.js";
import { formatMinor } from "./export.js";
import { lookup } from "./locales.js";
import { ValidationError } from "./sync.js";

const LANG = "es";
const MAX_EXAMPLES = 40;
const CALLS_PER_HOUR = 120;
/** Default monthly cap: about 1 USD at 0.038 USD per million input tokens. */
export const DEFAULT_CAP_TOKENS = 25_000_000;

export class DeciderError extends Error {
  constructor(code, status) {
    super(code);
    this.code = code;
    this.status = status;
  }
}

const month = (now) => new Date(now).toISOString().slice(0, 7);
const hour = (now) => new Date(now).toISOString().slice(0, 13);
const categoryName = (c) => c.name || lookup(LANG, `categories.default.${c.key}`) || c.key || c.id;

async function metaValue(db, key) {
  return Number((await db.first("SELECT value FROM meta WHERE key = ?", [key]))?.value ?? 0);
}

function bump(key, by) {
  return { sql: "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = value + excluded.value", params: [key, by] };
}

/** Consent is per person (docs/adr/0006-people-and-spaces.md). */
const consentKey = (userId) => `decider_consent_at:${userId}`;

export async function status(db, decider, capTokens, userId, now = Date.now()) {
  return {
    available: Boolean(decider),
    consent: (await metaValue(db, consentKey(userId))) > 0,
    tokens_this_month: await metaValue(db, `decider_tokens:${month(now)}`),
    cap_tokens: capTokens,
  };
}

export async function setConsent(db, userId, on, now = Date.now()) {
  if (on) await db.run("INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value", [consentKey(userId), now]);
  else await db.run("DELETE FROM meta WHERE key = ?", [consentKey(userId)]);
}

/** The text the decision model reads: the payment and the person's recent merchant to category pairs. */
export function buildState({ merchant, amount }, examples) {
  let text = `Pago con tarjeta.\nComercio: ${merchant}\nMonto: ${amount}`;
  if (examples.length) text += `\n\nCategorías que esta persona dio antes a sus comercios:\n${examples.map((e) => `${e.merchant}: ${e.category}`).join("\n")}`;
  return text;
}

async function recentExamples(db, space, names) {
  const rows = await db.all(
    `SELECT merchant, category_id FROM transactions
     WHERE space_id = ? AND deleted = 0 AND kind = 'expense' AND category_id IS NOT NULL AND category_auto != 1 AND merchant IS NOT NULL
     ORDER BY occurred_at DESC LIMIT 500`,
    [space],
  );
  const seen = new Set();
  const out = [];
  for (const r of rows) {
    const key = merchantKey(r.merchant);
    if (!key || seen.has(key) || !names.has(r.category_id)) continue;
    seen.add(key);
    out.push({ merchant: String(r.merchant).slice(0, 60), category: names.get(r.category_id) });
    if (out.length === MAX_EXAMPLES) break;
  }
  return out;
}

/**
 * The one way to ask the hosted decider. Returns `{ category_id, confidence }` (category_id may
 * be null when there is nothing to choose from).
 */
export async function categorize(db, decider, capTokens, who, body, now = Date.now()) {
  if (!decider) throw new DeciderError("not_available", 404);
  if (!((await metaValue(db, consentKey(who.userId))) > 0)) throw new DeciderError("consent_required", 403);
  const space = typeof body?.space_id === "string" ? body.space_id : who.personal;
  if (!who.spaces.includes(space)) throw new ValidationError("invalid_space");
  const merchant = typeof body?.merchant === "string" ? body.merchant.trim().slice(0, 200) : "";
  const amountMinor = body?.amount_minor;
  const currency = body?.currency;
  if (!merchant) throw new ValidationError("merchant_required");
  if (!Number.isSafeInteger(amountMinor) || amountMinor < 0) throw new ValidationError("invalid_amount");
  if (typeof currency !== "string" || !/^[A-Z]{3}$/.test(currency)) throw new ValidationError("invalid_currency");

  const tokensKey = `decider_tokens:${month(now)}`;
  if ((await metaValue(db, tokensKey)) >= capTokens) throw new DeciderError("cap_reached", 429);
  const callsKey = `decider_calls:${hour(now)}`;
  if ((await metaValue(db, callsKey)) >= CALLS_PER_HOUR) throw new DeciderError("rate_limited", 429);

  const categories = await db.all("SELECT id, key, name FROM categories WHERE space_id = ? AND deleted = 0 ORDER BY id", [space]);
  if (categories.length < 2) return { category_id: null, confidence: 0 };
  const names = new Map(categories.slice(0, 255).map((c) => [c.id, categoryName(c)]));
  const state = buildState({ merchant, amount: formatMinor(amountMinor, currency) }, await recentExamples(db, space, names));
  const questions = {
    category: {
      type: "choice",
      instructions: "¿En cuál de las categorías de esta persona va este pago? Usa sus categorías anteriores como guía.",
      criteria: Object.fromEntries(names),
    },
  };

  // Count the call before asking, so a failing provider cannot be retried without limit.
  await db.batch([
    { sql: "DELETE FROM meta WHERE key LIKE 'decider_calls:%' AND key != ?", params: [callsKey] },
    bump(callsKey, 1),
  ]);
  const r = await decider.decide({ state, questions });
  const used = bump(tokensKey, Math.max(0, Math.round(Number(r?.inputTokens) || 0)));
  await db.run(used.sql, used.params);
  const a = r?.answers?.category;
  const id = names.has(a?.choice) ? a.choice : null;
  const confidence = Number.isFinite(a?.confidence) ? Math.min(1, Math.max(0, a.confidence)) : 0;
  return { category_id: id, confidence: id ? confidence : 0 };
}
