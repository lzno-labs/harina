// Small crypto helpers on Web Crypto, available in Node 22 and in Workers.

export function randomToken(bytes = 32) {
  const b = crypto.getRandomValues(new Uint8Array(bytes));
  return btoa(String.fromCharCode(...b)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export async function sha256(text) {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(d)].map((x) => x.toString(16).padStart(2, "0")).join("");
}

/** Comparison through hashes, so timing does not reveal a matching prefix. */
export async function safeEqual(a, b) {
  return (await sha256(`cmp:${a}`)) === (await sha256(`cmp:${b}`));
}

const LINK_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"; // no 0/O, 1/I/L

/** Human-typeable one-time code, for example "K7QF-M2XA". */
export function linkCode() {
  const b = crypto.getRandomValues(new Uint8Array(8));
  const s = [...b].map((x) => LINK_ALPHABET[x % LINK_ALPHABET.length]).join("");
  return `${s.slice(0, 4)}-${s.slice(4)}`;
}

export function normalizeLinkCode(code) {
  return String(code ?? "").toUpperCase().replace(/[^A-Z0-9]/g, "");
}
