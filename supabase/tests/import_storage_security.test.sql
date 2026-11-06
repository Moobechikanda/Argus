BEGIN;
SELECT plan(6);

SELECT ok(
  EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'reconciliation-imports' AND public = false),
  'reconciliation import bucket exists and is private'
);
SELECT ok(
  EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'storage' AND tablename = 'objects'
    AND policyname = 'reconciliation_import_storage_insert' AND cmd = 'INSERT'
    AND roles @> ARRAY['authenticated']::name[]),
  'authenticated users have the dedicated import upload policy'
);
SELECT ok(
  NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'storage' AND tablename = 'objects'
    AND policyname LIKE 'reconciliation_import_storage_%' AND cmd IN ('SELECT', 'UPDATE', 'DELETE', 'ALL')),
  'import policy grants no direct read, update, or delete path'
);
SELECT ok(
  (SELECT qual FROM pg_policies WHERE schemaname = 'storage' AND tablename = 'objects'
    AND policyname = 'reconciliation_import_storage_insert') IS NULL,
  'insert policy does not grant access based on caller-controlled USING clause'
);
SELECT ok(
  (SELECT with_check FROM pg_policies WHERE schemaname = 'storage' AND tablename = 'objects'
    AND policyname = 'reconciliation_import_storage_insert') LIKE '%has_role_in%'
    AND (SELECT with_check FROM pg_policies WHERE schemaname = 'storage' AND tablename = 'objects'
    AND policyname = 'reconciliation_import_storage_insert') LIKE '%reconciliation_data_sources%',
  'upload policy checks admin membership and source ownership'
);
SELECT ok(
  (SELECT file_size_limit = 52428800 AND NOT public FROM storage.buckets WHERE id = 'reconciliation-imports'),
  'bucket enforces a 50 MiB limit and remains private'
);

SELECT * FROM finish();
ROLLBACK;
