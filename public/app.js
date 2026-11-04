// harina web client: a small single page app over the same sync API the iPhone uses.
import { applyI18n, loadLocale, region, t } from "./i18n.js";
import { formatMoney, minorToInput, parseAmount } from "./money.js";
import { createPasskey, getPasskey, supported } from "./webauthn.js";

const CURRENCIES = ["CRC", "USD"];
const state = { origin: "", accounts: new Map(), categories: new Map(), transactions: new Map(), month: monthOf(new Date()) };
const main = document.getElementById("main");

// ---------- helpers ----------

function h(tag, attrs = {}, ...children) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v === undefined || v === null || v === false) continue;
    if (k.startsWith("on")) el.addEventListener(k.slice(2), v);
    else if (k === "text") el.textContent = v;
    else el.setAttribute(k, v === true ? "" : v);
  }
  for (const c of children.flat()) if (c !== null && c !== undefined && c !== false) el.append(c);
  return el;
}

function toast(text) {
  const el = document.getElementById("toast");
  el.textContent = text;
  el.hidden = false;
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => (el.hidden = true), 3000);
}

class ApiError extends Error {}

async function api(path, { method = "GET", body } = {}) {
  let r;
  try {
    r = await fetch(path, {
      method,
      headers: body ? { "Content-Type": "application/json" } : {},
      body: body ? JSON.stringify(body) : undefined,
      credentials: "same-origin",
    });
  } catch {
    throw new ApiError("offline");
  }
  const data = await r.json().catch(() => ({}));
  if (!r.ok) throw new ApiError(data.error || "generic");
  return data;
}

function errorText(e) {
  if (e instanceof ApiError && e.message === "offline") return t("app.offline");
  if (e?.name === "NotAllowedError") return t("errors.passkey_cancelled");
  const key = `errors.${e?.message}`;
  return t(key) === key ? t("errors.generic") : t(key);
}

async function guarded(fn) {
  try {
    await fn();
  } catch (e) {
    if (e instanceof ApiError && e.message === "unauthorized") return boot();
    toast(errorText(e));
  }
}

function uuid() {
  return crypto.randomUUID();
}

