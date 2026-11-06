-- Private, tenant-scoped upload storage for reconciliation imports.
-- Object keys are exactly: <company UUID>/<data source UUID>/<generated filename>.
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
    'reconciliation-imports', 'reconciliation-imports', false, 52428800,
    ARRAY['text/csv', 'application/json', 'application/x-ndjson', 'text/plain']
)
ON CONFLICT (id) DO UPDATE SET
    name = EXCLUDED.name,
    public = false,
    file_size_limit = EXCLUDED.file_size_limit,
    allowed_mime_types = EXCLUDED.allowed_mime_types;

DROP POLICY IF EXISTS reconciliation_import_storage_insert ON storage.objects;
CREATE POLICY reconciliation_import_storage_insert ON storage.objects
FOR INSERT TO authenticated
WITH CHECK (
    bucket_id = 'reconciliation-imports'
    AND array_length(storage.foldername(name), 1) = 2
    AND (storage.foldername(name))[1] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    AND (storage.foldername(name))[2] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    AND storage.filename(name) ~* '^[0-9a-f-]{36}\.(csv|json|jsonl)$'
    AND EXISTS (
        SELECT 1
          FROM public.reconciliation_data_sources ds
        WHERE ds.id = ((storage.foldername(storage.objects.name))[2])::uuid
           AND ds.company_id = ((storage.foldername(storage.objects.name))[1])::uuid
           AND ds.deleted_at IS NULL
           AND public.has_role_in(ds.company_id, 'admin'::public.app_role)
    )
);

-- No SELECT, UPDATE, or DELETE policy is provided. Reads are through the
-- claim-bound signer, and cleanup is reserved for a separately reviewed job.
