// harina web client: a small single page app over the same sync API the iPhone uses.
import { applyI18n, loadLocale, region, t } from "./i18n.js";
import { formatMoney, minorToInput, parseAmount } from "./money.js";
import { createPasskey, getPasskey, supported } from "./webauthn.js";
import qrcode from "./vendor/qrcode-generator-2.0.4.js";
import { calibrate, decide, detectRecurring, liveStats, merchantKey, projectMonth, trainCategoryModel } from "./insights.js";

const CURRENCIES = ["CRC", "USD"];
const state = {
  origin: "",
  accounts: new Map(),
  categories: new Map(),
  transactions: new Map(),
  month: monthOf(new Date()),
  currency: null,
  filter: "all",
  query: "",
  back: "#/",
  devices: [],
};
const app = document.getElementById("app");
let main;

// ---------- DOM helpers ----------

function h(tag, attrs = {}, ...children) {
  const el = document.createElement(tag);
  setAttrs(el, attrs);
  for (const c of children.flat(Infinity)) if (c !== null && c !== undefined && c !== false) el.append(c);
  return el;
}

function setAttrs(el, attrs) {
  for (const [k, v] of Object.entries(attrs)) {
    if (v === undefined || v === null || v === false) continue;
    if (k.startsWith("on")) el.addEventListener(k.slice(2), v);
    else if (k === "text") el.textContent = v;
    else if (k === "bg") el.style.background = v;
    else if (k === "width") el.style.width = v;
    else el.setAttribute(k, v === true ? "" : v);
  }
}

const SVGNS = "http://www.w3.org/2000/svg";
function s(tag, attrs = {}, ...children) {
  const el = document.createElementNS(SVGNS, tag);
  for (const [k, v] of Object.entries(attrs)) if (v !== undefined && v !== null) el.setAttribute(k, v);
  for (const c of children.flat()) if (c) el.append(c);
  return el;
}

const ICONS = {
  home: "M3 10.5 12 3l9 7.5V20a1 1 0 0 1-1 1h-5v-6H9v6H4a1 1 0 0 1-1-1z",
  list: "M8 6h13M8 12h13M8 18h13M3.5 6h.01M3.5 12h.01M3.5 18h.01",
  plus: "M12 5v14M5 12h14",
  inbox: "M22 12h-6l-2 3h-4l-2-3H2M5.45 5.11 2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z",
  settings: "M4 21v-7M4 10V3M12 21v-9M12 8V3M20 21v-5M20 12V3M1 14h6M9 8h6M17 16h6",
  left: "M15 18l-6-6 6-6",
  right: "M9 18l6-6-6-6",
  down: "M12 5v14M19 12l-7 7-7-7",
  up: "M12 19V5M5 12l7-7 7 7",
  search: "M11 19a8 8 0 1 0 0-16 8 8 0 0 0 0 16zM21 21l-4.35-4.35",
  zap: "M13 2 3 14h9l-1 8 10-12h-9z",
  spark: "M12 3l1.9 5.1L19 10l-5.1 1.9L12 17l-1.9-5.1L5 10l5.1-1.9z",
  phone: "M8 2h8a2 2 0 0 1 2 2v16a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2zM11 18h2",
  download: "M12 3v12M7 10l5 5 5-5M5 21h14",
  key: "M21 2l-2 2m-7.6 7.6a5.5 5.5 0 1 1-7.78 7.78 5.5 5.5 0 0 1 7.78-7.78zm0 0L15.5 7.5m0 0 3 3L22 7l-3-3m-3.5 3.5L19 4",
  logout: "M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4M16 17l5-5-5-5M21 12H9",
  check: "M20 6 9 17l-5-5",
  card: "M2 7a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2zM2 10h20",
  tag: "M20.59 13.41 13.42 20.58a2 2 0 0 1-2.83 0L2 12V2h10l8.59 8.59a2 2 0 0 1 0 2.82zM7 7h.01",
  trash: "M3 6h18M8 6V4a1 1 0 0 1 1-1h6a1 1 0 0 1 1 1v2M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6",
  edit: "M12 20h9M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4z",
  shield: "M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z",
};

function icon(name) {
  return s("svg", { class: "icon", viewBox: "0 0 24 24", "aria-hidden": "true" }, s("path", { d: ICONS[name] }));
}

function logo() {
  const g = s("linearGradient", { id: "lg", x1: "0", y1: "0", x2: "1", y2: "1" },
    s("stop", { offset: "0", "stop-color": "#ff9a3c" }), s("stop", { offset: ".52", "stop-color": "#ff4f6d" }), s("stop", { offset: "1", "stop-color": "#8b5cf6" }));
  const leaf = (cx, cy, rot) => s("ellipse", { cx, cy, rx: "4", ry: "6.6", transform: `rotate(${rot} ${cx} ${cy})` });
  return s("svg", { viewBox: "0 0 64 64", "aria-hidden": "true" }, s("defs", {}, g), s("rect", { width: "64", height: "64", rx: "18", fill: "url(#lg)" }),
    s("g", { fill: "#fff" }, s("path", { d: "M32 50V22", stroke: "#fff", "stroke-width": "3.5", "stroke-linecap": "round" }),
      s("ellipse", { cx: "32", cy: "16", rx: "4.2", ry: "7" }), leaf(25, 27, -38), leaf(39, 27, 38), leaf(25, 38, -38), leaf(39, 38, 38)));
}

function toast(text) {
  const el = document.getElementById("toast");
  el.textContent = text;
  el.hidden = false;
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => (el.hidden = true), 2600);
}

// ---------- API ----------

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

// ---------- dates and data ----------