function monthOf(d) {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}`;
}

function localMonth(iso) {
  return monthOf(new Date(iso));
}

function dateInputValue(iso) {
  const d = new Date(iso);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

const fmtDate = (iso) => new Intl.DateTimeFormat(region, { day: "numeric", month: "short" }).format(new Date(iso));
const fmtDateTime = (ms) => new Intl.DateTimeFormat(region, { dateStyle: "medium", timeStyle: "short" }).format(new Date(ms));
const fmtMonth = (ym) => new Intl.DateTimeFormat(region, { month: "long", year: "numeric" }).format(new Date(`${ym}-15T12:00:00`));

function categoryName(c) {
  if (!c) return t("form.none");
  return c.name || t(`categories.default.${c.key}`);
}

function liveList(map) {
  return [...map.values()].filter((r) => !r.deleted);
}

function merchantKey(name) {
  return (name ?? "").normalize("NFD").replace(/\p{M}/gu, "").toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
}

/** The category last used for this merchant, if any. */
function suggestCategory(merchant) {
  const key = merchantKey(merchant);
  if (!key) return null;
  let best = null;
  for (const tx of liveList(state.transactions)) {
    if (tx.category_id && merchantKey(tx.merchant) === key && (!best || tx.updated_at > best.updated_at)) best = tx;
  }
  const c = best && state.categories.get(best.category_id);
  return c && !c.deleted ? c : null;
}

const needsReview = (tx) => !tx.deleted && (tx.needs_review || (tx.kind === "expense" && !tx.category_id));

// ---------- data ----------

function applyRecords(records) {
  for (const [entity, rows] of Object.entries(records)) for (const r of rows) state[entity].set(r.id, r);
}

async function loadAll() {
  let since = 0;
  for (;;) {
    const r = await api(`/api/sync?since=${since}`);
    applyRecords(r.records);
    since = r.seq;
    if (!r.more) break;
  }
}

async function save(entity, record) {
  const r = await api("/api/sync", { method: "POST", body: { changes: { [entity]: [{ ...record, updated_at: Date.now() }] } } });
  applyRecords(r.records);
}

// ---------- views ----------

function setView(title, ...content) {
  main.replaceChildren(h("h1", { text: title }), ...content);
  for (const a of document.querySelectorAll(".top a")) {
    a.toggleAttribute("aria-current", a.getAttribute("href") === (location.hash || "#/"));
    if (a.hasAttribute("aria-current")) a.setAttribute("aria-current", "page");
  }
}

function viewSetup() {
  const token = h("input", { name: "token", autocomplete: "one-time-code", required: true });
  setView(
    t("setup.title"),
    h("p", { text: t("setup.intro") }),
    h(
      "form",
      {
        onsubmit: (e) => {
          e.preventDefault();
          guarded(async () => {
            if (!supported()) throw new Error("passkey_unsupported");
            const { challengeId, options } = await api("/api/auth/register/options", { method: "POST", body: { setupToken: token.value } });
            const response = await createPasskey(options);
            await api("/api/auth/register/verify", { method: "POST", body: { setupToken: token.value, challengeId, response } });
            await boot();
          });
        },
      },
      h("label", { text: t("setup.token") }, token),
      h("button", { class: "primary", text: t("setup.create") }),
    ),
  );
}

function viewLogin() {
  setView(
    t("login.title"),
    h("p", { class: "muted", text: t("app.tagline") }),
    h("button", {
      class: "primary",
      text: t("login.button"),
      onclick: () =>
        guarded(async () => {
          if (!supported()) throw new Error("passkey_unsupported");
          const { challengeId, options } = await api("/api/auth/login/options", { method: "POST", body: {} });
          const response = await getPasskey(options);
          await api("/api/auth/login/verify", { method: "POST", body: { challengeId, response } });
          await boot();
        }),
    }),
  );
}

function shiftMonth(ym, delta) {
  const [y, m] = ym.split("-").map(Number);
  return monthOf(new Date(y, m - 1 + delta, 1));
}

function viewMonth() {
  const txs = liveList(state.transactions)
    .filter((tx) => localMonth(tx.occurred_at) === state.month)
    .sort((a, b) => b.occurred_at.localeCompare(a.occurred_at));
  const totals = {};
  const byCat = {};
  for (const tx of txs) {
    totals[tx.currency] ??= { expense: 0, income: 0 };
    totals[tx.currency][tx.kind] += tx.amount_minor;
    if (tx.kind === "expense") {
      const k = `${tx.currency}|${tx.category_id ?? ""}`;
      byCat[k] = (byCat[k] ?? 0) + tx.amount_minor;
    }
  }
  const pending = liveList(state.transactions).filter(needsReview).length;
  const go = (d) => () => {
    state.month = shiftMonth(state.month, d);
    viewMonth();
  };
  setView(
    t("month.title"),
    h(
      "div",
      { class: "monthnav" },
      h("button", { text: "‹", "aria-label": t("month.previous"), onclick: go(-1) }),
      h("strong", { text: fmtMonth(state.month) }),
      h("button", { text: "›", "aria-label": t("month.next"), onclick: go(1) }),
    ),
    pending ? h("p", {}, h("a", { href: "#/revisar", text: t("month.toReview", { count: pending }) })) : null,
    h(
      "div",
      { class: "card totals" },
      Object.keys(totals).length
        ? Object.entries(totals).flatMap(([cur, v]) => [
            h("div", { class: "total" }, h("span", { class: "muted", text: `${t("month.spent")} ${cur}` }), h("b", { class: "bad", text: formatMoney(v.expense, cur, region) })),
            h("div", { class: "total" }, h("span", { class: "muted", text: `${t("month.earned")} ${cur}` }), h("b", { class: "good", text: formatMoney(v.income, cur, region) })),
          ])
        : h("p", { class: "muted", text: t("month.empty") }),
    ),
    Object.keys(byCat).length
      ? h(
          "div",
          { class: "card" },
          h("h2", { text: t("month.byCategory") }),
          h(
            "ul",
            { class: "list" },
            Object.entries(byCat)
              .sort((a, b) => b[1] - a[1])
              .map(([k, v]) => {
                const [cur, cat] = k.split("|");
                return h("li", {}, h("span", { text: categoryName(state.categories.get(cat)) }), h("span", { text: formatMoney(v, cur, region) }));
              }),
          ),
        )
      : null,
    txs.length ? h("div", { class: "card" }, h("h2", { text: t("month.movements") }), txList(txs)) : null,
  );
}

function txList(txs) {
  return h(
    "ul",
    { class: "list" },
    txs.map((tx) =>
      h(
        "li",
        {},
        h(
          "a",
          { href: `#/editar/${tx.id}` },
          h(
            "span",
            {},
            h("span", { text: tx.merchant || tx.note || categoryName(state.categories.get(tx.category_id)) }),
            h("div", {
              class: "meta",
              text: [fmtDate(tx.occurred_at), categoryName(state.categories.get(tx.category_id)), t(`source.${tx.source}`)].join(" · "),
            }),
          ),
          h("span", { class: tx.kind === "income" ? "good" : "", text: formatMoney(tx.amount_minor, tx.currency, region) }),
        ),
      ),
    ),
  );
}

