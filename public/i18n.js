// Loads locales/<lang>.json from the server. No visible text lives in the code.
let strings = {};
export const lang = "es";
// Numbers, money and dates follow the browser's region; words follow the locale file.
export const region = navigator.language && navigator.language.startsWith("es") ? navigator.language : "es-CR";

export async function loadLocale() {
  const r = await fetch(`/locales/${lang}.json`);
  strings = await r.json();
  document.documentElement.lang = lang;
}

export function t(key, vars = {}) {
  const s = key.split(".").reduce((o, k) => (o && typeof o === "object" ? o[k] : undefined), strings);
  if (typeof s !== "string") return key;
  return s.replace(/\{(\w+)\}/g, (_, k) => String(vars[k] ?? ""));
}

/** Fills elements marked with data-i18n (text) and data-i18n-<attr> (attributes). */
export function applyI18n(root = document) {
  for (const el of root.querySelectorAll("[data-i18n]")) el.textContent = t(el.dataset.i18n);
  for (const el of root.querySelectorAll("*")) {
    for (const a of [...el.attributes]) {
      if (a.name.startsWith("data-i18n-")) el.setAttribute(a.name.slice(10), t(a.value));
    }
  }
}