function monthOf(d) {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}`;
}
const localMonth = (iso) => monthOf(new Date(iso));
function shiftMonth(ym, delta) {
  const [y, m] = ym.split("-").map(Number);
  return monthOf(new Date(y, m - 1 + delta, 1));
}
const monthDate = (ym) => new Date(`${ym}-15T12:00:00`);
const fmtMonthName = (ym) => new Intl.DateTimeFormat(region, { month: "long" }).format(monthDate(ym));
const fmtMonth = (ym) => {
  const d = monthDate(ym);
  const name = new Intl.DateTimeFormat(region, { month: "short" }).format(d).replace(".", "");
  return `${name.charAt(0).toUpperCase()}${name.slice(1)} ${d.getFullYear()}`;
};
const fmtDateTime = (ms) => new Intl.DateTimeFormat(region, { dateStyle: "medium", timeStyle: "short" }).format(new Date(ms));
const fmtPct = (x) => new Intl.NumberFormat(region, { style: "percent", maximumFractionDigits: 0 }).format(x);
function dateInputValue(iso) {
  const d = new Date(iso);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}
function dayLabel(iso) {
  const d = new Date(iso);
  const key = dateInputValue(iso);
  const today = new Date();
  if (key === dateInputValue(today.toISOString())) return t("month.today");
  if (key === dateInputValue(new Date(today.getTime() - 864e5).toISOString())) return t("month.yesterday");
  return new Intl.DateTimeFormat(region, { weekday: "short", day: "numeric", month: "short" }).format(d);
}
const money = (minor, cur) => formatMoney(minor, cur, region);

const live = (map) => [...map.values()].filter((r) => !r.deleted);
const liveTx = () => live(state.transactions);

// ---------- decision model and recurring expenses (public/insights.js) ----------

let insightsCache = null;

/** Model, calibration and recurring list, rebuilt only when the data changes. */
function insights() {
  if (insightsCache) return insightsCache;
  const txs = [...state.transactions.values()];
  const active = new Set(live(state.categories).map((c) => c.id));
  insightsCache = {
    model: trainCategoryModel(txs, active),
    calibration: calibrate(txs, active),
    recurring: detectRecurring(txs, new Date()),
    stats: liveStats(txs),
  };
  return insightsCache;
}

/** The model's answer for a payment: band, best category and the categories ranked by probability. */
function categoryDecision(tx) {
  const { model, calibration } = insights();
  const d = decide(model, calibration, tx);
  const ranked = d.ranked.map((r) => state.categories.get(r.id)).filter((c) => c && !c.deleted);
  const best = d.band === "ask" ? null : (state.categories.get(d.categoryId) ?? null);
  return { ...d, best: best && !best.deleted ? best : null, rankedCategories: ranked };
}

function suggestCategory(merchant) {
  return categoryDecision({ merchant, card: null, amount_minor: null, currency: null }).best;
}

/** How a category was set: kept automatic only if it did not change; a changed automatic one is a correction. */
function categoryAutoAfter(tx, newCategory) {
  if ((tx.category_auto ?? 0) === 1) return tx.category_id === newCategory ? 1 : 2;
  return tx.category_auto ?? 0;
}

const needsReview = (tx) => !tx.deleted && (tx.needs_review || (tx.kind === "expense" && !tx.category_id));

// ---------- category look ----------

// Suggested categories, same keys and ids (`default-<key>`) on the web, the iPhone and the server.
// The first seven are on by default (PRD); the rest are suggestions the person can add.
export const CATALOG = [
  ["food", "🍽️", "#ff8a4c", "#ff5f6d", true],
  ["groceries", "🛒", "#22c58b", "#0ea5a4", true],
  ["transport", "🚗", "#4c8dff", "#6a5cff", true],
  ["home", "🏠", "#a77bff", "#d061ff", true],
  ["health", "💊", "#ff5c8a", "#ff3f5f", true],
  ["entertainment", "🎬", "#ffc23d", "#ff8f3d", true],
  ["other", "📦", "#8e97a8", "#5f6779", true],
  ["coffee", "☕", "#c08457", "#8a5a3b", false],
  ["utilities", "💡", "#facc15", "#f59e0b", false],
  ["subscriptions", "🔁", "#38bdf8", "#6366f1", false],
  ["clothing", "👕", "#f472b6", "#db2777", false],
  ["pets", "🐶", "#fb923c", "#ea580c", false],
  ["education", "📚", "#60a5fa", "#2563eb", false],
  ["travel", "✈️", "#22d3ee", "#0891b2", false],
  ["gifts", "🎁", "#f87171", "#dc2626", false],
  ["personal", "💇", "#e879f9", "#a855f7", false],
  ["kids", "🧸", "#fbbf24", "#d97706", false],
  ["sports", "🏋️", "#4ade80", "#16a34a", false],
  ["salary", "💼", "#34d399", "#059669", false],
].map(([key, glyph, from, to, on]) => ({ key, glyph, from, to, on }));
const CATALOG_BY_KEY = Object.fromEntries(CATALOG.map((c) => [c.key, c]));
const PALETTE = [["#14b8a6", "#0891b2"], ["#f97316", "#ef4444"], ["#6366f1", "#a855f7"], ["#ec4899", "#f43f5e"], ["#84cc16", "#16a34a"], ["#0ea5e9", "#2563eb"], ["#eab308", "#f97316"]];
export const COLORS = ["#ff5f6d", "#ff8a4c", "#f59e0b", "#eab308", "#22c58b", "#14b8a6", "#0ea5e9", "#4c8dff", "#6366f1", "#a855f7", "#ec4899", "#8e97a8"];
export const EMOJIS = ["🍽️", "🛒", "🚗", "🏠", "💊", "🎬", "📦", "☕", "🍔", "🍕", "🍺", "⛽", "🚌", "🅿️", "💡", "📱", "🔁", "👕", "👟", "🐶", "📚", "✈️", "🏖️", "🎁", "💇", "🧸", "🏋️", "⚽", "🎮", "🎵", "💻", "🔧", "🏥", "🦷", "💼", "💰", "🏦", "❤️", "⛪", "🌱"];

function categoryName(c) {
  if (!c) return t("categories.uncategorized");
  return c.name || t(`categories.default.${c.key}`);
}

/** Darker shade of a #rrggbb color, for the tile gradient. */
function shade(hex, f = 0.72) {
  const n = parseInt(hex.slice(1), 16);
  const c = (v) => Math.round(v * f).toString(16).padStart(2, "0");
  return `#${c(n >> 16)}${c((n >> 8) & 255)}${c(n & 255)}`;
}

function look(c) {
  if (!c) return { glyph: "?", from: "#9aa1b4", to: "#6b7389" };
  const base = c.key && CATALOG_BY_KEY[c.key];
  let from, to;
  if (c.color) [from, to] = [c.color, shade(c.color)];
  else if (base) [from, to] = [base.from, base.to];
  else {
    let n = 0;
    for (const ch of c.id) n = (n * 31 + ch.charCodeAt(0)) >>> 0;
    [from, to] = PALETTE[n % PALETTE.length];
  }
  const glyph = c.icon || base?.glyph || (categoryName(c).trim()[0] ?? "?").toUpperCase();
  return { glyph, from, to };
}

function tile(c, cls = "tile") {
  const l = look(c);
  return h("span", { class: cls, bg: `linear-gradient(135deg, ${l.from}, ${l.to})`, "aria-hidden": "true", text: l.glyph });
}

function txTile(tx) {
  if (tx.kind === "income" && !tx.category_id) {
    return h("span", { class: "tile", bg: "linear-gradient(135deg, #34e0a1, #0fb57a)", "aria-hidden": "true" }, icon("down"));
  }
  return tile(state.categories.get(tx.category_id));
}

// ---------- data sync ----------

