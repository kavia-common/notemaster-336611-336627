#!/bin/bash
set -euo pipefail

# Initializes schema and seed data for the notes app.
#
# This script is designed to be idempotent and safe to run on every container start.
# It uses the connection string written by startup.sh in db_connection.txt.
#
# Tables:
# - notes: note content (markdown), timestamps
# - tags: unique tag names
# - note_tags: many-to-many join table
#
# Seed data:
# - a few starter tags
# - a few starter notes
# - relationships between them
#
# Exit codes:
# - 0 on success
# - non-zero on failure

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONN_FILE="${SCRIPT_DIR}/db_connection.txt"

if [ ! -f "${CONN_FILE}" ]; then
  echo "ERROR: ${CONN_FILE} not found. Run startup.sh first (or ensure it created db_connection.txt)."
  exit 1
fi

CONN_CMD="$(cat "${CONN_FILE}")"
if [ -z "${CONN_CMD}" ]; then
  echo "ERROR: db_connection.txt is empty."
  exit 1
fi

# db_connection.txt contains something like:
#   psql postgresql://appuser:pass@localhost:5000/myapp
# We want the URL part for psql connection:
DB_URL="${CONN_CMD#psql }"

echo "Initializing notes schema using ${CONN_FILE} ..."

# Use ON_ERROR_STOP so the script fails fast on SQL errors.
PSQL_BASE=(psql "${DB_URL}" -v ON_ERROR_STOP=1)

run_sql() {
  local sql="$1"
  "${PSQL_BASE[@]}" -c "${sql}" >/dev/null
}

# ---- Schema ----

# Needed for gen_random_uuid() (if backend ever wants UUIDs) and generally harmless.
run_sql 'CREATE EXTENSION IF NOT EXISTS pgcrypto;'

run_sql '
CREATE TABLE IF NOT EXISTS notes (
  id BIGSERIAL PRIMARY KEY,
  title TEXT NOT NULL DEFAULT '''',
  content TEXT NOT NULL DEFAULT '''',
  is_archived BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
'

run_sql '
CREATE TABLE IF NOT EXISTS tags (
  id BIGSERIAL PRIMARY KEY,
  name TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT tags_name_unique UNIQUE (name)
);
'

run_sql '
CREATE TABLE IF NOT EXISTS note_tags (
  note_id BIGINT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
  tag_id  BIGINT NOT NULL REFERENCES tags(id)  ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (note_id, tag_id)
);
'

run_sql 'CREATE INDEX IF NOT EXISTS idx_notes_updated_at ON notes(updated_at DESC);'
run_sql 'CREATE INDEX IF NOT EXISTS idx_note_tags_note_id ON note_tags(note_id);'
run_sql 'CREATE INDEX IF NOT EXISTS idx_note_tags_tag_id ON note_tags(tag_id);'

# Keep updated_at correct.
run_sql '
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
'

run_sql '
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger WHERE tgname = ''trg_notes_set_updated_at''
  ) THEN
    CREATE TRIGGER trg_notes_set_updated_at
    BEFORE UPDATE ON notes
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();
  END IF;
END
$$;
'

# ---- Seed data (idempotent) ----
# Use deterministic IDs via natural keys where possible to make seeding repeatable.

run_sql "INSERT INTO tags(name) VALUES ('inbox')      ON CONFLICT (name) DO NOTHING;"
run_sql "INSERT INTO tags(name) VALUES ('work')       ON CONFLICT (name) DO NOTHING;"
run_sql "INSERT INTO tags(name) VALUES ('personal')   ON CONFLICT (name) DO NOTHING;"
run_sql "INSERT INTO tags(name) VALUES ('ideas')      ON CONFLICT (name) DO NOTHING;"
run_sql "INSERT INTO tags(name) VALUES ('markdown')   ON CONFLICT (name) DO NOTHING;"

# Insert a few notes only if the table is empty (keeps user data intact on restart).
run_sql '
DO $$
DECLARE
  n_count BIGINT;
BEGIN
  SELECT COUNT(*) INTO n_count FROM notes;
  IF n_count = 0 THEN
    INSERT INTO notes(title, content)
    VALUES
      (
        ''Welcome to NoteMaster'',
        ''# Welcome\n\nThis is a seeded note.\n\n- Edit me\n- Tag me\n- Delete me\n\nMarkdown is supported.''
      ),
      (
        ''Quick ideas'',
        ''## Ideas\n\n- Add keyboard shortcuts\n- Add full-text search\n- Add offline mode''
      ),
      (
        ''Work checklist'',
        ''## Checklist\n\n- [ ] Draft spec\n- [ ] Implement API\n- [ ] Wire up UI\n- [ ] Verify end-to-end''
      );
  END IF;
END
$$;
'

# Attach tags to the seeded notes based on title matching.
# This is safe to run multiple times due to PK(note_id, tag_id) and ON CONFLICT DO NOTHING.
run_sql "
INSERT INTO note_tags(note_id, tag_id)
SELECT n.id, t.id
FROM notes n
JOIN tags t ON t.name = 'markdown'
WHERE n.title = 'Welcome to NoteMaster'
ON CONFLICT DO NOTHING;
"

run_sql "
INSERT INTO note_tags(note_id, tag_id)
SELECT n.id, t.id
FROM notes n
JOIN tags t ON t.name = 'inbox'
WHERE n.title IN ('Welcome to NoteMaster', 'Quick ideas', 'Work checklist')
ON CONFLICT DO NOTHING;
"

run_sql "
INSERT INTO note_tags(note_id, tag_id)
SELECT n.id, t.id
FROM notes n
JOIN tags t ON t.name = 'ideas'
WHERE n.title = 'Quick ideas'
ON CONFLICT DO NOTHING;
"

run_sql "
INSERT INTO note_tags(note_id, tag_id)
SELECT n.id, t.id
FROM notes n
JOIN tags t ON t.name = 'work'
WHERE n.title = 'Work checklist'
ON CONFLICT DO NOTHING;
"

echo "Notes schema + seed initialization complete."
