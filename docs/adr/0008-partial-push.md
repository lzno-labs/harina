# ADR-0008: A refused record never blocks the iPhone's sync

- **Status:** Accepted
- **Date:** 2026-11-20
- **Extends:** ADR-0002
- **Author:** owner session (claude)

## Context

Under ADR-0002 a push is all or nothing: one record that breaks a rule refuses the whole request
and nothing is saved. The iPhone sends its whole queue in one push and only pulls after a
successful push. So one bad record stops that iPhone from sending anything, and from receiving
anything either, on every sync, until someone finds and fixes it. The only sign is the generic
«No se pudo sincronizar», which blames the signal.

Records can break a rule without a bug in the forms:

- The iPhone counts characters, while the server counts UTF-16 code units, where an emoji takes
  two or more. A long note with emoji passes on the phone and fails on the server.
- A phone whose clock is more than a day ahead has every edit refused.
- A newer app can send a value or a kind of record that an older server does not know. Since the
  repository is public, self-hosted servers will lag behind the app.

## Options

1. **Keep all or nothing** and fix each cause on the client. The next unforeseen cause blocks sync
   again.
2. **Always save what is valid.** This breaks moves: a move is a tombstone in the old space and a
   copy in the new one. Saving only the tombstone would make the record disappear. It also breaks
   the web, which saves one record at a time and shows the error.
3. **Partial pushes on request**, with records grouped by entity and id.

## Decision

Option 3, plus two client and server fixes.

- **Opt-in partial pushes.** `POST /api/sync` takes `partial: true`. Records are grouped by entity
  and id: a move is one group, and a suggested category with the same id in two spaces is one
  group too. A group with any invalid record is left out. The rest is saved, and the response adds
  `rejected: [{ entity, id, space_id, error, field }]`.
  - The answer is 200 even when everything was refused. Malformed requests and more than 500
    records are still a 400.
  - An entity the server does not know is refused alone.
- **Who uses it.** Only the iPhone's queue sends `partial`. Moves, the web and MCP do not, and keep
  all or nothing.
- **What the iPhone does with refusals.**
  - Refused records stay on the phone, marked to send.
  - Everything else syncs, and the pull runs.
  - Settings shows «Cambios sin enviar» with each record and why it was refused, and opens its
    editor to fix or delete it.
- **Text limits.** The iPhone cuts text to the server's limits, counted in UTF-16 code units,
  before sending.
- **Future clocks.** A record more than a day in the future counts as written now. Before, it was
  refused. It still cannot beat later edits, which was the point of the limit.

## Consequences

- **Compatible both ways.** Older apps never send `partial` and see the same answers as before,
  except that a future `updated_at` is now saved. Older servers ignore `partial` and answer all or
  nothing, so a new app behaves as before with them.
- **Refused records keep being sent.** A refused record is resent on every sync until it is fixed.
  It is small and the server stays the judge.
- **The web is unchanged.** It still shows the error of the one record it saved.
