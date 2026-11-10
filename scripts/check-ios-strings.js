// Fails when the iOS app uses a localization key that is missing in es.lproj/Localizable.strings.
import { readFileSync, readdirSync } from "node:fs";

const dir = "ios/Harina/Resources/es.lproj";
const strings = readFileSync(`${dir}/Localizable.strings`, "utf8") + readFileSync(`${dir}/AppShortcuts.strings`, "utf8");
// Interpolations become %@ or %lld depending on the type; compare them all as %@.
const defined = new Set([...strings.matchAll(/^"([^"]+)"\s*=/gm)].map((m) => m[1].replace(/\$\{\w+\}/g, "%@").replace(/%lld/g, "%@")));
const errors = [];
const SYMBOL_ROOTS = new Set(["checkmark", "plus", "bolt", "dollarsign", "lock", "arrow", "chevron", "square", "circle", "faceid",
  "qrcode", "link", "trash", "pencil", "icloud", "tray", "house", "list", "slider", "creditcard", "leaf", "desktopcomputer", "sparkles", "mic", "person", "banknote", "bell", "tray", "hand", "calendar"]);
for (const f of readdirSync("ios/Harina", { recursive: true }).filter((p) => p.endsWith(".swift"))) {
  const src = readFileSync(`ios/Harina/${f}`, "utf8");
  // Literal keys look like "area.name", optionally with one interpolation: "area.name \(x)".
  for (const m of src.matchAll(/(systemImage: |systemName: |static let \w+ = |L\()?"([a-z]+\.[a-zA-Z.]+)((?: \\\([^"]*?\))*)"/g)) {
    if (m[1]) continue; // SF Symbols, and run-time keys checked below
    const count = (m[3].match(/\\\(/g) ?? []).length;
    const key = m[2] + " %@".repeat(count);
    if (/^(app\.lzno|harina\.|api\.)/.test(m[2])) continue;
    // SF Symbols passed through variables or ternaries (systemImage: and systemName: are skipped above).
    if (SYMBOL_ROOTS.has(m[2].split(".")[0])) continue;
    // Prefix of a key built at run time, for example LocalizedStringKey("onboarding.currency." + code).
    if (m[2].endsWith(".")) {
      if (![...defined].some((k) => k.startsWith(m[2]))) errors.push(`ios/Harina/${f}: no keys start with "${m[2]}"`);
      continue;
    }
    if (!defined.has(key)) errors.push(`ios/Harina/${f}: missing "${key}"`);
  }
  for (const m of src.matchAll(/L\("([a-z.]+)" \+/g)) {
    if (![...defined].some((k) => k.startsWith(m[1]))) errors.push(`ios/Harina/${f}: no keys start with "${m[1]}"`);
  }
}
if (errors.length) {
  console.error(errors.join("\n"));
  process.exit(1);
}
console.log(`ios strings: ok (${defined.size} keys)`);
