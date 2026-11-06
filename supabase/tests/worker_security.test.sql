-- Synthetic authorization tests for the restricted worker database APIs.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET search_path TO extensions, public, auth;
SELECT plan(46);

-- Grant postgres temporary membership so SET LOCAL ROLE works in this test
-- transaction (worker roles are least-privilege with no members in production).
GRANT reconciliation_import_worker, reconciliation_matching_worker, reconciliation_scheduler TO postgres;

SELECT ok((SELECT NOT rolsuper AND NOT rolbypassrls AND NOT rolcreatedb AND NOT rolcreaterole
           FROM pg_roles WHERE rolname = 'reconciliation_import_worker'), 'import worker is unprivileged');
SELECT ok((SELECT NOT rolsuper AND NOT rolbypassrls AND NOT rolcreatedb AND NOT rolcreaterole
           FROM pg_roles WHERE rolname = 'reconciliation_matching_worker'), 'matching worker is unprivileged');
SELECT ok(NOT EXISTS (SELECT 1 FROM pg_auth_members m JOIN pg_roles r ON r.oid = m.member WHERE r.rolname = 'reconciliation_import_worker'), 'import worker has no inherited role memberships');
SELECT ok(NOT EXISTS (SELECT 1 FROM pg_auth_members m JOIN pg_roles r ON r.oid = m.member WHERE r.rolname = 'reconciliation_matching_worker'), 'matching worker has no inherited role memberships');
SELECT ok(NOT has_schema_privilege('reconciliation_import_worker', 'public', 'CREATE'), 'import worker cannot create schema objects');
SELECT ok(NOT has_schema_privilege('reconciliation_matching_worker', 'public', 'CREATE'), 'matching worker cannot create schema objects');
SELECT ok(has_database_privilege('reconciliation_import_worker', current_database(), 'CONNECT'), 'import worker can connect to the application database');
SELECT ok(has_database_privilege('reconciliation_matching_worker', current_database(), 'CONNECT'), 'matching worker can connect to the application database');
SELECT ok(NOT has_table_privilege('reconciliation_import_worker', 'public.profiles', 'SELECT'), 'import worker cannot read profiles');
SELECT ok(NOT has_table_privilege('reconciliation_matching_worker', 'public.profiles', 'SELECT'), 'matching worker cannot read profiles');
SELECT ok(NOT has_table_privilege('reconciliation_import_worker', 'public.audit_log', 'DELETE'), 'import worker cannot delete audit history');
SELECT ok(NOT has_table_privilege('reconciliation_matching_worker', 'public.audit_log', 'DELETE'), 'matching worker cannot delete audit history');
SELECT ok(NOT has_table_privilege('reconciliation_import_worker', 'public.reconciliation_encryption_keys', 'SELECT'), 'import worker cannot read key material');
SELECT ok(NOT has_table_privilege('reconciliation_matching_worker', 'public.reconciliation_encryption_keys', 'SELECT'), 'matching worker cannot read key material');
SELECT ok(NOT has_schema_privilege('reconciliation_import_worker', 'extensions', 'USAGE'), 'import worker has no direct extension access');
SELECT ok(NOT has_schema_privilege('reconciliation_matching_worker', 'extensions', 'USAGE'), 'matching worker has no direct extension access');
SELECT ok(has_function_privilege('reconciliation_import_worker', 'public.reconciliation_claim_import_jobs(integer)', 'EXECUTE'), 'import worker can claim only through RPC');
SELECT ok(has_function_privilege('reconciliation_matching_worker', 'public.reconciliation_claim_matching_runs(integer)', 'EXECUTE'), 'matching worker can claim only through RPC');
SELECT ok(NOT has_function_privilege('reconciliation_matching_worker', 'public.reconciliation_heartbeat_import(uuid,uuid)', 'EXECUTE'), 'matching worker cannot renew import leases');
SELECT ok(NOT has_function_privilege('reconciliation_import_worker', 'public.reconciliation_heartbeat_matching_run(uuid,uuid)', 'EXECUTE'), 'import worker cannot renew matching leases');

-- pgTAP assertion functions live in extensions. Grant usage only for the test
-- transaction so worker RPCs run under their real constrained role.
GRANT USAGE ON SCHEMA extensions TO reconciliation_import_worker,
    reconciliation_matching_worker, reconciliation_scheduler;

INSERT INTO public.companies(id, name, slug) VALUES
 ('a1000000-0000-0000-0000-000000000001', 'Synthetic A', 'synthetic-a'),
 ('b2000000-0000-0000-0000-000000000002', 'Synthetic B', 'synthetic-b')
ON CONFLICT DO NOTHING;
INSERT INTO public.reconciliation_import_jobs(id, company_id, status, file_ref)
VALUES ('a3000000-0000-0000-0000-000000000003', 'a1000000-0000-0000-0000-000000000001', 'pending', 'synthetic.csv')
ON CONFLICT DO NOTHING;

SET LOCAL ROLE reconciliation_import_worker;
SELECT set_config('test.import_claim', claim_token::text, true)
  FROM public.reconciliation_claim_import_jobs(1);