function options(list, selected, noneText) {
  return [h("option", { value: "", text: noneText }), ...list.map(([id, label]) => h("option", { value: id, text: label, selected: id === selected }))];
}

function viewForm(existing) {
  const tx = existing ?? { id: uuid(), kind: "expense", currency: "CRC", source: "manual", occurred_at: new Date().toISOString() };
  const amount = h("input", {
    class: "big",
    inputmode: "decimal",
    autocomplete: "off",
    required: true,
    value: existing ? minorToInput(tx.amount_minor, tx.currency, region) : "",
    "aria-label": t("form.amount"),
  });
  const kind = (k) => h("label", {}, h("input", { type: "radio", name: "kind", value: k, checked: tx.kind === k }), t(`form.${k}`));
  const currency = h("select", {}, CURRENCIES.map((c) => h("option", { value: c, text: c, selected: c === tx.currency })));
  const cats = liveList(state.categories).map((c) => [c.id, categoryName(c)]).sort((a, b) => a[1].localeCompare(b[1], region));
  const category = h("select", {}, options(cats, tx.category_id, t("form.none")));
  const accounts = h("select", {}, options(liveList(state.accounts).map((a) => [a.id, a.name]), tx.account_id, t("form.noAccount")));
  const date = h("input", { type: "date", value: dateInputValue(tx.occurred_at), required: true });
  const merchant = h("input", { value: tx.merchant ?? "", autocomplete: "off" });
  const note = h("input", { value: tx.note ?? "" });
  const hint = h("p", { class: "meta" });
  const showHint = () => {
    const s = !category.value && suggestCategory(merchant.value);
    hint.replaceChildren(s ? h("button", { type: "button", text: t("form.suggested", { category: categoryName(s) }), onclick: () => ((category.value = s.id), showHint()) }) : "");
  };
  merchant.addEventListener("input", showHint);
  category.addEventListener("change", showHint);
  showHint();
  const form = h(
    "form",
    {
      onsubmit: (e) => {
        e.preventDefault();
        const minor = parseAmount(amount.value, currency.value);
        if (minor === null) return toast(t("form.invalidAmount"));
        const day = date.value.split("-").map(Number);
        const old = new Date(tx.occurred_at);
        const when = new Date(day[0], day[1] - 1, day[2], old.getHours(), old.getMinutes());
        guarded(async () => {
          await save("transactions", {
            ...tx,
            kind: form.querySelector("input[name=kind]:checked").value,
            amount_minor: minor,
            currency: currency.value,
            category_id: category.value || null,
            account_id: accounts.value || null,
            merchant: merchant.value,
            note: note.value,
            needs_review: false,
            occurred_at: when.toISOString(),
          });
          toast(t("form.saved"));
          state.month = monthOf(when);
          location.hash = existing ? "#/" : "#/nuevo";
          if (!existing) viewForm();
        });
      },
    },
    h("div", { class: "seg", role: "radiogroup", "aria-label": t("form.kind") }, kind("expense"), kind("income")),
    h("div", { class: "row" }, amount, h("label", { text: t("form.currency") }, currency)),
    tx.raw_amount ? h("p", { class: "meta", text: t("review.rawAmount", { raw: tx.raw_amount }) }) : null,
    h("label", { text: t("form.merchant") }, merchant),
    h("label", { text: t("form.category") }, category),
    hint,
    h("div", { class: "row" }, h("label", { text: t("form.account") }, accounts), h("label", { text: t("form.date") }, date)),
    h("label", { text: t("form.note") }, note),
    h("button", { class: "primary", text: t("form.save") }),
    existing
      ? h("button", {
          type: "button",
          class: "danger",
          text: t("form.delete"),
          onclick: () =>
            confirm(t("form.confirmDelete")) &&
            guarded(async () => {
              await save("transactions", { ...tx, deleted: true });
              location.hash = "#/";
            }),
        })
      : null,
  );
  setView(t(existing ? "form.titleEdit" : "form.titleNew"), form);
  amount.focus();
}

