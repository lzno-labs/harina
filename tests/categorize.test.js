// SPDX-License-Identifier: AGPL-3.0-only
import assert from "node:assert/strict";
import { test } from "node:test";
import { createDecider } from "../src/decider.js";
import { setup } from "./helpers.js";

/** A decider that records what it was asked and answers with a fixed choice. */
function fakeDecider(answer = { choice: "default-food", confidence: 0.93 }, inputTokens = 500) {
  const asked = [];
  return {
    asked,
    decider: {
      name: "fake",
      async decide(q) {
        asked.push(q);
        return { answers: { category: { type: "choice", ...answer } }, inputTokens };
      },
    },
  };
}

const payment = { merchant: "Musmanni Heredia", amount_minor: 82500, currency: "CRC" };
const ask = (call, h, body = payment) => call("/api/categorize", { method: "POST", headers: h, body });

test("the open core offers no hosted decider", async () => {
  assert.equal(createDecider({}), null);
  const { call, login } = await setup();
  const h = await login();
  assert.deepEqual(await (await call("/api/decider", { headers: h })).json(), {
    available: false, consent: false, tokens_this_month: 0, cap_tokens: 25_000_000,
  });
  assert.equal((await ask(call, h)).status, 404);
});

test("it needs a session or device and the person's consent", async () => {
  const { decider, asked } = fakeDecider();
  const { call, login } = await setup({}, { decider });
  assert.equal((await call("/api/decider")).status, 401);
  const h = await login();
  const r = await ask(call, h);
  assert.equal(r.status, 403);
  assert.equal((await r.json()).error, "consent_required");
  assert.equal(asked.length, 0);
  const on = await (await call("/api/decider/consent", { method: "POST", headers: h, body: { on: true } })).json();
  assert.equal(on.consent, true);
  assert.equal((await call("/api/decider/consent", { method: "POST", headers: h, body: { on: "yes" } })).status, 400);
  assert.equal((await ask(call, h)).status, 200);
  await call("/api/decider/consent", { method: "POST", headers: h, body: { on: false } });
  assert.equal((await ask(call, h)).status, 403);
});

test("it sends only the payment, the categories and recent merchant pairs, and returns the choice", async () => {
  const { decider, asked } = fakeDecider();
  const { call, login } = await setup({}, { decider });
  const h = await login();
  await call("/api/decider/consent", { method: "POST", headers: h, body: { on: true } });
  const base = { kind: "expense", amount_minor: 100000, currency: "CRC", source: "apple_pay", updated_at: Date.now(), note: "secret note", card: "BAC Visa" };
  await call("/api/sync", {
    method: "POST", headers: h,
    body: { changes: { transactions: [
      { ...base, id: "a", merchant: "Automercado", category_id: "default-groceries", occurred_at: "2026-11-02T12:00:00Z" },
      { ...base, id: "b", merchant: "AUTOMERCADO", category_id: "default-groceries", occurred_at: "2026-11-01T12:00:00Z" },
      { ...base, id: "c", merchant: "Uber", category_id: "default-transport", occurred_at: "2026-11-03T12:00:00Z", category_auto: 1 },
    ] } },
  });
  const r = await (await ask(call, h)).json();
  assert.deepEqual(r, { category_id: "default-food", confidence: 0.93 });
  const q = asked[0];
  assert.match(q.state, /Musmanni Heredia/);
  assert.match(q.state, /Automercado: /);
  assert.equal(q.state.match(/automercado/gi).length, 1, "one example per merchant");
  assert.doesNotMatch(q.state, /Uber/, "automatic categories are not examples");
  assert.doesNotMatch(q.state, /secret note|BAC Visa/);
  assert.equal(q.questions.category.type, "choice");
  assert.ok(q.questions.category.criteria["default-food"]);
});

test("an answer outside the person's categories is ignored", async () => {
  const { decider } = fakeDecider({ choice: "made-up", confidence: 0.99 });
  const { call, login } = await setup({}, { decider });
  const h = await login();
  await call("/api/decider/consent", { method: "POST", headers: h, body: { on: true } });
  assert.deepEqual(await (await ask(call, h)).json(), { category_id: null, confidence: 0 });
});

test("tokens are counted and the monthly cap stops the calls", async () => {
  const { decider, asked } = fakeDecider(undefined, 600);
  const { call, login } = await setup({ aiCapTokens: 1000 }, { decider });
  const h = await login();
  await call("/api/decider/consent", { method: "POST", headers: h, body: { on: true } });
  assert.equal((await ask(call, h)).status, 200);
  assert.equal((await ask(call, h)).status, 200);
  const r = await ask(call, h);
  assert.equal(r.status, 429);
  assert.equal((await r.json()).error, "cap_reached");
  assert.equal(asked.length, 2);
  assert.equal((await (await call("/api/decider", { headers: h })).json()).tokens_this_month, 1200);
});

test("bad payments are rejected before asking", async () => {
  const { decider, asked } = fakeDecider();
  const { call, login } = await setup({}, { decider });
  const h = await login();
  await call("/api/decider/consent", { method: "POST", headers: h, body: { on: true } });
  for (const bad of [{ ...payment, merchant: "" }, { ...payment, amount_minor: -1 }, { ...payment, currency: "colones" }]) {
    assert.equal((await ask(call, h, bad)).status, 400, JSON.stringify(bad));
  }
  assert.equal(asked.length, 0);
});
