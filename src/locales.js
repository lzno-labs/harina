// Every user-facing string lives in locales/<lang>.json. Spanish is the default.
import es from "../locales/es.json" with { type: "json" };

export const LOCALES = { es };
export const DEFAULT_LOCALE = "es";

export function lookup(lang, key) {
  return key.split(".").reduce((o, k) => (o && typeof o === "object" ? o[k] : undefined), LOCALES[lang] ?? LOCALES.es);
}