function viewReview() {
  const txs = liveList(state.transactions)
    .filter(needsReview)
    .sort((a, b) => b.occurred_at.localeCompare(a.occurred_at));
  setView(
    t("review.title"),
    h("p", { class: "muted", text: t("review.intro") }),
    txs.length
      ? h(
          "ul",
          { class: "list" },
          txs.map((tx) => {
            const s = !tx.needs_review && suggestCategory(tx.merchant);
            return h(
              "li",
              {},
              h(
                "a",
                { href: `#/editar/${tx.id}` },
                h("span", {}, h("span", { text: tx.merchant || "?" }), h("div", { class: "meta", text: fmtDate(tx.occurred_at) })),
                h("span", { text: tx.needs_review && tx.raw_amount ? tx.raw_amount : formatMoney(tx.amount_minor, tx.currency, region) }),
              ),
              s
                ? h("button", {
                    text: t("review.apply", { category: categoryName(s) }),
                    onclick: () => guarded(async () => (await save("transactions", { ...tx, category_id: s.id }), viewReview())),
                  })
                : null,
            );
          }),
        )
      : h("p", { text: t("review.empty") }),
  );
}

async function viewSettings() {
  const { devices } = await api("/api/devices");
  const rerender = () => guarded(viewSettings);
  const named = (entity, labelKey, extra = () => ({})) =>
    h(
      "form",
      {
        class: "row",
        onsubmit: (e) => {
          e.preventDefault();
          const input = e.target.querySelector("input");
          if (!input.value.trim()) return;
          guarded(async () => (await save(entity, { id: uuid(), name: input.value.trim(), ...extra(e.target) }), rerender()));
        },
      },
      h("input", { "aria-label": t(labelKey), placeholder: t(labelKey) }),
      h("button", { text: t(`${entity}.add`) }),
    );
  const codeBox = h("div");
  setView(
    t("nav.settings"),
    h(
      "section",
      { class: "card" },
      h("h2", { text: t("categories.title") }),
      h(
        "ul",
        { class: "list" },
        liveList(state.categories)
          .sort((a, b) => categoryName(a).localeCompare(categoryName(b), region))
          .map((c) =>
            h(
              "li",
              {},
              h("span", { text: categoryName(c) }),
              h(
                "span",
                { class: "actions" },
                h("button", {
                  text: t("categories.rename"),
                  onclick: () => {
                    const name = prompt(t("categories.newName"), categoryName(c));
                    if (name && name.trim()) guarded(async () => (await save("categories", { ...c, name: name.trim() }), rerender()));
                  },
                }),
                h("button", {
                  class: "danger",
                  text: t("form.delete"),
                  onclick: () => confirm(t("categories.confirmDelete", { name: categoryName(c) })) && guarded(async () => (await save("categories", { ...c, deleted: true }), rerender())),
                }),
              ),
            ),
          ),
      ),
      named("categories", "categories.newName"),
    ),
    h(
      "section",
      { class: "card" },
      h("h2", { text: t("accounts.title") }),
      h(
        "ul",
        { class: "list" },
        liveList(state.accounts).map((a) =>
          h(
            "li",
            {},
            h("span", {}, h("span", { text: a.name }), a.card ? h("div", { class: "meta", text: a.card }) : null),
            h("button", {
              class: "danger",
              text: t("form.delete"),
              onclick: () => confirm(t("accounts.confirmDelete", { name: a.name })) && guarded(async () => (await save("accounts", { ...a, deleted: true }), rerender())),
            }),
          ),
        ),
      ),
      h(
        "form",
        {
          onsubmit: (e) => {
            e.preventDefault();
            const [name, card] = e.target.querySelectorAll("input");
            if (!name.value.trim()) return;
            guarded(async () => (await save("accounts", { id: uuid(), name: name.value.trim(), card: card.value.trim() || null }), rerender()));
          },
        },
        h("label", { text: t("accounts.name") }, h("input", { required: true })),
        h("label", { text: t("accounts.card") }, h("input", {})),
        h("p", { class: "meta", text: t("accounts.cardHint") }),
        h("button", { text: t("accounts.add") }),
      ),
    ),
    h(
      "section",
      { class: "card" },
      h("h2", { text: t("devices.title") }),
      h("p", { class: "muted", text: t("devices.intro") }),
      h("p", { text: t("devices.server", { url: state.origin }) }),
      devices.length
        ? h(
            "ul",
            { class: "list" },
            devices.map((d) =>
              h(
                "li",
                {},
                h("span", {}, h("span", { text: d.name }), h("div", { class: "meta", text: t("devices.lastSeen", { date: fmtDateTime(d.last_seen_at ?? d.created_at) }) })),
                h("button", {
                  class: "danger",
                  text: t("devices.revoke"),
                  onclick: () => confirm(t("devices.confirmRevoke", { name: d.name })) && guarded(async () => (await api(`/api/devices/${d.id}`, { method: "DELETE" }), rerender())),
                }),
              ),
            ),
          )
        : h("p", { class: "meta", text: t("devices.empty") }),
      h("button", {
        text: t("devices.newCode"),
        onclick: () =>
          guarded(async () => {
            const { code, expiresAt } = await api("/api/devices/link-code", { method: "POST", body: {} });
            const time = new Intl.DateTimeFormat(region, { timeStyle: "short" }).format(new Date(expiresAt));
            codeBox.replaceChildren(h("p", { class: "meta", text: t("devices.code", { time }) }), h("p", { class: "code", text: code }));
          }),
      }),
      codeBox,
    ),
    h(
      "section",
      { class: "card" },
      h("h2", { text: t("data.title") }),
      h("p", { class: "muted", text: t("data.intro") }),
      h("div", { class: "row" }, h("a", { href: "/api/export.csv", download: "harina.csv", text: t("data.exportCsv") }), h("a", { href: "/api/export.json", download: "harina.json", text: t("data.exportJson") })),
      h("p", { class: "meta", text: t("data.privacy") }),
      h("button", {
        text: t("passkeys.add"),
        onclick: () =>
          guarded(async () => {
            const { challengeId, options } = await api("/api/auth/register/options", { method: "POST", body: {} });
            const response = await createPasskey(options);
            await api("/api/auth/register/verify", { method: "POST", body: { challengeId, response } });
            toast(t("passkeys.added"));
          }),
      }),
      h("button", {
        class: "danger",
        text: t("data.deleteAll"),
        onclick: () => {
          if (prompt(t("data.confirmDeleteAll")) !== t("data.confirmWord")) return;
          guarded(async () => {
            await api("/api/data/delete", { method: "POST", body: { confirm: true } });
            await loadAll();
            toast(t("data.deleted"));
            rerender();
          });
        },
      }),
      h("button", {
        text: t("nav.logout"),
        onclick: () => guarded(async () => (await api("/api/auth/logout", { method: "POST", body: {} }), boot())),
      }),
    ),
  );
}

function router() {
  const hash = location.hash || "#/";
  const edit = hash.match(/^#\/editar\/(.+)$/);
  if (edit) {
    const tx = state.transactions.get(edit[1]);
    return tx && !tx.deleted ? viewForm(tx) : (location.hash = "#/");
  }
  if (hash === "#/nuevo") return viewForm();
  if (hash === "#/revisar") return viewReview();
  if (hash === "#/ajustes") return guarded(viewSettings);
  return viewMonth();
}

async function boot() {
  document.querySelector(".top").hidden = true;
  main.replaceChildren(h("p", { class: "muted", text: t("app.loading") }));
  let session;
  try {
    session = await api("/api/session");
  } catch (e) {
    return main.replaceChildren(h("p", { text: errorText(e) }));
  }
  state.origin = session.origin;
  if (session.setupNeeded) return viewSetup();
  if (!session.authenticated) return viewLogin();
  for (const k of ["accounts", "categories", "transactions"]) state[k].clear();
  await guarded(loadAll);
  document.querySelector(".top").hidden = false;
  router();
}

window.addEventListener("hashchange", router);
await loadLocale();
applyI18n();
boot();
