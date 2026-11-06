-- RETIRED: key bytes remain in the database prototype and application roles
-- cannot access them after migration 20261101000003. This old manual test
-- inserts a raw key and exercises unsafe company-id based functions. Do not run.
-- Use supabase/tests/encryption_key_containment.test.sql for current checks.
SELECT 'legacy encryption round-trip script is retired; no changes were made' AS status;