SELECT ok(public.reconciliation_import_insert_record(
  'a3000000-0000-0000-0000-000000000003', current_setting('test.import_claim')::uuid,
  'SYN-A-1', '{"name":"Synthetic One"}', '{"name":"Synthetic One"}', 'hash-a1'),
  'import worker can insert a row only for its claimed job');
SELECT ok(public.reconciliation_heartbeat_import('a3000000-0000-0000-0000-000000000003',
  current_setting('test.import_claim')::uuid), 'import worker can renew only its valid lease');
SELECT ok(NOT public.reconciliation_heartbeat_import('a3000000-0000-0000-0000-000000000003',
  'a9000000-0000-0000-0000-000000000009'), 'import worker cannot renew with another claim token');
SELECT throws_ok($$SELECT public.reconciliation_import_insert_record(
  'a3000000-0000-0000-0000-000000000003', 'a9000000-0000-0000-0000-000000000009',
  'SYN-A-invalid', '{}', '{}', 'invalid-token')$$,
  '42501', 'invalid or expired import lease', 'import writes reject invalid claim tokens');
SELECT set_config('test.old_import_claim', current_setting('test.import_claim'), true);
RESET ROLE;
UPDATE public.reconciliation_import_jobs SET lease_until = now() - interval '1 second'
 WHERE id = 'a3000000-0000-0000-0000-000000000003';
SET LOCAL ROLE reconciliation_import_worker;
SELECT ok(NOT public.reconciliation_heartbeat_import('a3000000-0000-0000-0000-000000000003',
  current_setting('test.old_import_claim')::uuid), 'expired import lease cannot be renewed');
SELECT ok(NOT public.reconciliation_finish_import('a3000000-0000-0000-0000-000000000003',
  current_setting('test.old_import_claim')::uuid, 'completed', 1, 0, NULL), 'expired import lease cannot be finished');
SELECT set_config('test.import_claim', claim_token::text, true)
  FROM public.reconciliation_claim_import_jobs(1);
SELECT ok(current_setting('test.import_claim')::uuid <> current_setting('test.old_import_claim')::uuid,
  'missing/expired import ownership is reclaimed with a fresh token');
SELECT set_config('test.expired_import_claim', current_setting('test.import_claim'), true);
RESET ROLE;
UPDATE public.reconciliation_import_jobs SET lease_until = NULL
 WHERE id = 'a3000000-0000-0000-0000-000000000003';
SET LOCAL ROLE reconciliation_import_worker;
SELECT set_config('test.import_claim', claim_token::text, true)
  FROM public.reconciliation_claim_import_jobs(1);
SELECT ok(current_setting('test.import_claim')::uuid <> current_setting('test.expired_import_claim')::uuid,
  'import job with a missing lease is reclaimed instead of stuck');
SELECT ok(public.reconciliation_finish_import('a3000000-0000-0000-0000-000000000003',
  current_setting('test.import_claim')::uuid, 'completed', 1, 0, NULL), 'new import claimant can finish its lease');
SELECT ok(NOT has_table_privilege(current_user, 'public.reconciliation_import_jobs', 'SELECT'), 'import worker cannot directly select jobs');
RESET ROLE;
SELECT set_config('test.record_a', id::text, true) FROM public.reconciliation_source_records WHERE source_record_id = 'SYN-A-1';

INSERT INTO public.reconciliation_source_records(import_job_id, company_id, source_record_id, raw_data, normalized_data, row_hash)
VALUES ('a3000000-0000-0000-0000-000000000003', 'a1000000-0000-0000-0000-000000000001', 'SYN-A-2',
        '{"name":"Synthetic Two"}', '{"name":"Synthetic Two"}', 'hash-a2');
SELECT set_config('test.record_a2', id::text, true) FROM public.reconciliation_source_records WHERE source_record_id = 'SYN-A-2';
INSERT INTO public.reconciliation_import_jobs(id, company_id, status, file_ref)
VALUES ('b3000000-0000-0000-0000-000000000004', 'b2000000-0000-0000-0000-000000000002', 'completed', 'synthetic.csv')
ON CONFLICT DO NOTHING;
INSERT INTO public.reconciliation_source_records(id, import_job_id, company_id, source_record_id, raw_data, normalized_data, row_hash)
VALUES ('b5000000-0000-0000-0000-000000000006', 'b3000000-0000-0000-0000-000000000004', 'b2000000-0000-0000-0000-000000000002', 'SYN-B-1',
        '{"name":"Other Tenant"}', '{"name":"Other Tenant"}', 'hash-b1');
INSERT INTO public.reconciliation_reconciliation_runs(id, company_id, status)
VALUES ('a4000000-0000-0000-0000-000000000005', 'a1000000-0000-0000-0000-000000000001', 'queued');

SET LOCAL ROLE reconciliation_matching_worker;
SELECT set_config('test.match_claim', claim_token::text, true)
  FROM public.reconciliation_claim_matching_runs(1);
