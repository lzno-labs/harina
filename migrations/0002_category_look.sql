-- Categories can carry their own emoji and color (docs/design/onboarding.md).
-- Both optional: without them the look comes from the key (suggestions) or the id (custom).
ALTER TABLE categories ADD COLUMN icon TEXT;
ALTER TABLE categories ADD COLUMN color TEXT;
