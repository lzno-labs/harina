// Fails when visible text is written in the web code instead of locales/*.json, or when a
// translation key used by the web or server does not exist in locales/es.json.
import { readFileSync, readdirSync } from "node:fs";

const es = JSON.parse(readFileSync("locales/es.json", "utf8"));
const has = (key) => key.split(".").reduce((o, k) => (o && typeof o === "object" ? o[k] : undefined), es) !== undefined;
const errors = [];

// 1. HTML: no text between tags except the brand name; text comes from data-i18n.
const html = readFileSync("public/index.html", "utf8").replace(/<script[\s\S]*?<\/script>|<style[\s\S]*?<\/style>/g, "");
for (const m of html.matchAll(/>([^<]+)</g)) {
  const text = m[1].trim();
  if (text && text !== "Harina") errors.push(`public/index.html: visible text "${text}" must come from locales`);
}
for (const m of html.matchAll(/data-i18n(?:-[a-z]+)?="([^"]+)"/g)) if (!has(m[1])) errors.push(`public/index.html: missing key ${m[1]}`);

// 2. JS: every t("key") exists, and no string literal with letters is used as visible text.
for (const dir of ["public", "src"]) {
  for (const f of readdirSync(dir, { recursive: true }).filter((p) => p.endsWith(".js"))) {
    const path = `${dir}/${f}`;
    const src = readFileSync(path, "utf8");
    for (const m of src.matchAll(/\bt\("([a-zA-Z0-9_.]+)"/g)) if (!has(m[1])) errors.push(`${path}: missing key ${m[1]}`);
    for (const m of src.matchAll(/\b(?:text|placeholder|"aria-label"|title):\s*"([^"]*[A-Za-zÁÉÍÓÚáéíóúñÑ][^"]*)"/g)) {
      errors.push(`${path}: visible text "${m[1]}" must come from locales`);
    }
    for (const m of src.matchAll(/\b(?:textContent|innerText)\s*=\s*"([^"]+)"/g)) errors.push(`${path}: visible text "${m[1]}" must come from locales`);
    if (/\.innerHTML\s*=/.test(src)) errors.push(`${path}: innerHTML is not allowed (XSS); build nodes and use textContent`);
  }
}

// 3. Every locale file has the same keys as es.json.
const keys = (o, p = "") => Object.entries(o).flatMap(([k, v]) => (v && typeof v === "object" ? keys(v, `${p}${k}.`) : [`${p}${k}`]));
const base = new Set(keys(es));
for (const f of readdirSync("locales").filter((f) => f.endsWith(".json") && f !== "es.json")) {
  const other = new Set(keys(JSON.parse(readFileSync(`locales/${f}`, "utf8"))));
  for (const k of base) if (!other.has(k)) errors.push(`locales/${f}: missing ${k}`);
  for (const k of other) if (!base.has(k)) errors.push(`locales/${f}: extra ${k}`);
}

if (errors.length) {
  console.error(errors.join("\n"));
  process.exit(1);
}
console.log("i18n: ok");
