BEGIN;
SELECT plan(21);

SELECT ok(
    (SELECT relrowsecurity AND relforcerowsecurity
       FROM pg_class WHERE oid = 'public.reconciliation_encryption_keys'::regclass),
    'key table uses enabled and forced RLS'
);
SELECT is(
    (SELECT count(*)::integer FROM pg_policies
      WHERE schemaname = 'public' AND tablename = 'reconciliation_encryption_keys'),
    0,
    'key table has no application-facing RLS policies'
);
SELECT ok(NOT has_table_privilege('anon', 'public.reconciliation_encryption_keys', 'SELECT'), 'anon cannot read key table');
SELECT ok(NOT has_table_privilege('authenticated', 'public.reconciliation_encryption_keys', 'SELECT'), 'authenticated cannot read key table');
SELECT ok(NOT has_table_privilege('authenticated', 'public.reconciliation_encryption_keys', 'INSERT'), 'tenant admins cannot insert key rows');
SELECT ok(NOT has_table_privilege('authenticated', 'public.reconciliation_encryption_keys', 'UPDATE'), 'tenant admins cannot update key rows');
SELECT ok(NOT has_table_privilege('authenticated', 'public.reconciliation_encryption_keys', 'DELETE'), 'tenant admins cannot delete key rows');
SELECT ok(NOT has_column_privilege('authenticated', 'public.reconciliation_encryption_keys', 'key', 'SELECT'), 'tenant members cannot read key bytes by column grant');
SELECT ok(NOT has_table_privilege('service_role', 'public.reconciliation_encryption_keys', 'SELECT'), 'service_role cannot read prototype key material');
SELECT ok(NOT has_table_privilege('reconciliation_import_worker', 'public.reconciliation_encryption_keys', 'SELECT'), 'import worker cannot read key material');
SELECT ok(NOT has_table_privilege('reconciliation_matching_worker', 'public.reconciliation_encryption_keys', 'SELECT'), 'matching worker cannot read key material');
SELECT ok(NOT has_function_privilege('authenticated', 'public.reconciliation_encrypt_field(text,uuid)', 'EXECUTE'), 'authenticated cannot invoke legacy encryption function');
SELECT ok(NOT has_function_privilege('authenticated', 'public.reconciliation_decrypt_field(bytea,uuid)', 'EXECUTE'), 'authenticated cannot invoke legacy decryption function');
SELECT ok(NOT has_function_privilege('service_role', 'public.reconciliation_decrypt_field(bytea,uuid)', 'EXECUTE'), 'service_role cannot invoke arbitrary-ciphertext decryption function');
SELECT is(
    (SELECT count(*)::integer
       FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public'
        AND p.proname IN ('reconciliation_encrypt_field', 'reconciliation_decrypt_field')
        AND (has_function_privilege('anon', p.oid, 'EXECUTE')
          OR has_function_privilege('authenticated', p.oid, 'EXECUTE')
          OR has_function_privilege('service_role', p.oid, 'EXECUTE'))),
    0,
    'no legacy crypto overload is executable by application roles'
);
SELECT ok(NOT has_function_privilege('authenticated', 'public.log_reconciliation_audit(public.audit_action,uuid,text,text,jsonb)', 'EXECUTE'), 'authenticated cannot forge reconciliation audit events');
SELECT ok(NOT has_table_privilege('authenticated', 'public.audit_log', 'DELETE'), 'authenticated cannot delete audit records');
SELECT ok(NOT has_table_privilege('authenticated', 'public.audit_log', 'INSERT'), 'authenticated cannot forge audit rows through table insert');
SELECT ok(NOT has_table_privilege('authenticated', 'public.audit_log', 'UPDATE'), 'authenticated cannot rewrite audit rows');
SELECT ok(NOT has_table_privilege('authenticated', 'public.reconciliation_audit_retention_policy', 'UPDATE'), 'tenant users cannot manipulate retention policy');

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.role', 'authenticated', true);
SELECT set_config('request.jwt.claim.sub', 'f1000000-0000-0000-0000-000000000001', true);
SELECT throws_ok(
    $$SELECT public.log_audit('match.accepted'::public.audit_action,
         'f2000000-0000-0000-0000-000000000002'::uuid, NULL,
         'reconciliation_match_candidates', 'fake-target', '{}'::jsonb)$$,
    '42501',
    'not authorized to write audit event for this tenant',
    'authenticated member cannot forge an audit event for a different tenant'
);
RESET ROLE;
SELECT * FROM finish();
ROLLBACK;
