# People and spaces: Harina for many people, with personal and shared finances

Status: proposed, 2026-11-10. Architecture: ADR-0006. Scope approved by the owner.

## Goal

Anyone can create an account on harina.lzno.app, from the iPhone or the web. Each person keeps
their finances private and can share part of them with someone (a partner, a household) without
sharing everything.

## How it looks to people

- **Spaces.** «Personal» (only me) and any shared space («Casa», «Viaje a Panamá»). The summary
  has a space picker: Personal, each shared space, or «Todo» (everything I can see).
- **Sharing by card.** Each account or card has a space. «BAC Visa» → Personal; «Tarjeta de la casa»
  → Casa. An Apple Pay payment lands in the card's space automatically, so day to day sharing needs
  no taps. The Siri and manual forms default to the last space used and can change it.
- **Moving one payment.** Any movement can be moved to another space I belong to (for example a
  personal card used for the household groceries). The other members see it from then on; moving it
  back hides it again.
- **Inviting.** In a shared space: «Invitar» shows a QR, a link and a code (7 days, one use). The
  invitee needs an account (they can create it from the link).
- **Who paid.** In a shared space each movement shows who added it. Members can edit and categorize;
  only the owner can delete the space or remove members.
- **Categories per space.** A new shared space starts with the suggested categories; each space
  edits its own. The decision model learns per space.

## Accounts

- **From the iPhone:** onboarding «Con un servidor» → «Crear cuenta» (name optional) → the server
  creates the user, the personal space and the device token. Nothing else to type. The data already
  on the phone moves to the personal space (it was waiting to sync).
- **Web access later:** Settings, «Entrar en la computadora»: the iPhone shows a one-time code; the
  web asks for it and then for a new passkey.
- **From the web:** «Crear cuenta» with a passkey, then link the iPhone with the QR as today.
- **Without a server:** unchanged; the phone keeps everything, and it can create an account later.

## Later (not in this design)

Splitting a shared expense («yo pagué, mitad y mitad») and the «quién le debe a quién» balance; a
space for more than one currency rule; read-only members.

## Phases

1. **Users and sign-up** (fresh schema, per-user passkeys and devices, sign-up on web and iPhone, the
   web-access code, `HARINA_SIGNUP`, limits). Test data on the server is discarded (owner, 2026-11-10);
   rows still on an iPhone sync again after relinking.
2. **Shared spaces** (spaces, invites, card space, move a movement, space picker, per-space
   categories, who paid) on server, web and iPhone.
3. **Legal and opening:** privacy notice and terms (approved by the owner), then
   `HARINA_SIGNUP=open` on harina.lzno.app.

## Security and privacy

- Every query filters by the user's spaces; tests prove a user cannot read or write another
  person's space through sync, export, MCP or the decider.
- Invites are single use, expire and are stored hashed; a link only names the space after sign-in.
- Sign-up: rate limit per IP, `HARINA_MAX_USERS`, no email collected.
- Deleting an account removes the personal space; for shared spaces the person chooses to delete
  or leave what they added.

## Cost

D1 free tier (5 GB, 5 million reads a day) covers thousands of people at this data size. No new
provider. The hosted decider cap becomes per user as well as global.