function applyRecords(records) {
  for (const [entity, rows] of Object.entries(records)) for (const r of rows) state[entity].set(r.id, r);
  insightsCache = null;
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

// ---------- shell ----------

const NAV = [
  ["#/", "home", "nav.month"],
  ["#/movimientos", "list", "nav.movements"],
  ["#/nuevo", "plus", "nav.add"],
  ["#/revisar", "inbox", "nav.review"],
  ["#/ajustes", "settings", "nav.settings"],
];

function shell() {
  const pending = liveTx().filter(needsReview).length;
  const badge = (href) => (href === "#/revisar" && pending ? h("span", { class: "dot num", text: String(pending) }) : null);
  const side = h(
    "nav",
    { class: "side", "aria-label": t("app.name") },
    h("div", { class: "logo" }, logo(), t("app.name")),
    NAV.filter(([href]) => href !== "#/nuevo").map(([href, ic, key]) => h("a", { href }, icon(ic), t(key), badge(href))),
    h("a", { href: "#/nuevo", class: "cta" }, icon("plus"), t("nav.add")),
  );
  const bar = h(
    "nav",
    { class: "tabbar", "aria-label": t("app.name") },
    NAV.map(([href, ic, key]) =>
      href === "#/nuevo"
        ? h("a", { href, "aria-label": t(key) }, h("span", { class: "fab" }, icon("plus")))
        : h("a", { href }, icon(ic), t(key), badge(href)),
    ),
  );
  main = h("main", { id: "main" });
  app.replaceChildren(h("div", { class: "shell" }, side, main), bar);
}

function markNav() {
  const hash = location.hash || "#/";
  const base = hash.startsWith("#/editar") ? "#/movimientos" : hash;
  for (const a of document.querySelectorAll(".side a, .tabbar a")) {
    if (a.getAttribute("href") === base) a.setAttribute("aria-current", "page");
    else a.removeAttribute("aria-current");
  }
}

function render(...content) {
  main.replaceChildren(h("div", { class: "fade-in" }, ...content));
  markNav();
  window.scrollTo(0, 0);
}

// ---------- auth screens ----------

function authScreen(...content) {
  app.replaceChildren(h("div", { class: "auth" }, h("div", { class: "auth-card fade-in" }, h("div", { class: "logo" }, logo(), t("app.name")), ...content)));
}

function features() {
  const f = (emoji, from, to, key) => h("div", {}, h("span", { class: "tile", bg: `linear-gradient(135deg, ${from}, ${to})`, text: emoji }), t(key));
  return h(
    "div",
    { class: "feature-list" },
    f("⚡", "#ffb547", "#ff7a45", "setup.features.applePay"),
    f("₡", "#22c58b", "#0ea5a4", "setup.features.currencies"),
    f("🔒", "#8b5cf6", "#6366f1", "setup.features.private"),
  );
}

function passkeySignup(body = {}) {
  return guarded(async () => {
    if (!supported()) throw new Error("passkey_unsupported");
    const { challengeId, options } = await api("/api/auth/register/options", { method: "POST", body });
    const response = await createPasskey(options);
    await api("/api/auth/register/verify", { method: "POST", body: { ...body, challengeId, response } });
    await boot();
  });
}

/** First person on a closed instance: the setup token creates the account. */
function viewSetup() {
  const token = h("input", { class: "input", name: "token", autocomplete: "one-time-code", required: true, placeholder: t("setup.token"), "aria-label": t("setup.token") });
  authScreen(
    h("h1", { text: t("setup.title") }),
    h("p", { text: t("setup.intro") }),
    features(),
    h(
      "form",
      {
        onsubmit: (e) => {
          e.preventDefault();
          passkeySignup({ setupToken: token.value });
        },
      },
      token,
      h("button", { class: "btn primary" }, icon("key"), t("setup.create")),
    ),
  );
}

/** Sign in with a passkey, create an account (open sign-up) or use a code shown on the iPhone. */
function viewLogin(session) {
  const code = h("input", { class: "input", name: "code", autocomplete: "one-time-code", placeholder: t("login.codePlaceholder"), "aria-label": t("login.codePlaceholder") });
  authScreen(
    h("h1", { text: t("login.title") }),
    h("p", { text: t("login.subtitle") }),
    features(),
    h(
      "button",
      {
        class: "btn primary",
        onclick: () =>
          guarded(async () => {
            if (!supported()) throw new Error("passkey_unsupported");
            const { challengeId, options } = await api("/api/auth/login/options", { method: "POST", body: {} });
            const response = await getPasskey(options);
            await api("/api/auth/login/verify", { method: "POST", body: { challengeId, response } });
            await boot();
          }),
      },
      icon("key"),
      t("login.button"),
    ),
    session.signup === "open" ? h("button", { class: "btn block", onclick: () => passkeySignup() }, icon("plus"), t("login.signup")) : null,
    h("p", { class: "muted", text: t("login.codeHelp") }),
    h(
      "form",
      {
        class: "inline-form",
        onsubmit: (e) => {
          e.preventDefault();
          guarded(async () => {
            await api("/api/auth/web-code/redeem", { method: "POST", body: { code: code.value } });
            await boot();
          });
        },
      },
      code,
      h("button", { class: "btn" }, t("login.codeButton")),
    ),
  );
}

// ---------- summary ----------

function monthTx(ym) {
  return liveTx().filter((tx) => localMonth(tx.occurred_at) === ym);
}

function usedCurrencies() {
  const set = new Set(liveTx().map((tx) => tx.currency));
  return CURRENCIES.filter((c) => set.has(c)).concat([...set].filter((c) => !CURRENCIES.includes(c)));
}

function pickCurrency() {
  const used = usedCurrencies();
  if (state.currency && (used.includes(state.currency) || !used.length)) return state.currency;
  const spent = {};
  for (const tx of monthTx(state.month)) if (tx.kind === "expense") spent[tx.currency] = (spent[tx.currency] ?? 0) + 1;
  return Object.entries(spent).sort((a, b) => b[1] - a[1])[0]?.[0] ?? used[0] ?? "CRC";
}

/** Cumulative daily spending for a month, as an array indexed by day (0 = day 1). */
function cumulative(ym, cur) {
  const [y, m] = ym.split("-").map(Number);
  const days = new Date(y, m, 0).getDate();
  const perDay = new Array(days).fill(0);
  for (const tx of monthTx(ym)) if (tx.kind === "expense" && tx.currency === cur) perDay[new Date(tx.occurred_at).getDate() - 1] += tx.amount_minor;
  let acc = 0;
  return perDay.map((v) => (acc += v));
}

function paceChart(ym, cur) {
  const curr = cumulative(ym, cur);
  const prev = cumulative(shiftMonth(ym, -1), cur);
  const now = new Date();
  const isThis = ym === monthOf(now);
  const upto = isThis ? now.getDate() : curr.length;
  const W = 340, H = 140, P = 6;
  const max = Math.max(1, ...curr.slice(0, upto), ...prev) * 1.08;
  const days = Math.max(curr.length, prev.length);
  const x = (i) => P + (i / (days - 1)) * (W - 2 * P);
  const y = (v) => H - 18 - (v / max) * (H - 30);
  const path = (arr, n) => arr.slice(0, n).map((v, i) => `${i ? "L" : "M"}${x(i).toFixed(1)},${y(v).toFixed(1)}`).join(" ");
  const curPath = path(curr, upto);
  const lastX = x(upto - 1), lastY = y(curr[upto - 1] ?? 0);
  const grid = [0.25, 0.5, 0.75].map((f) => s("line", { class: "grid-line", x1: 0, x2: W, y1: y(max * f / 1.08), y2: y(max * f / 1.08) }));
  const label = (i, anchor) => s("text", { x: x(i), y: H - 2, "text-anchor": anchor }, document.createTextNode(String(i + 1)));
  return s(
    "svg",
    { class: "chart", viewBox: `0 0 ${W} ${H}`, role: "img", "aria-label": t("month.pace") },
    s("defs", {},
      s("linearGradient", { id: "hgrad", x1: "0", x2: "1" }, s("stop", { offset: "0", "stop-color": "#ff9a3c" }), s("stop", { offset: ".6", "stop-color": "#ff4f6d" }), s("stop", { offset: "1", "stop-color": "#8b5cf6" })),
      s("linearGradient", { id: "harea", x1: "0", x2: "0", y1: "0", y2: "1" }, s("stop", { offset: "0", "stop-color": "#ff4f6d", "stop-opacity": ".28" }), s("stop", { offset: "1", "stop-color": "#ff4f6d", "stop-opacity": "0" })),
    ),
    grid,
    s("path", { class: "prev", d: path(prev, prev.length) }),
    s("path", { class: "area", d: `${curPath} L${lastX.toFixed(1)},${H - 18} L${x(0)},${H - 18} Z` }),
    s("path", { class: "cur", d: curPath }),
    s("circle", { class: "today", cx: lastX, cy: lastY, r: 5 }),
    label(0, "start"),
    label(Math.floor((days - 1) / 2), "middle"),
    label(days - 1, "end"),
  );
}

function donut(parts, total) {
  const R = 52, C = 2 * Math.PI * R;
  let offset = 0;
  const arcs = parts.map(({ value, color }) => {
    const len = (value / total) * C;
    const gap = parts.length > 1 ? Math.min(3, len / 3) : 0;
    const el = s("circle", { cx: 66, cy: 66, r: R, stroke: color, "stroke-dasharray": `${Math.max(0, len - gap)} ${C}`, "stroke-dashoffset": -offset, "stroke-linecap": "butt" });
    offset += len;
    return el;
  });
  return s("svg", { class: "donut", viewBox: "0 0 132 132", "aria-hidden": "true" }, s("circle", { class: "track", cx: 66, cy: 66, r: R }), arcs);
}

function viewMonth() {
  const cur = pickCurrency();
  state.currency = cur;
  const txs = monthTx(state.month);
  const sum = (list, kind) => list.filter((tx) => tx.kind === kind && tx.currency === cur).reduce((a, tx) => a + tx.amount_minor, 0);
  const spent = sum(txs, "expense");
  const earned = sum(txs, "income");

  // Same point of the previous month: up to today's day number when looking at the current month.
  const now = new Date();
  const prevYm = shiftMonth(state.month, -1);
  const isThis = state.month === monthOf(now);
  const prevCum = cumulative(prevYm, cur);
  const prevAt = isThis ? prevCum[Math.min(now.getDate(), prevCum.length) - 1] : prevCum[prevCum.length - 1];
  let vs;
  if (!prevAt) vs = h("span", { class: "pill" }, icon("spark"), t("month.vsNone"));
  else {
    const diff = (spent - prevAt) / prevAt;
    const vars = { pct: fmtPct(Math.abs(diff)), month: fmtMonthName(prevYm) };
    vs = Math.abs(diff) < 0.005
      ? h("span", { class: "pill" }, t("month.vsSame", vars))
      : h("span", { class: "pill" }, icon(diff < 0 ? "down" : "up"), t(diff < 0 ? "month.vsLess" : "month.vsMore", vars));
  }

  const currencies = usedCurrencies();
  const curToggle =
    currencies.length > 1
      ? h(
          "span",
          { class: "cur-toggle", role: "group", "aria-label": t("month.currency") },
          currencies.map((c) => h("button", { "aria-pressed": String(c === cur), text: c, onclick: () => ((state.currency = c), viewMonth()) })),
        )
      : null;

  const projection = isThis ? projectMonth(liveTx(), insights().recurring, cur, now) : null;
  const hero = h(
    "section",
    { class: "card hero" },
    h("div", { class: "label" }, h("span", { text: t("month.spentIn", { month: fmtMonthName(state.month) }) }), curToggle),
    h("div", { class: "big num", text: money(spent, cur) }),
    vs,
    projection ? h("p", { class: "projection num", text: t("month.projection", { amount: money(projection.projected, cur) }) }) : null,
    h(
      "div",
      { class: "hero-stats" },
      h("div", { class: "hero-stat" }, h("span", { text: t("month.income") }), h("b", { class: "num", text: money(earned, cur) })),
      h("div", { class: "hero-stat" }, h("span", { text: t("month.balance") }), h("b", { class: "num", text: money(earned - spent, cur) })),
    ),
  );

  const pending = liveTx().filter(needsReview);
  const inbox = pending.length
    ? h(
        "a",
        { class: "inbox", href: "#/revisar" },
        h("span", { class: "tile" }, icon("inbox")),
        h("div", {}, h("b", { text: t("month.reviewTitle", { count: pending.length }) }), h("span", { text: t("month.reviewSub") })),
        h("span", { class: "go" }, icon("right")),
      )
    : null;

  const chart = h(
    "section",
    { class: "card" },
    h("div", { class: "card-head" }, h("h2", { text: t("month.pace") })),
    paceChart(state.month, cur),
    h("div", { class: "legend" }, h("span", {}, h("i"), t("month.thisMonth")), h("span", {}, h("i", { class: "prev" }), t("month.lastMonth"))),
  );

  // Categories
  const byCat = new Map();
  for (const tx of txs) if (tx.kind === "expense" && tx.currency === cur) byCat.set(tx.category_id ?? "", (byCat.get(tx.category_id ?? "") ?? 0) + tx.amount_minor);
  const cats = [...byCat.entries()].sort((a, b) => b[1] - a[1]);
  const catCard = h(
    "section",
    { class: "card" },
    h("div", { class: "card-head" }, h("h2", { text: t("month.byCategory") })),
    cats.length
      ? [
          h(
            "div",
            { class: "donut-wrap" },
            donut(cats.map(([id, v]) => ({ value: v, color: look(state.categories.get(id)).from })), spent || 1),
            h("div", { class: "donut-center" }, h("span", { text: t("month.spentIn", { month: fmtMonthName(state.month) }) }), h("b", { class: "num", text: money(spent, cur) })),
          ),
          cats.map(([id, v]) => {
            const c = state.categories.get(id);
            const l = look(c);
            return h(
              "div",
              { class: "cat-row" },
              tile(c, "tile sm"),
              h("div", {}, h("div", { class: "name", text: categoryName(c) }), h("div", { class: "bar" }, h("i", { width: `${Math.max(2, (v / spent) * 100)}%`, bg: `linear-gradient(90deg, ${l.from}, ${l.to})` }))),
              h("div", {}, h("div", { class: "name num", text: money(v, cur) }), h("div", { class: "sub num", text: t("month.ofTotal", { pct: fmtPct(v / spent) }) })),
            );
          }),
        ]
      : h("div", { class: "empty" }, h("span", { class: "big-emoji", text: "🌾" }), h("b", { text: t("month.emptyTitle") }), t("month.empty")),
  );

  const recent = [...txs].sort((a, b) => b.occurred_at.localeCompare(a.occurred_at)).slice(0, 8);
  const recentCard = recent.length
    ? h("section", { class: "card span" }, h("div", { class: "card-head" }, h("h2", { text: t("month.recent") }), h("a", { href: "#/movimientos", text: t("month.seeAll") })), txGroups(recent))
    : null;

  render(
    h(
      "div",
      { class: "page-head" },
      h("div", {}, h("p", { class: "eyebrow", text: greeting() }), h("h1", { text: t("month.title") })),
      h(
        "div",
        { class: "month-switch" },
        h("button", { class: "icon-btn", "aria-label": t("month.previous"), onclick: () => ((state.month = shiftMonth(state.month, -1)), viewMonth()) }, icon("left")),
        h("strong", { text: fmtMonth(state.month) }),
        h("button", { class: "icon-btn", "aria-label": t("month.next"), onclick: () => ((state.month = shiftMonth(state.month, 1)), viewMonth()) }, icon("right")),
      ),
    ),
    h("div", { class: "grid dash" }, startCard(), h("div", { class: "grid" }, hero, inbox, chart), h("div", { class: "grid" }, fixedCard(cur), catCard), recentCard),
  );
}

function dismissed(key) {
  try {
    return localStorage.getItem(key) === "1";
  } catch {
    return false;
  }
}

/** Three-step start list for a new installation; disappears when done or dismissed. */
function startCard() {
  const steps = [
    ["categories", live(state.categories).some((c) => c.updated_at > 0) || state.categories.size > 7, "#/ajustes"],
    ["link", state.devices.length > 0, "#/ajustes"],
    ["capture", liveTx().some((tx) => tx.source === "apple_pay"), null],
    ["first", liveTx().length > 0, "#/nuevo"],
  ];
  if (steps.every(([, done]) => done) || dismissed("harina.start.hidden")) return null;
  const doneCount = steps.filter(([, done]) => done).length;
  return h(
    "section",
    { class: "card span start" },
    h("div", { class: "card-head" },
      h("div", {}, h("h2", { text: t("start.title") }), h("p", { class: "eyebrow num", text: t("start.progress", { done: doneCount, total: steps.length }) })),
      h("button", {
        class: "link-btn",
        text: t("start.hide"),
        onclick: () => {
          try {
            localStorage.setItem("harina.start.hidden", "1");
          } catch {
            // private mode: hide for this visit only
          }
          viewMonth();
        },
      }),
    ),
    h("div", { class: "bar" }, h("i", { width: `${(doneCount / steps.length) * 100}%`, bg: "linear-gradient(90deg, #ff9a3c, #ff4f6d, #8b5cf6)" })),
    h(
      "ol",
      { class: "steps" },
      steps.map(([key, done, href], i) =>
        h(
          "li",
          { class: done ? "done" : "" },
          h("span", { class: "step-dot" }, done ? icon("check") : String(i + 1)),
          h("div", { class: "grow" }, h("b", { text: t(`start.${key}.title`) }), h("span", { text: t(`start.${key}.text`) })),
          !done && href ? h("a", { class: "btn", href, text: t(`start.${key}.cta`) }) : null,
        ),
      ),
    ),
  );
}

function greeting() {
  const hr = new Date().getHours();
  return t(hr < 12 ? "app.greeting.morning" : hr < 19 ? "app.greeting.afternoon" : "app.greeting.evening");
}

// ---------- recurring expenses ----------

const CADENCE_KEY = { weekly: "fixed.weekly", monthly: "fixed.monthly", yearly: "fixed.yearly" };

function whenLabel(r) {
  if (r.status === "missed") return t("fixed.missed", { date: new Intl.DateTimeFormat(region, { day: "numeric", month: "short" }).format(new Date(r.next)) });
  if (r.daysToNext <= 0) return t("fixed.today");
  if (r.daysToNext === 1) return t("fixed.tomorrow");
  if (r.daysToNext <= 7) return t("fixed.inDays", { days: r.daysToNext });
  return t("fixed.on", { date: new Intl.DateTimeFormat(region, { day: "numeric", month: "short" }).format(new Date(r.next)) });
}

function fixedRow(r) {
  const c = state.categories.get(r.categoryId);
  return h(
    "div",
    { class: "tx fixed-row" },
    tile(c && !c.deleted ? c : null),
    h(
      "div",
      { class: "who" },
      h("b", { text: r.merchant }),
      h("span", {},
        h("span", { class: `when ${r.status}`, text: whenLabel(r) }),
        ` · ${t(CADENCE_KEY[r.cadence])}`,
        r.confidence === "likely" ? ` · ${t("fixed.likely")}` : "",
      ),
    ),
    h(
      "div",
      { class: "amt num" },
      money(r.amount, r.currency),
      r.priceChange ? h("small", { class: "up", text: t("fixed.priceUp", { from: money(r.priceChange.from, r.currency) }) }) : null,
    ),
  );
}

/** Dashboard card: fixed charges of the month in the hero currency and the next ones due. */
function fixedCard(cur) {
  const rec = insights().recurring.filter((r) => r.currency === cur);
  if (!rec.length) return null;
  const monthly = rec.reduce((a, r) => a + r.monthly, 0);
  const upcoming = rec.filter((r) => r.status !== "scheduled").slice(0, 4);
  return h(
    "section",
    { class: "card" },
    h("div", { class: "card-head" }, h("h2", { text: t("fixed.title") }), h("a", { href: "#/fijos", text: t("month.seeAll") })),
    h("p", { class: "fixed-total" }, h("b", { class: "num", text: money(monthly, cur) }), h("span", { text: t("fixed.perMonth", { count: rec.length }) })),
    (upcoming.length ? upcoming : rec.slice(0, 3)).map(fixedRow),
  );
}

function viewFixed() {
  const rec = insights().recurring;
  const totals = {};
  for (const r of rec) totals[r.currency] = (totals[r.currency] ?? 0) + r.monthly;
  const section = (title, list) => (list.length ? h("section", { class: "card" }, h("div", { class: "card-head" }, h("h2", { text: title })), list.map(fixedRow)) : null);
  render(
    h("div", { class: "page-head" }, h("div", {}, h("p", { class: "eyebrow", text: t("fixed.subtitle") }), h("h1", { text: t("fixed.title") }))),
    rec.length
      ? [
          h(
            "div",
            { class: "grid two-up" },
            Object.entries(totals).map(([cur, v]) =>
              h("section", { class: "card stat" }, h("span", { text: t("fixed.monthlyTotal", { currency: cur }) }), h("b", { class: "num", text: money(v, cur) }), h("small", { class: "num", text: t("fixed.yearlyTotal", { amount: money(v * 12, cur) }) })),
            ),
          ),
          h(
            "div",
            { class: "grid" },
            section(t("fixed.attention"), rec.filter((r) => r.status === "missed" || r.priceChange)),
            section(t("fixed.upcoming"), rec.filter((r) => r.status !== "missed" && !r.priceChange)),
          ),
          h("p", { class: "eyebrow", text: t("fixed.how") }),
        ]
      : h("section", { class: "card empty" }, h("span", { class: "big-emoji", text: "🔁" }), h("b", { text: t("fixed.emptyTitle") }), t("fixed.empty")),
  );
}

// ---------- movements ----------

function txRow(tx) {
  const c = state.categories.get(tx.category_id);
  const acc = state.accounts.get(tx.account_id);
  const sub = [categoryName(c), acc && !acc.deleted ? acc.name : null].filter(Boolean).join(" · ");
  const amount = tx.needs_review && tx.raw_amount && !tx.amount_minor
    ? h("div", { class: "amt" }, h("small", { text: t("review.fixAmount") }), tx.raw_amount)
    : h("div", { class: `amt num ${tx.kind === "income" ? "in" : ""}`, text: `${tx.kind === "income" ? "+" : ""}${money(tx.amount_minor, tx.currency)}` });
  return h(
    "a",
    { class: "tx", href: `#/editar/${tx.id}` },
    txTile(tx),
    h("div", { class: "who" }, h("b", { text: tx.merchant || tx.note || categoryName(c) }),
      h("span", {}, tx.source === "apple_pay" ? icon("zap") : null, tx.category_auto === 1 ? h("i", { class: "auto", title: t("auto.mark"), "aria-label": t("auto.mark") }, icon("spark")) : null, sub)),
    amount,
  );
}

function txGroups(txs) {
  const groups = new Map();
  for (const tx of txs) {
    const k = dateInputValue(tx.occurred_at);
    if (!groups.has(k)) groups.set(k, []);
    groups.get(k).push(tx);
  }
  return [...groups.values()].map((list) => {
    const totals = {};
    for (const tx of list) if (tx.kind === "expense") totals[tx.currency] = (totals[tx.currency] ?? 0) + tx.amount_minor;
    return h(
      "div",
      {},
      h("div", { class: "day" }, h("span", { text: dayLabel(list[0].occurred_at) }), h("span", { class: "num", text: Object.entries(totals).map(([c, v]) => money(v, c)).join(" · ") })),
      list.map(txRow),
    );
  });
}

function viewMovements() {
  const filters = [
    ["all", "movements.all"],
    ["expense", "movements.expenses"],
    ["income", "movements.incomes"],
    ["apple_pay", "movements.applePay"],
  ];
  const listBox = h("div");
  const draw = () => {
    const q = merchantKey(state.query);
    const txs = liveTx()
      .filter((tx) => state.filter === "all" || tx.kind === state.filter || tx.source === state.filter)
      .filter((tx) => !q || merchantKey(`${tx.merchant ?? ""} ${tx.note ?? ""} ${categoryName(state.categories.get(tx.category_id))}`).includes(q))
      .sort((a, b) => b.occurred_at.localeCompare(a.occurred_at));
    listBox.replaceChildren(
      txs.length
        ? h("section", { class: "card" }, h("p", { class: "eyebrow num", text: t("movements.count", { count: txs.length }) }), txGroups(txs.slice(0, 300)))
        : h("div", { class: "card empty" }, h("span", { class: "big-emoji", text: "🔎" }), t("movements.empty")),
    );
  };
  const search = h("input", {
    type: "search",
    value: state.query,
    placeholder: t("movements.search"),
    "aria-label": t("movements.search"),
    oninput: (e) => ((state.query = e.target.value), draw()),
  });
  const chips = h(
    "div",
    { class: "chips", role: "group" },
    filters.map(([f, key]) =>
      h("button", {
        class: "chip",
        "aria-pressed": String(state.filter === f),
        text: t(key),
        onclick: (e) => {
          state.filter = f;
          for (const b of e.target.parentNode.children) b.setAttribute("aria-pressed", String(b === e.target));
          draw();
        },
      }),
    ),
  );
  draw();
  render(h("div", { class: "page-head" }, h("h1", { text: t("movements.title") })), h("label", { class: "search" }, icon("search"), search), chips, listBox);
}

// ---------- composer ----------

function viewForm(existing) {
  const tx = existing ?? { id: crypto.randomUUID(), kind: "expense", currency: state.currency || "CRC", source: "manual", occurred_at: new Date().toISOString() };
  const st = { kind: tx.kind, currency: tx.currency, category: tx.category_id ?? null, account: tx.account_id ?? null };

  const amount = h("input", {
    class: "amount-input num",
    inputmode: "decimal",
    autocomplete: "off",
    placeholder: t("form.amountPlaceholder"),
    value: existing && !(tx.needs_review && !tx.amount_minor) ? minorToInput(tx.amount_minor, tx.currency, region) : "",
    "aria-label": t("form.amount"),
  });
  const curBtn = h("button", {
    type: "button",
    class: "cur",
    text: st.currency,
    title: t("form.tapToChange"),
    "aria-label": t("form.currency"),
    onclick: () => {
      st.currency = CURRENCIES[(CURRENCIES.indexOf(st.currency) + 1) % CURRENCIES.length];
      curBtn.textContent = st.currency;
    },
  });
  const kindBtns = ["expense", "income"].map((k) =>
    h("button", {
      type: "button",
      class: k === "expense" ? "exp" : "inc",
      "aria-pressed": String(st.kind === k),
      text: t(`form.${k}`),
      onclick: () => {
        st.kind = k;
        for (const b of kindBtns) b.setAttribute("aria-pressed", String(b.textContent === t(`form.${k}`)));
        saveBtn.lastChild.textContent = t(k === "income" ? "form.saveIncome" : "form.saveExpense");
      },
    }),
  );
  const merchant = h("input", { class: "input", value: tx.merchant ?? "", autocomplete: "off", "aria-label": t("form.merchant") });
  const note = h("input", { class: "input", value: tx.note ?? "", "aria-label": t("form.note") });
  const date = h("input", { class: "input", type: "date", value: dateInputValue(tx.occurred_at), required: true, "aria-label": t("form.date") });

  const catGrid = h("div", { class: "cat-grid", role: "group", "aria-label": t("form.category") });
  const drawCats = () => {
    const sug = !st.category ? suggestCategory(merchant.value) : null;
    const cats = live(state.categories).sort((a, b) => categoryName(a).localeCompare(categoryName(b), region));
    catGrid.replaceChildren(
      ...cats.map((c) =>
        h(
          "button",
          {
            type: "button",
            class: "cat-opt",
            "aria-pressed": String(st.category === c.id),
            onclick: () => {
              st.category = st.category === c.id ? null : c.id;
              drawCats();
            },
          },
          sug?.id === c.id ? h("span", { class: "spark" }, icon("spark"), t("form.suggestedShort")) : null,
          tile(c),
          categoryName(c),
        ),
      ),
    );
  };
  merchant.addEventListener("input", drawCats);
  drawCats();

  const accounts = live(state.accounts);
  const accChips = accounts.length
    ? h(
        "div",
        { class: "chips", role: "group", "aria-label": t("form.account") },
        accounts.map((a) =>
          h(
            "button",
            {
              type: "button",
              class: "chip",
              "aria-pressed": String(st.account === a.id),
              onclick: (e) => {
                st.account = st.account === a.id ? null : a.id;
                for (const b of e.currentTarget.parentNode.children) b.setAttribute("aria-pressed", String(b === e.currentTarget && st.account === a.id));
              },
            },
            icon("card"),
            a.name,
          ),
        ),
      )
    : null;

  const saveBtn = h("button", { class: "btn primary" }, icon("check"), h("span", { text: t(st.kind === "income" ? "form.saveIncome" : "form.saveExpense") }));

  const form = h(
    "form",
    {
      class: "composer",
      onsubmit: (e) => {
        e.preventDefault();
        const minor = parseAmount(amount.value, st.currency);
        if (minor === null) {
          amount.focus();
          return toast(t("form.invalidAmount"));
        }
        const day = date.value.split("-").map(Number);
        const old = new Date(tx.occurred_at);
        const when = new Date(day[0], day[1] - 1, day[2], old.getHours(), old.getMinutes());
        guarded(async () => {
          await save("transactions", {
            ...tx,
            kind: st.kind,
            amount_minor: minor,
            currency: st.currency,
            category_id: st.category,
            category_auto: categoryAutoAfter(tx, st.category),
            account_id: st.account,
            merchant: merchant.value,
            note: note.value,
            needs_review: false,
            occurred_at: when.toISOString(),
          });
          toast(t("form.saved"));
          state.month = monthOf(when);
          state.currency = st.currency;
          if (existing) location.hash = state.back;
          else router();
        });
      },
    },
    h("section", { class: "card" },
      h("div", { class: "seg", role: "group", "aria-label": t("form.kind") }, kindBtns),
      h("div", { class: "amount-box" }, curBtn, amount, tx.raw_amount ? h("p", { class: "eyebrow", text: t("review.rawAmount", { raw: tx.raw_amount }) }) : null),
      h("label", { class: "field" }, h("span", { text: t("form.merchant") }), merchant),
      h("div", { class: "field" }, h("span", { text: t("form.category") }), catGrid),
      accChips ? h("div", { class: "field" }, h("span", { text: t("form.account") }), accChips) : null,
      h("div", { class: "two" }, h("label", { class: "field" }, h("span", { text: t("form.date") }), date), h("label", { class: "field" }, h("span", { text: t("form.note") }), note)),
      h("div", { class: "actions-row" },
        saveBtn,
        existing
          ? h("button", {
              type: "button",
              class: "btn danger ghost",
              onclick: () =>
                confirm(t("form.confirmDelete")) &&
                guarded(async () => {
                  await save("transactions", { ...tx, deleted: true });
                  location.hash = state.back;
                }),
            }, icon("trash"), t("form.delete"))
          : null,
      ),
    ),
  );
  render(h("div", { class: "page-head composer" }, h("h1", { text: t(existing ? "form.titleEdit" : "form.titleNew") })), form);
  if (!existing) amount.focus();
}

// ---------- review ----------

function viewReview() {
  const txs = liveTx()
    .filter(needsReview)
    .sort((a, b) => b.occurred_at.localeCompare(a.occurred_at));
  const cats = live(state.categories).sort((a, b) => categoryName(a).localeCompare(categoryName(b), region));
  const card = (tx) => {
    const d = categoryDecision(tx);
    const sug = !tx.needs_review ? d.best : null;
    // Most likely first (the model's ranking), then the rest alphabetically.
    const options = [...d.rankedCategories, ...cats.filter((c) => !d.rankedCategories.includes(c))];
    return h(
      "section",
      { class: "card review-card" },
      h(
        "a",
        { class: "top", href: `#/editar/${tx.id}` },
        txTile(tx),
        h("div", {}, h("b", { text: tx.merchant || t("categories.uncategorized") }), h("span", { text: [dayLabel(tx.occurred_at), tx.card].filter(Boolean).join(" · ") })),
        tx.needs_review
          ? h("div", { class: "amt", text: tx.raw_amount || "?" })
          : h("div", { class: "amt num", text: money(tx.amount_minor, tx.currency) }),
      ),
      tx.needs_review
        ? h("a", { class: "btn block", href: `#/editar/${tx.id}` }, icon("edit"), t("review.fixAmount"))
        : h(
            "div",
            { class: "chips" },
            options.map((c) =>
              h(
                "button",
                {
                  class: `chip ${sug?.id === c.id ? "suggest" : ""}`,
                  onclick: () =>
                    guarded(async () => {
                      await save("transactions", { ...tx, category_id: c.id, category_auto: categoryAutoAfter(tx, c.id) });
                      toast(t("form.saved"));
                      viewReview();
                      refreshBadge();
                    }),
                },
                sug?.id === c.id ? icon("spark") : h("span", { class: "e", text: look(c).glyph }),
                categoryName(c),
              ),
            ),
          ),
    );
  };
  render(
    h("div", { class: "page-head" }, h("div", {}, h("p", { class: "eyebrow num", text: txs.length ? t("review.left", { count: txs.length }) : "" }), h("h1", { text: t("review.title") }))),
    txs.length
      ? [h("p", { class: "eyebrow", text: t("review.intro") }), h("div", { class: "grid" }, txs.map(card))]
      : h("section", { class: "card empty" }, h("span", { class: "big-emoji", text: "🎉" }), h("b", { text: t("review.emptyTitle") }), t("review.empty")),
  );
}

function refreshBadge() {
  const n = liveTx().filter(needsReview).length;
  for (const a of document.querySelectorAll('a[href="#/revisar"]')) {
    a.querySelector(".dot")?.remove();
    if (n) a.append(h("span", { class: "dot num", text: String(n) }));
  }
}

// ---------- iPhone linking ----------

/** Deep link the iPhone camera opens: the app asks for confirmation before linking. */
function linkUrl(code) {
  return `harina://link?server=${encodeURIComponent(state.origin)}&code=${encodeURIComponent(code)}`;
}

/** QR code drawn as SVG nodes (no innerHTML), dark modules on white with a quiet zone. */
function qrSvg(text) {
  const qr = qrcode(0, "M");
  qr.addData(text);
  qr.make();
  const n = qr.getModuleCount();
  let d = "";
  for (let r = 0; r < n; r++) for (let c = 0; c < n; c++) if (qr.isDark(r, c)) d += `M${c + 4},${r + 4}h1v1h-1z`;
  return s("svg", { class: "qr", viewBox: `0 0 ${n + 8} ${n + 8}`, role: "img", "aria-label": t("devices.scan"), "shape-rendering": "crispEdges" },
    s("rect", { width: n + 8, height: n + 8, fill: "#fff", rx: 2 }), s("path", { d, fill: "#0d1121" }));
}

/** While a code is on screen, refresh when a new iPhone shows up. */
function pollDevices(before, onchange) {
  clearInterval(pollDevices.timer);
  const until = Date.now() + 10 * 60 * 1000;
  pollDevices.timer = setInterval(async () => {
    if (Date.now() > until || location.hash !== "#/ajustes") return clearInterval(pollDevices.timer);
    try {
      const { devices } = await api("/api/devices");
      if (devices.length > before) {
        clearInterval(pollDevices.timer);
        state.devices = devices;
        toast(t("devices.linked"));
        onchange();
      }
    } catch {
      // keep polling; the next tick may succeed
    }
  }, 3000);
}

// ---------- categories ----------

/** Suggestions from the catalog that are not active now. Adding one reuses its shared id. */
function suggestionsBox(onchange) {
  const missing = CATALOG.filter((k) => !live(state.categories).some((c) => c.key === k.key || c.id === `default-${k.key}`));
  if (!missing.length) return null;
  return h(
    "div",
    {},
    h("p", { class: "group-title", text: t("categories.suggestions") }),
    h(
      "div",
      { class: "chips wrap" },
      missing.map((k) =>
        h(
          "button",
          {
            class: "chip",
            onclick: () =>
              guarded(async () => {
                const old = state.categories.get(`default-${k.key}`);
                await save("categories", { ...(old ?? {}), id: `default-${k.key}`, key: k.key, name: null, icon: null, color: null, deleted: false });
                onchange();
              }),
          },
          h("span", { class: "e", text: k.glyph }),
          t(`categories.default.${k.key}`),
          icon("plus"),
        ),
      ),
    ),
  );
}

/** Modal editor: name, emoji and color, with a live preview. `c` null creates a category. */
function editCategory(c, onchange) {
  const draft = { name: c ? categoryName(c) : "", icon: c ? look(c).glyph : "🏷️", color: c?.color ?? (c ? null : COLORS[7]) };
  const preview = h("span", { class: "tile big-tile" });
  const name = h("input", { class: "input", value: draft.name, placeholder: t("categories.newName"), "aria-label": t("categories.newName"), maxlength: "100" });
  const drawPreview = () => {
    const l = look({ ...(c ?? { id: "new" }), icon: draft.icon, color: draft.color, name: name.value || "?" });
    preview.textContent = l.glyph;
    preview.style.background = `linear-gradient(135deg, ${l.from}, ${l.to})`;
  };
  name.addEventListener("input", drawPreview);
  const custom = h("input", { class: "input emoji-input", maxlength: "16", placeholder: t("categories.customEmoji"), "aria-label": t("categories.customEmoji") });
  custom.addEventListener("input", () => {
    if (custom.value.trim()) {
      draft.icon = [...new Intl.Segmenter().segment(custom.value.trim())][0]?.segment ?? draft.icon;
      drawPreview();
    }
  });
  const emojiGrid = h(
    "div",
    { class: "emoji-grid" },
    EMOJIS.map((e) => h("button", { type: "button", class: "emoji-opt", text: e, onclick: () => ((draft.icon = e), drawPreview()) })),
  );
  const swatches = h(
    "div",
    { class: "swatches" },
    COLORS.map((col) =>
      h("button", {
        type: "button",
        class: "swatch",
        bg: col,
        "aria-label": col,
        onclick: (e) => {
          draft.color = col;
          for (const b of swatches.children) b.removeAttribute("aria-pressed");
          e.currentTarget.setAttribute("aria-pressed", "true");
          drawPreview();
        },
      }),
    ),
  );
  const dialog = h(
    "dialog",
    { class: "sheet" },
    h(
      "form",
      {
        method: "dialog",
        onsubmit: (e) => {
          e.preventDefault();
          const value = name.value.trim();
          if (!value) return name.focus();
          const keepDefaultName = c?.key && !c.name && value === categoryName(c);
          guarded(async () => {
            await save("categories", { ...(c ?? { id: crypto.randomUUID() }), name: keepDefaultName ? null : value, icon: draft.icon, color: draft.color, deleted: false });
            dialog.close();
            onchange();
          });
        },
      },
      h("div", { class: "sheet-head" }, preview, h("h2", { text: t(c ? "categories.edit" : "categories.add") })),
      h("label", { class: "field" }, h("span", { text: t("categories.newName") }), name),
      h("div", { class: "field" }, h("span", { text: t("categories.emoji") }), emojiGrid, custom),
      h("div", { class: "field" }, h("span", { text: t("categories.color") }), swatches),
      h(
        "div",
        { class: "actions-row" },
        h("button", { class: "btn primary" }, icon("check"), t("form.save")),
        c
          ? h("button", {
              type: "button",
              class: "btn danger ghost",
              onclick: () =>
                confirm(t("categories.confirmDelete", { name: categoryName(c) })) &&
                guarded(async () => {
                  await save("categories", { ...c, deleted: true });
                  dialog.close();
                  onchange();
                }),
            }, icon("trash"), t("form.delete"))
          : null,
        h("button", { type: "button", class: "btn ghost", text: t("app.cancel"), onclick: () => dialog.close() }),
      ),
    ),
  );
  dialog.addEventListener("close", () => dialog.remove());
  document.body.append(dialog);
  drawPreview();
  dialog.showModal();
  if (!c) name.focus();
}

/** Assistants connected over MCP: address to add, list with permissions, revoke. */
function connectionsGroup(connections, onchange) {
  const mcpUrl = `${state.origin}/mcp`;
  const fmt = (ms) => new Intl.DateTimeFormat(region, { dateStyle: "medium" }).format(new Date(ms));
  return h(
    "div",
    {},
    h("p", { class: "group-title", text: t("connections.title") }),
    h(
      "div",
      { class: "group" },
      h("div", { class: "row" },
        h("span", { class: "tile sm", bg: "linear-gradient(135deg, #ff9a3c, #ff4f6d)" }, icon("link")),
        h("div", { class: "grow" }, h("span", { text: t("connections.intro") }), h("b", { class: "mono", text: mcpUrl })),
        h("button", {
          class: "link-btn",
          text: t("connections.copy"),
          onclick: () => navigator.clipboard?.writeText(mcpUrl).then(() => toast(t("connections.copied")), () => {}),
        }),
      ),
      connections.length
        ? connections.map((c) =>
            h("div", { class: "row" },
              h("span", { class: "tile sm", bg: "linear-gradient(135deg, #8b5cf6, #6366f1)", text: (c.client_name || "?").slice(0, 1).toUpperCase() }),
              h("div", { class: "grow" },
                h("b", { text: c.client_name || t("connect.unknownClient") }),
                h("span", { text: [c.host, c.scopes.map((x) => t(x === "harina.write" ? "connections.write" : "connections.read")).join(" + "), c.last_used_at ? t("connections.lastUsed", { date: fmt(c.last_used_at) }) : t("connections.since", { date: fmt(c.created_at) })].filter(Boolean).join(" · ") }),
              ),
              h("button", {
                class: "link-btn danger",
                text: t("connections.revoke"),
                onclick: () => confirm(t("connections.confirmRevoke", { name: c.client_name || t("connect.unknownClient") })) && guarded(async () => (await api(`/api/connections/${c.id}`, { method: "DELETE" }), onchange())),
              }),
            ),
          )
        : h("div", { class: "row" }, h("span", { class: "muted", text: t("connections.empty") })),
    ),
  );
}

/** What the decision model learned, in numbers (it acts on the iPhone, where payments arrive). */
function autoCategoryGroup() {
  const { calibration, stats } = insights();
  const pct = (x) => (x === null || x === undefined ? t("auto.na") : fmtPct(x));
  const rows = [
    [t("auto.history"), calibration.cases ? t("auto.historyValue", { pct: pct(calibration.accuracy), cases: calibration.cases }) : t("auto.learning")],
    [t("auto.threshold"), calibration.threshold === null ? t("auto.notYet") : t("auto.thresholdValue", { pct: pct(calibration.threshold), coverage: pct(calibration.coverage) })],
    [t("auto.live"), stats.auto + stats.corrected ? t("auto.liveValue", { kept: stats.auto, corrected: stats.corrected, pct: pct(stats.precision) }) : t("auto.noneYet")],
  ];
  return h(
    "div",
    {},
    h("p", { class: "group-title", text: t("auto.title") }),
    h("div", { class: "group" },
      h("div", { class: "row" }, h("span", { class: "tile sm", bg: "linear-gradient(135deg, #ff9a3c, #8b5cf6)" }, icon("spark")), h("div", { class: "grow" }, h("b", { text: t("auto.title") }), h("span", { text: t("auto.intro") }))),
      rows.map(([k, v]) => h("div", { class: "row" }, h("div", { class: "grow" }, h("b", { text: k }), h("span", { text: v })))),
    ),
  );
}

// ---------- settings ----------

async function viewSettings() {
  const [{ devices }, { connections }] = await Promise.all([api("/api/devices"), api("/api/connections")]);
  state.devices = devices;
  const rerender = () => guarded(viewSettings);
  const codeBox = h("div");
  const row = (left, title, sub, ...right) => h("div", { class: "row" }, left, h("div", { class: "grow" }, h("b", { text: title }), sub ? h("span", { text: sub }) : null), ...right);
  const iconTile = (name, from, to) => h("span", { class: "tile sm", bg: `linear-gradient(135deg, ${from}, ${to})` }, icon(name));
  render(
    h("div", { class: "page-head" }, h("h1", { text: t("settings.title") })),
    h("div", { class: "grid dash" },
      h("div", {},
        h("p", { class: "group-title", text: t("categories.title") }),
        h(
          "div",
          { class: "group" },
          live(state.categories)
            .sort((a, b) => categoryName(a).localeCompare(categoryName(b), region))
            .map((c) =>
              h("button", { class: "row row-btn", onclick: () => editCategory(c, rerender) },
                tile(c, "tile sm"),
                h("div", { class: "grow" }, h("b", { text: categoryName(c) })),
                h("span", { class: "go" }, icon("edit")),
              ),
            ),
          h("div", { class: "row" }, h("button", { class: "btn block", onclick: () => editCategory(null, rerender) }, icon("plus"), t("categories.add"))),
        ),
        suggestionsBox(rerender),
        h("p", { class: "group-title", text: t("accounts.title") }),
        h(
          "div",
          { class: "group" },
          live(state.accounts).map((a) =>
            row(
              iconTile("card", "#4c8dff", "#6a5cff"),
              a.name,
              a.card,
              h("button", {
                class: "link-btn danger",
                "aria-label": t("form.delete"),
                onclick: () => confirm(t("accounts.confirmDelete", { name: a.name })) && guarded(async () => (await save("accounts", { ...a, deleted: true }), rerender())),
              }, icon("trash")),
            ),
          ),
          h(
            "div",
            { class: "row" },
            h(
              "form",
              {
                onsubmit: (e) => {
                  e.preventDefault();
                  const [name, card] = e.target.querySelectorAll("input");
                  if (name.value.trim()) guarded(async () => (await save("accounts", { id: crypto.randomUUID(), name: name.value.trim(), card: card.value.trim() || null }), rerender()));
                },
              },
              h("input", { class: "input", placeholder: t("accounts.name"), "aria-label": t("accounts.name"), required: true }),
              h("input", { class: "input", placeholder: t("accounts.cardShort"), "aria-label": t("accounts.card") }),
              h("button", { class: "btn", "aria-label": t("accounts.add") }, icon("plus")),
            ),
          ),
        ),
        h("p", { class: "eyebrow", text: t("accounts.cardHint") }),
      ),
      h("div", {},
        autoCategoryGroup(),
        connectionsGroup(connections, rerender),
        h("p", { class: "group-title", text: t("settings.sync") }),
        h(
          "div",
          { class: "group" },
          row(iconTile("phone", "#ffb547", "#ff7a45"), t("devices.title"), t("devices.server", { url: state.origin })),
          devices.map((d) =>
            row(
              iconTile("phone", "#22c58b", "#0ea5a4"),
              d.name,
              t("devices.lastSeen", { date: fmtDateTime(d.last_seen_at ?? d.created_at) }),
              h("button", {
                class: "link-btn danger",
                text: t("devices.revoke"),
                onclick: () => confirm(t("devices.confirmRevoke", { name: d.name })) && guarded(async () => (await api(`/api/devices/${d.id}`, { method: "DELETE" }), rerender())),
              }),
            ),
          ),
          h(
            "div",
            { class: "row" },
            h("button", {
              class: "btn block",
              onclick: () =>
                guarded(async () => {
                  const { code, expiresAt } = await api("/api/devices/link-code", { method: "POST", body: {} });
                  const time = new Intl.DateTimeFormat(region, { timeStyle: "short" }).format(new Date(expiresAt));
                  codeBox.replaceChildren(
                    h("div", { class: "code-box" },
                      qrSvg(linkUrl(code)),
                      h("b", { text: t("devices.scan") }),
                      h("div", { class: "code", text: code }),
                      h("span", { text: t("devices.code", { time }) }),
                    ),
                  );
                  pollDevices(devices.length, rerender);
                }),
            }, icon("link"), t("devices.newCode")),
          ),
          codeBox,
        ),
        h("p", { class: "eyebrow", text: t("devices.intro") }),
        h("p", { class: "group-title", text: t("data.title") }),
        h(
          "div",
          { class: "group" },
          row(iconTile("download", "#8b5cf6", "#6366f1"), t("data.exportCsv"), null, h("a", { class: "link-btn", href: "/api/export.csv", download: "harina.csv", "aria-label": t("data.exportCsv") }, icon("download"))),
          row(iconTile("download", "#8b5cf6", "#6366f1"), t("data.exportJson"), null, h("a", { class: "link-btn", href: "/api/export.json", download: "harina.json", "aria-label": t("data.exportJson") }, icon("download"))),
          row(iconTile("shield", "#22c58b", "#0ea5a4"), t("data.title"), t("data.privacy")),
        ),
        h("p", { class: "group-title", text: t("settings.security") }),
        h(
          "div",
          { class: "group" },
          h("div", { class: "row" },
            h("button", {
              class: "btn block",
              onclick: () =>
                guarded(async () => {
                  const { challengeId, options } = await api("/api/auth/register/options", { method: "POST", body: {} });
                  const response = await createPasskey(options);
                  await api("/api/auth/register/verify", { method: "POST", body: { challengeId, response } });
                  if (state.session?.user) state.session.user.hasPasskey = true;
                  toast(t("passkeys.added"));
                }),
            }, icon("key"), t("passkeys.add")),
          ),
          state.session?.user && !state.session.user.hasPasskey ? row(iconTile("key", "#ffb547", "#ff7a45"), t("passkeys.missingTitle"), t("passkeys.missing")) : null,
          h("div", { class: "row" },
            h("button", { class: "btn block", onclick: () => guarded(async () => (await api("/api/auth/logout", { method: "POST", body: {} }), boot())) }, icon("logout"), t("nav.logout")),
          ),
          h("div", { class: "row" },
            h("button", {
              class: "btn block danger ghost",
              onclick: () => {
                if (prompt(t("account.confirmDelete")) !== t("data.confirmWord")) return;
                guarded(async () => {
                  await api("/api/account/delete", { method: "POST", body: { confirm: true } });
                  await boot();
                });
              },
            }, icon("trash"), t("account.delete")),
          ),
          h("div", { class: "row" },
            h("button", {
              class: "btn block danger ghost",
              onclick: () => {
                if (prompt(t("data.confirmDeleteAll")) !== t("data.confirmWord")) return;
                guarded(async () => {
                  await api("/api/data/delete", { method: "POST", body: { confirm: true } });
                  await loadAll();
                  toast(t("data.deleted"));
                  rerender();
                });
              },
            }, icon("trash"), t("data.deleteAll")),
          ),
        ),
      ),
    ),
  );
}

ICONS.link = "M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71";

// ---------- router ----------

function router() {
  const hash = location.hash || "#/";
  const edit = hash.match(/^#\/editar\/(.+)$/);
  if (edit) {
    const tx = state.transactions.get(edit[1]);
    return tx && !tx.deleted ? viewForm(tx) : (location.hash = "#/");
  }
  if (hash === "#/nuevo") return viewForm();
  if (hash === "#/movimientos") return viewMovements();
  if (hash === "#/fijos") return viewFixed();
  if (hash === "#/revisar") return viewReview();
  if (hash === "#/ajustes") return guarded(viewSettings);
  return viewMonth();
}

function onRoute() {
  if (!main) return;
  if (!location.hash.startsWith("#/editar")) state.back = location.hash || "#/";
  refreshBadge();
  router();
}

// ---------- connecting an assistant (OAuth consent, docs/adr/0004-oauth-and-mcp.md) ----------

/** Full-screen consent page, shown before the app shell: who asks, what it can do, allow or deny. */
async function viewConsent(id) {
  if (id.startsWith("error/")) {
    const key = id === "error/request_expired" ? "connect.expired" : "connect.badRequest";
    return authScreen(h("h1", { text: t("connect.title") }), h("p", { text: t(key) }));
  }
  let info;
  try {
    info = await api(`/api/oauth/requests/${encodeURIComponent(id)}`);
  } catch (e) {
    if (e instanceof ApiError && e.message === "unauthorized") return viewLogin();
    return authScreen(h("h1", { text: t("connect.title") }), h("p", { text: t("connect.expired") }));
  }
  const name = info.client.name || t("connect.unknownClient");
  const wantsWrite = info.scopes.includes("harina.write");
  const write = h("input", { type: "checkbox", id: "write" });
  const decide = (approve) =>
    guarded(async () => {
      const { redirect } = await api("/api/oauth/decision", { method: "POST", body: { id, approve, write: approve && write.checked } });
      app.replaceChildren(h("div", { class: "auth" }, h("p", { text: t("connect.redirecting") })));
      location.assign(redirect);
    });
  authScreen(
    h("h1", { text: t("connect.title") }),
    h("p", {}, h("b", { text: t("connect.intro", { client: name }) }), h("br"), h("span", { class: "muted-host", text: t("connect.from", { host: info.client.host }) })),
    h(
      "div",
      { class: "feature-list" },
      h("div", {}, h("span", { class: "tile", bg: "linear-gradient(135deg, #22c58b, #0ea5a4)" }, icon("check")), t("connect.canRead")),
      wantsWrite ? h("label", { class: "consent-write", for: "write" }, write, h("span", { text: t("connect.canWrite") })) : null,
      h("div", {}, h("span", { class: "tile", bg: "linear-gradient(135deg, #8b5cf6, #6366f1)" }, icon("shield")), t("connect.never")),
    ),
    h("p", { class: "consent-warning", text: t("connect.warning") }),
    h("div", { class: "actions-row" },
      h("button", { class: "btn primary", onclick: () => decide(true) }, icon("check"), t("connect.allow")),
      h("button", { class: "btn ghost", onclick: () => decide(false), text: t("connect.deny") }),
    ),
  );
}

async function boot() {
  main = null;
  app.replaceChildren(h("div", { class: "auth" }, h("div", { class: "auth-card" }, h("div", { class: "logo" }, logo()), h("p", { text: t("app.loading") }))));
  let session;
  try {
    session = await api("/api/session");
  } catch (e) {
    return app.replaceChildren(h("div", { class: "auth" }, h("p", { text: errorText(e) })));
  }
  state.origin = session.origin;
  state.session = session;
  if (session.setupNeeded && session.signup !== "open") return viewSetup();
  const consent = (location.hash || "").match(/^#\/autorizar\/(.+)$/)?.[1];
  if (consent?.startsWith("error/")) return viewConsent(consent);
  if (!session.authenticated) return viewLogin(session);
  if (consent) return viewConsent(consent);
  for (const k of ["accounts", "categories", "transactions"]) state[k].clear();
  await guarded(async () => {
    await loadAll();
    state.devices = (await api("/api/devices")).devices;
  });
  shell();
  router();
}

window.addEventListener("hashchange", onRoute);
await loadLocale();
applyI18n();
boot();
