-- Envelopes, payment reminders and savings pots (docs/design/budgets-reminders-savings.md).

CREATE TABLE reminders (
  space_id TEXT NOT NULL,
  id TEXT NOT NULL,
  name TEXT NOT NULL,
  amount_minor INTEGER,
  currency TEXT,
  day_of_month INTEGER NOT NULL CHECK (day_of_month BETWEEN 1 AND 31),
  category_id TEXT,
  account_id TEXT,
  paid_month TEXT,
  note TEXT,
  updated_at INTEGER NOT NULL,
  deleted INTEGER NOT NULL DEFAULT 0,
  seq INTEGER NOT NULL,
  PRIMARY KEY (space_id, id)
);
CREATE INDEX reminders_seq ON reminders (seq);

CREATE TABLE budgets (
  space_id TEXT NOT NULL,
  id TEXT NOT NULL,
  name TEXT NOT NULL,
  amount_minor INTEGER NOT NULL,
  currency TEXT NOT NULL,
  category_ids TEXT NOT NULL,
  updated_at INTEGER NOT NULL,
  deleted INTEGER NOT NULL DEFAULT 0,
  seq INTEGER NOT NULL,
  PRIMARY KEY (space_id, id)
);
CREATE INDEX budgets_seq ON budgets (seq);

CREATE TABLE pots (
  space_id TEXT NOT NULL,
  id TEXT NOT NULL,
  name TEXT NOT NULL,
  currency TEXT NOT NULL,
  goal_minor INTEGER,
  goal_date TEXT,
  updated_at INTEGER NOT NULL,
  deleted INTEGER NOT NULL DEFAULT 0,
  seq INTEGER NOT NULL,
  PRIMARY KEY (space_id, id)
);
CREATE INDEX pots_seq ON pots (seq);

-- New kinds: 'saving' (money into a pot) and 'withdrawal' (back out), plus pot_id. SQLite cannot
-- change a CHECK, so the table is rebuilt and every row copied.
CREATE TABLE transactions_new (
  space_id TEXT NOT NULL,
  id TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('expense', 'income', 'saving', 'withdrawal')),
  amount_minor INTEGER NOT NULL CHECK (amount_minor >= 0),
  currency TEXT NOT NULL CHECK (length(currency) = 3),
  category_id TEXT,
  account_id TEXT,
  pot_id TEXT,
  merchant TEXT,
  note TEXT,
  card TEXT,
  source TEXT NOT NULL CHECK (source IN ('manual', 'apple_pay')),
  raw_amount TEXT,
  needs_review INTEGER NOT NULL DEFAULT 0,
  category_auto INTEGER NOT NULL DEFAULT 0,
  created_by TEXT,
  occurred_at TEXT NOT NULL,
  updated_at INTEGER NOT NULL,
  deleted INTEGER NOT NULL DEFAULT 0,
  seq INTEGER NOT NULL,
  PRIMARY KEY (space_id, id)
);
INSERT INTO transactions_new (space_id, id, kind, amount_minor, currency, category_id, account_id, merchant, note, card, source,
  raw_amount, needs_review, category_auto, created_by, occurred_at, updated_at, deleted, seq)
SELECT space_id, id, kind, amount_minor, currency, category_id, account_id, merchant, note, card, source,
  raw_amount, needs_review, category_auto, created_by, occurred_at, updated_at, deleted, seq FROM transactions;
DROP TABLE transactions;
ALTER TABLE transactions_new RENAME TO transactions;
CREATE INDEX transactions_seq ON transactions (seq);
CREATE INDEX transactions_occurred ON transactions (space_id, occurred_at);
