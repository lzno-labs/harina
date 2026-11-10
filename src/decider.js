// SPDX-License-Identifier: AGPL-3.0-only
// Hosted category decider (docs/adr/0005-hosted-decider.md). The open core ships none: a
// deployment that offers one replaces this file with its own `createDecider(env)`.
//
// A decider is `{ name, decide({ state, questions }) }` resolving to
// `{ answers: { <question id>: { choice, confidence } }, inputTokens }`, the shape of a
// decision model's `choice` questions. Return null to offer nothing.

/** @returns {null | { name: string, decide: (q: { state: string, questions: object }) => Promise<{ answers: object, inputTokens: number }> }} */
export function createDecider() {
  return null;
}
