// Amounts: parsing what a person types and formatting by region. Shared by the web and tests.

const ZERO_DECIMAL = new Set(["JPY", "KRW", "CLP", "PYG"]);
export const minorUnits = (currency) => (ZERO_DECIMAL.has(currency) ? 0 : 2);

/**
 * Parses "4500", "4 500,50", "4.500,50", "4,500.50", "12,5" or "₡4 500" into minor units.
 * The last "," or "." followed by one or two digits is the decimal mark; other marks group thousands.
 * @returns {number | null} minor units, or null when the text is not an amount
 */
export function parseAmount(text, currency = "CRC") {
  if (typeof text !== "string") return null;
  const s = text.replace(/[\s\u00a0\u202f]/g, "").replace(/[^\d.,-]/g, "");
  if (!s || s.includes("-") || !/\d/.test(s)) return null;
  const m = s.match(/^(.*?)[.,](\d{1,2})$/);
  let whole = m ? m[1] : s;
  let frac = m ? m[2] : "";
  // "4.500" or "4,500" with exactly three digits after the only mark is a thousands group.
  if (!m && /[.,]/.test(s)) whole = s;
  whole = whole.replace(/[.,]/g, "");
  if (!/^\d*$/.test(whole) || (!whole && !frac)) return null;
  const d = minorUnits(currency);
  frac = frac.padEnd(d, "0").slice(0, d);
  const n = Number(`${whole || "0"}${frac}`);
  return Number.isSafeInteger(n) ? n : null;
}

export function minorToNumber(minor, currency) {
  return minor / 10 ** minorUnits(currency);
}

/** Formats minor units for a region, for example es-CR → "₡4 500,00". */
export function formatMoney(minor, currency, locale) {
  return new Intl.NumberFormat(locale, { style: "currency", currency }).format(minorToNumber(minor, currency));
}

/** Plain editable text for an amount, using the region's decimal mark. */
export function minorToInput(minor, currency, locale) {
  const d = minorUnits(currency);
  return new Intl.NumberFormat(locale, { minimumFractionDigits: d, maximumFractionDigits: d, useGrouping: false }).format(
    minorToNumber(minor, currency),
  );
}
