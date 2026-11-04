// A software passkey for tests: produces real WebAuthn registration and assertion responses
// (ES256, "none" attestation) so the server's verification runs end to end.

const enc = new TextEncoder();
const b64url = (buf) => Buffer.from(buf).toString("base64url");
const concat = (...parts) => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let i = 0;
  for (const p of parts) out.set(p, (i += p.length) - p.length);
  return out;
};
const sha256 = async (data) => new Uint8Array(await crypto.subtle.digest("SHA-256", data));

function cborHead(major, n) {
  if (n < 24) return Uint8Array.of((major << 5) | n);
  if (n < 256) return Uint8Array.of((major << 5) | 24, n);
  if (n < 65536) return Uint8Array.of((major << 5) | 25, n >> 8, n & 255);
  throw new Error("too long");
}
function cbor(v) {
  if (typeof v === "number") return v >= 0 ? cborHead(0, v) : cborHead(1, -1 - v);
  if (typeof v === "string") return concat(cborHead(3, enc.encode(v).length), enc.encode(v));
  if (v instanceof Uint8Array) return concat(cborHead(2, v.length), v);
  if (v instanceof Map) return concat(cborHead(5, v.size), ...[...v].flatMap(([k, x]) => [cbor(k), cbor(x)]));
  throw new Error("unsupported");
}

function derSignature(raw) {
  const int = (b) => {
    let i = 0;
    while (i < b.length - 1 && b[i] === 0) i++;
    b = b.slice(i);
    if (b[0] & 0x80) b = concat(Uint8Array.of(0), b);
    return concat(Uint8Array.of(0x02, b.length), b);
  };
  const body = concat(int(raw.slice(0, 32)), int(raw.slice(32)));
  return concat(Uint8Array.of(0x30, body.length), body);
}

export async function createAuthenticator() {
  const keys = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const credId = crypto.getRandomValues(new Uint8Array(16));
  let counter = 0;

  async function authData(rpId, flags, extra = new Uint8Array()) {
    const c = new Uint8Array(4);
    new DataView(c.buffer).setUint32(0, counter);
    return concat(await sha256(enc.encode(rpId)), Uint8Array.of(flags), c, extra);
  }

  return {
    async register(options, origin) {
      const jwk = await crypto.subtle.exportKey("jwk", keys.publicKey);
      const cose = cbor(new Map([[1, 2], [3, -7], [-1, 1], [-2, Buffer.from(jwk.x, "base64url")], [-3, Buffer.from(jwk.y, "base64url")]]));
      const len = Uint8Array.of(credId.length >> 8, credId.length & 255);
      const ad = await authData(options.rp.id, 0x45, concat(new Uint8Array(16), len, credId, cose));
      const clientData = enc.encode(JSON.stringify({ type: "webauthn.create", challenge: options.challenge, origin, crossOrigin: false }));
      return {
        id: b64url(credId),
        rawId: b64url(credId),
        type: "public-key",
        clientExtensionResults: {},
        response: {
          clientDataJSON: b64url(clientData),
          attestationObject: b64url(cbor(new Map([["fmt", "none"], ["attStmt", new Map()], ["authData", ad]]))),
          transports: ["internal"],
        },
      };
    },
    async login(options, origin, { rpId } = {}) {
      counter += 1;
      const ad = await authData(rpId ?? options.rpId, 0x05);
      const clientData = enc.encode(JSON.stringify({ type: "webauthn.get", challenge: options.challenge, origin, crossOrigin: false }));
      const raw = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, keys.privateKey, concat(ad, await sha256(clientData))));
      return {
        id: b64url(credId),
        rawId: b64url(credId),
        type: "public-key",
        clientExtensionResults: {},
        response: {
          clientDataJSON: b64url(clientData),
          authenticatorData: b64url(ad),
          signature: b64url(derSignature(raw)),
          userHandle: b64url(enc.encode("owner")),
        },
      };
    },
  };
}
