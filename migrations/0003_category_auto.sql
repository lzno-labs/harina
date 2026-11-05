-- How a transaction got its category (docs/design/fijos-y-categoria-automatica.md):
-- 0 set by the person, 1 set automatically by the decision model, 2 automatic then corrected.
ALTER TABLE transactions ADD COLUMN category_auto INTEGER NOT NULL DEFAULT 0;
