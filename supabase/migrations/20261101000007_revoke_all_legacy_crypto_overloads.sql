-- Local/schema history may contain legacy one-argument overloads not created
-- by the currently tracked migrations. Quarantine every overload by name.
DO $$
DECLARE _function record;
BEGIN
    FOR _function IN
        SELECT p.oid::regprocedure AS signature
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public'
           AND p.proname IN ('reconciliation_encrypt_field', 'reconciliation_decrypt_field')
    LOOP
        EXECUTE format(
            'REVOKE ALL PRIVILEGES ON FUNCTION %s FROM PUBLIC, anon, authenticated, service_role, reconciliation_import_worker, reconciliation_matching_worker, reconciliation_scheduler',
            _function.signature
        );
    END LOOP;
END $$;