SELECT throws_ok($$SELECT * FROM public.reconciliation_matching_source_records(
  'a4000000-0000-0000-0000-000000000005', 'a9000000-0000-0000-0000-000000000009')$$,
  '42501', 'invalid or expired matching lease', 'matching source reads reject invalid claim tokens');
SELECT ok(NOT public.reconciliation_heartbeat_matching_run('a4000000-0000-0000-0000-000000000005',
  'a9000000-0000-0000-0000-000000000009'), 'matching heartbeat rejects another claim token');
SELECT is((SELECT count(*) FROM public.reconciliation_matching_source_records(
  'a4000000-0000-0000-0000-000000000005', current_setting('test.match_claim')::uuid)), 2::bigint,
  'matching worker can read records only for its claimed run tenant');
SELECT ok(public.reconciliation_heartbeat_matching_run('a4000000-0000-0000-0000-000000000005',
  current_setting('test.match_claim')::uuid), 'matching worker can renew only its valid lease');
SELECT is(public.reconciliation_matching_write_candidates(
  'a4000000-0000-0000-0000-000000000005', current_setting('test.match_claim')::uuid,
  jsonb_build_array(jsonb_build_object('a', current_setting('test.record_a'),
    'b', current_setting('test.record_a2'), 'score', 0.99))),
  1, 'matching worker can write candidates for records in its claimed tenant');
SELECT is(public.reconciliation_matching_write_candidates(
  'a4000000-0000-0000-0000-000000000005', current_setting('test.match_claim')::uuid,
  jsonb_build_array(jsonb_build_object('a', current_setting('test.record_a'),
    'b', 'b5000000-0000-0000-0000-000000000006', 'score', 0.99))),
  0, 'matching worker cannot create cross-tenant candidates');
SELECT set_config('test.old_match_claim', current_setting('test.match_claim'), true);
RESET ROLE;
UPDATE public.reconciliation_reconciliation_runs SET lease_until = now() - interval '1 second'
 WHERE id = 'a4000000-0000-0000-0000-000000000005';
SET LOCAL ROLE reconciliation_matching_worker;
SELECT ok(NOT public.reconciliation_heartbeat_matching_run('a4000000-0000-0000-0000-000000000005',
  current_setting('test.old_match_claim')::uuid), 'expired matching lease cannot be renewed');
SELECT ok(NOT public.reconciliation_finish_matching_run(
  'a4000000-0000-0000-0000-000000000005', current_setting('test.old_match_claim')::uuid,
  'completed', 1, 0, NULL), 'expired matching lease cannot be finished');
SELECT set_config('test.match_claim', claim_token::text, true)
  FROM public.reconciliation_claim_matching_runs(1);
SELECT ok(current_setting('test.match_claim')::uuid <> current_setting('test.old_match_claim')::uuid,
  'missing/expired matching ownership is reclaimed with a fresh token');
SELECT set_config('test.expired_match_claim', current_setting('test.match_claim'), true);
RESET ROLE;
UPDATE public.reconciliation_reconciliation_runs SET lease_until = NULL
 WHERE id = 'a4000000-0000-0000-0000-000000000005';
SET LOCAL ROLE reconciliation_matching_worker;
SELECT set_config('test.match_claim', claim_token::text, true)
  FROM public.reconciliation_claim_matching_runs(1);
SELECT ok(current_setting('test.match_claim')::uuid <> current_setting('test.expired_match_claim')::uuid,
  'matching run with a missing lease is reclaimed instead of stuck');
SELECT ok(public.reconciliation_finish_matching_run(
  'a4000000-0000-0000-0000-000000000005', current_setting('test.match_claim')::uuid,
  'completed', 1, 0, NULL), 'new matching claimant can finish its lease');
RESET ROLE;

SELECT ok(NOT has_function_privilege('authenticated', 'public.reconciliation_audit_retention_cleanup()', 'EXECUTE'), 'authenticated cannot invoke audit cleanup');
SELECT ok(NOT has_function_privilege('anon', 'public.reconciliation_audit_retention_cleanup()', 'EXECUTE'), 'anon cannot invoke audit cleanup');
SELECT ok(has_function_privilege('reconciliation_scheduler', 'public.reconciliation_audit_retention_cleanup()', 'EXECUTE'), 'scheduler can invoke audit cleanup');
INSERT INTO public.audit_log(action, company_id, created_at, metadata)
VALUES ('company.created', 'a1000000-0000-0000-0000-000000000001', now() - interval '5 years', '{"synthetic":true}');
SELECT set_config('test.audit_count_before', count(*)::text, true) FROM public.audit_log;
SET LOCAL ROLE reconciliation_scheduler;
SELECT lives_ok($$SELECT public.reconciliation_audit_retention_cleanup()$$, 'scheduler cleanup is a no-op without an approved retention policy');
RESET ROLE;
SELECT is((SELECT count(*)::text FROM public.audit_log), current_setting('test.audit_count_before'), 'historical audit rows remain intact');
SELECT * FROM finish();
ROLLBACK;
