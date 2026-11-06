-- Least-privilege database boundary for reconciliation workers and audit retention.
-- Worker logins receive EXECUTE on narrowly-scoped RPCs only; they receive no
-- direct table, schema, role-management, BYPASSRLS, or key-table privileges.

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'reconciliation_import_worker') THEN
        CREATE ROLE reconciliation_import_worker LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'reconciliation_matching_worker') THEN
        CREATE ROLE reconciliation_matching_worker LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'reconciliation_scheduler') THEN
        CREATE ROLE reconciliation_scheduler NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS;
    END IF;
END $$;
-- Avoid ALTER ROLE attribute changes here: managed Supabase migration users
-- are not superusers. Fail closed if a pre-existing role is not least-privilege.
DO $$
DECLARE _role record;
BEGIN
    FOR _role IN
        SELECT oid, rolname, rolsuper, rolcreatedb, rolcreaterole, rolinherit, rolbypassrls, rolcanlogin
          FROM pg_roles
         WHERE rolname IN ('reconciliation_import_worker', 'reconciliation_matching_worker')
    LOOP
        IF _role.rolsuper OR _role.rolcreatedb OR _role.rolcreaterole OR _role.rolinherit
           OR _role.rolbypassrls OR NOT _role.rolcanlogin
           OR EXISTS (SELECT 1 FROM pg_auth_members am WHERE am.member = _role.oid) THEN
            RAISE EXCEPTION 'worker role % exists with unsafe attributes; provision it securely before migration', _role.rolname;
        END IF;
    END LOOP;
END $$;

-- The earlier reconciliation migrations schedule these audit actions but do
-- not add them to the base audit_action enum. Add them before those jobs run.
DO $$ BEGIN
    ALTER TYPE public.audit_action ADD VALUE 'import_job.scheduled';
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
    ALTER TYPE public.audit_action ADD VALUE 'reconciliation_run.scheduled';
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
    ALTER TYPE public.audit_action ADD VALUE 'audit_log.retention_cleanup';
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

ALTER TABLE public.reconciliation_import_jobs
    ADD COLUMN IF NOT EXISTS claim_token uuid,
    ADD COLUMN IF NOT EXISTS lease_until timestamptz;
ALTER TABLE public.reconciliation_reconciliation_runs
    ADD COLUMN IF NOT EXISTS claim_token uuid,
    ADD COLUMN IF NOT EXISTS lease_until timestamptz;

-- Retention is disabled until an institutionally approved policy is inserted.
CREATE TABLE IF NOT EXISTS public.reconciliation_audit_retention_policy (
    singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
    retention_days integer CHECK (retention_days BETWEEN 1 AND 36500),
    approved_by text,
    approved_at timestamptz,
    CHECK ((retention_days IS NULL) OR (approved_by IS NOT NULL AND approved_at IS NOT NULL))
);
INSERT INTO public.reconciliation_audit_retention_policy(singleton, retention_days)
VALUES (true, NULL) ON CONFLICT (singleton) DO NOTHING;
ALTER TABLE public.reconciliation_audit_retention_policy ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reconciliation_audit_retention_policy FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.reconciliation_audit_retention_policy FROM PUBLIC, anon, authenticated,
    reconciliation_import_worker, reconciliation_matching_worker, reconciliation_scheduler;

-- SECURITY DEFINER RPCs are owned by the migration owner (postgres on Supabase).
-- Worker roles can execute these wrappers only; input IDs are checked against a
-- live lease, and tenant IDs are always derived from the claimed parent row.
CREATE OR REPLACE FUNCTION public.reconciliation_claim_import_jobs(_limit integer DEFAULT 1)
RETURNS TABLE(id uuid, company_id uuid, data_source_id uuid, file_ref text, created_by uuid, claim_token uuid)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
    IF _limit < 1 OR _limit > 10 THEN RAISE EXCEPTION 'invalid claim limit'; END IF;
    UPDATE public.reconciliation_import_jobs j
       SET status = 'pending', claim_token = NULL, lease_until = NULL, started_at = NULL
     WHERE j.status = 'running' AND j.lease_until < now();
    RETURN QUERY
    WITH picked AS (
        SELECT j.id FROM public.reconciliation_import_jobs j
         WHERE j.status = 'pending'
         ORDER BY j.created_at FOR UPDATE SKIP LOCKED LIMIT _limit
    ), claimed AS (
        UPDATE public.reconciliation_import_jobs j
           SET status = 'running', started_at = now(), claim_token = extensions.gen_random_uuid(),
               lease_until = now() + interval '30 minutes'
          FROM picked p WHERE j.id = p.id
        RETURNING j.id, j.company_id, j.data_source_id, j.file_ref, j.created_by, j.claim_token
    ), logged AS (
        INSERT INTO public.audit_log(actor_user_id, company_id, action, target_table, target_id, metadata)
        SELECT c.created_by, c.company_id, 'import_job.started'::public.audit_action,
               'reconciliation_import_jobs', c.id::text, '{}'::jsonb FROM claimed c
        RETURNING 1
    ) SELECT c.id, c.company_id, c.data_source_id, c.file_ref, c.created_by, c.claim_token
        FROM claimed c CROSS JOIN (SELECT count(*) FROM logged) audit_rows;
END $$;

CREATE OR REPLACE FUNCTION public.reconciliation_import_insert_record(
    _job_id uuid, _claim_token uuid, _source_record_id text, _raw_data jsonb,
    _normalized_data jsonb, _row_hash text
) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE _company_id uuid; _inserted boolean := false; _written integer;
BEGIN
    SELECT j.company_id INTO _company_id FROM public.reconciliation_import_jobs j
     WHERE j.id = _job_id AND j.status = 'running' AND j.claim_token = _claim_token
       AND j.lease_until > now() FOR UPDATE;
    IF _company_id IS NULL THEN RAISE EXCEPTION 'invalid or expired import lease' USING ERRCODE = '42501'; END IF;
    INSERT INTO public.reconciliation_source_records(import_job_id, company_id, source_record_id, raw_data, normalized_data, row_hash)
    VALUES (_job_id, _company_id, _source_record_id, COALESCE(_raw_data, '{}'::jsonb),
            COALESCE(_normalized_data, '{}'::jsonb), _row_hash)
    ON CONFLICT (import_job_id, source_record_id, row_hash) DO NOTHING;
    GET DIAGNOSTICS _written = ROW_COUNT;
    _inserted := _written > 0;
    UPDATE public.reconciliation_import_jobs SET lease_until = now() + interval '30 minutes'
     WHERE id = _job_id AND claim_token = _claim_token;
    RETURN _inserted;
END $$;

CREATE OR REPLACE FUNCTION public.reconciliation_heartbeat_import(_job_id uuid, _claim_token uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
    UPDATE public.reconciliation_import_jobs SET lease_until = now() + interval '30 minutes'
     WHERE id = _job_id AND status = 'running' AND claim_token = _claim_token AND lease_until > now();
    RETURN FOUND;
END $$;

CREATE OR REPLACE FUNCTION public.reconciliation_finish_import(
    _job_id uuid, _claim_token uuid, _status text, _row_count integer,
    _error_count integer, _error text DEFAULT NULL
) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE _company_id uuid; _action public.audit_action;
BEGIN
    IF _status NOT IN ('completed', 'failed') THEN RAISE EXCEPTION 'invalid terminal status'; END IF;
    UPDATE public.reconciliation_import_jobs j
       SET status = _status::public.reconciliation_import_status, completed_at = now(),
           row_count = _row_count, error_count = _error_count, error = left(_error, 10000),
           lease_until = NULL, claim_token = NULL
     WHERE j.id = _job_id AND j.status = 'running' AND j.claim_token = _claim_token
     RETURNING j.company_id INTO _company_id;
    IF _company_id IS NULL THEN RETURN false; END IF;
    _action := CASE WHEN _status = 'completed' THEN 'import_job.completed'::public.audit_action
                    ELSE 'import_job.failed'::public.audit_action END;
    PERFORM public.log_reconciliation_audit(_action, _company_id, 'reconciliation_import_jobs',
        _job_id::text, jsonb_build_object('row_count', _row_count, 'error_count', _error_count));
    RETURN true;
END $$;

CREATE OR REPLACE FUNCTION public.reconciliation_claim_matching_runs(_limit integer DEFAULT 1)
RETURNS TABLE(id uuid, company_id uuid, blocking_rules jsonb, comparison_config jsonb, claim_token uuid)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
    IF _limit < 1 OR _limit > 10 THEN RAISE EXCEPTION 'invalid claim limit'; END IF;
    UPDATE public.reconciliation_reconciliation_runs r
       SET status = 'queued', claim_token = NULL, lease_until = NULL, started_at = NULL
     WHERE r.status = 'running' AND r.lease_until < now();
    RETURN QUERY
    WITH picked AS (
        SELECT r.id FROM public.reconciliation_reconciliation_runs r
         WHERE r.status = 'queued'
         ORDER BY r.created_at FOR UPDATE SKIP LOCKED LIMIT _limit
    ), claimed AS (
        UPDATE public.reconciliation_reconciliation_runs r
           SET status = 'running', started_at = now(), claim_token = extensions.gen_random_uuid(),
               lease_until = now() + interval '30 minutes'
          FROM picked p WHERE r.id = p.id
        RETURNING r.id, r.company_id, r.blocking_rules, r.comparison_config, r.claim_token
    ), logged AS (
        INSERT INTO public.audit_log(actor_user_id, company_id, action, target_table, target_id, metadata)
        SELECT r.created_by, c.company_id, 'reconciliation_run.started'::public.audit_action,
               'reconciliation_reconciliation_runs', c.id::text, '{}'::jsonb
          FROM claimed c JOIN public.reconciliation_reconciliation_runs r ON r.id = c.id
        RETURNING 1
    ) SELECT c.id, c.company_id, c.blocking_rules, c.comparison_config, c.claim_token
        FROM claimed c CROSS JOIN (SELECT count(*) FROM logged) audit_rows;
END $$;

CREATE OR REPLACE FUNCTION public.reconciliation_matching_source_records(_run_id uuid, _claim_token uuid)
RETURNS TABLE(id uuid, source_record_id text, raw_data jsonb, normalized_data jsonb)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE _company_id uuid;
BEGIN
    SELECT r.company_id INTO _company_id FROM public.reconciliation_reconciliation_runs r
     WHERE r.id = _run_id AND r.status = 'running' AND r.claim_token = _claim_token AND r.lease_until > now();
    IF _company_id IS NULL THEN RAISE EXCEPTION 'invalid or expired matching lease' USING ERRCODE = '42501'; END IF;
    RETURN QUERY SELECT s.id, s.source_record_id, s.raw_data, s.normalized_data
      FROM public.reconciliation_source_records s WHERE s.company_id = _company_id ORDER BY s.created_at;
END $$;

CREATE OR REPLACE FUNCTION public.reconciliation_heartbeat_matching_run(_run_id uuid, _claim_token uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
    UPDATE public.reconciliation_reconciliation_runs SET lease_until = now() + interval '30 minutes'
     WHERE id = _run_id AND status = 'running' AND claim_token = _claim_token AND lease_until > now();
    RETURN FOUND;
END $$;

CREATE OR REPLACE FUNCTION public.reconciliation_matching_write_candidates(
    _run_id uuid, _claim_token uuid, _candidates jsonb
) RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE _company_id uuid; _written integer;
BEGIN
    SELECT r.company_id INTO _company_id FROM public.reconciliation_reconciliation_runs r
     WHERE r.id = _run_id AND r.status = 'running' AND r.claim_token = _claim_token AND r.lease_until > now() FOR UPDATE;
    IF _company_id IS NULL THEN RAISE EXCEPTION 'invalid or expired matching lease' USING ERRCODE = '42501'; END IF;
    INSERT INTO public.reconciliation_match_candidates(company_id, record_a_id, record_b_id, match_score, comparison_details, status)
    SELECT _company_id, c.a, c.b, c.score, COALESCE(c.details, '{}'::jsonb), 'pending'
      FROM jsonb_to_recordset(COALESCE(_candidates, '[]'::jsonb)) AS c(a uuid, b uuid, score double precision, details jsonb)
      JOIN public.reconciliation_source_records a ON a.id = c.a AND a.company_id = _company_id
      JOIN public.reconciliation_source_records b ON b.id = c.b AND b.company_id = _company_id
     WHERE c.a <> c.b
    ON CONFLICT (record_a_id, record_b_id) WHERE status = 'pending' DO NOTHING;
    GET DIAGNOSTICS _written = ROW_COUNT;
    UPDATE public.reconciliation_reconciliation_runs SET lease_until = now() + interval '30 minutes'
     WHERE id = _run_id AND claim_token = _claim_token;
    RETURN _written;
END $$;

CREATE OR REPLACE FUNCTION public.reconciliation_finish_matching_run(
    _run_id uuid, _claim_token uuid, _status text, _pairs integer, _matches integer, _error text DEFAULT NULL
) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE _company_id uuid;
BEGIN
    IF _status NOT IN ('completed', 'failed') THEN RAISE EXCEPTION 'invalid terminal status'; END IF;
    UPDATE public.reconciliation_reconciliation_runs r
       SET status = _status, completed_at = now(), record_pairs_compared = _pairs,
           matches_found = _matches, error = left(_error, 10000), lease_until = NULL, claim_token = NULL
     WHERE r.id = _run_id AND r.status = 'running' AND r.claim_token = _claim_token
     RETURNING r.company_id INTO _company_id;
    IF _company_id IS NULL THEN RETURN false; END IF;
    PERFORM public.log_reconciliation_audit(
        CASE WHEN _status = 'completed' THEN 'reconciliation_run.completed'::public.audit_action
             ELSE 'reconciliation_run.failed'::public.audit_action END,
        _company_id, 'reconciliation_reconciliation_runs', _run_id::text,
        jsonb_build_object('pairs', _pairs, 'matches', _matches));
    RETURN true;
END $$;

-- Remove direct worker access, including inherited defaults, and grant only RPCs.
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM reconciliation_import_worker, reconciliation_matching_worker;
REVOKE ALL ON SCHEMA public FROM reconciliation_import_worker, reconciliation_matching_worker;
GRANT USAGE ON SCHEMA public TO reconciliation_import_worker, reconciliation_matching_worker;
GRANT CONNECT ON DATABASE postgres TO reconciliation_import_worker, reconciliation_matching_worker;
REVOKE ALL ON FUNCTION public.reconciliation_audit_retention_cleanup() FROM authenticated, anon, PUBLIC;
REVOKE EXECUTE ON FUNCTION public.reconciliation_claim_import_jobs(integer),
    public.reconciliation_import_insert_record(uuid,uuid,text,jsonb,jsonb,text),
    public.reconciliation_heartbeat_import(uuid,uuid),
    public.reconciliation_finish_import(uuid,uuid,text,integer,integer,text),
    public.reconciliation_claim_matching_runs(integer),
    public.reconciliation_matching_source_records(uuid,uuid),
    public.reconciliation_heartbeat_matching_run(uuid,uuid),
    public.reconciliation_matching_write_candidates(uuid,uuid,jsonb),
    public.reconciliation_finish_matching_run(uuid,uuid,text,integer,integer,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reconciliation_claim_import_jobs(integer),
    public.reconciliation_import_insert_record(uuid,uuid,text,jsonb,jsonb,text),
    public.reconciliation_heartbeat_import(uuid,uuid),
    public.reconciliation_finish_import(uuid,uuid,text,integer,integer,text) TO reconciliation_import_worker;
GRANT EXECUTE ON FUNCTION public.reconciliation_claim_matching_runs(integer),
    public.reconciliation_matching_source_records(uuid,uuid),
    public.reconciliation_heartbeat_matching_run(uuid,uuid),
    public.reconciliation_matching_write_candidates(uuid,uuid,jsonb),
    public.reconciliation_finish_matching_run(uuid,uuid,text,integer,integer,text) TO reconciliation_matching_worker;

-- Scheduler can invoke only the controlled cleanup wrapper. Retention is a no-op
-- until a policy is explicitly approved and recorded by an administrator.
CREATE OR REPLACE FUNCTION public.reconciliation_audit_retention_cleanup()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE _days integer; _deleted bigint;
BEGIN
    SELECT retention_days INTO _days FROM public.reconciliation_audit_retention_policy WHERE singleton;
    IF _days IS NULL THEN RETURN; END IF;
    DELETE FROM public.audit_log WHERE created_at < now() - make_interval(days => _days);
    GET DIAGNOSTICS _deleted = ROW_COUNT;
    PERFORM public.log_reconciliation_audit('audit_log.retention_cleanup'::public.audit_action,
        NULL, 'audit_log', 'scheduler', jsonb_build_object('retention_days', _days, 'deleted_rows', _deleted));
    RETURN;
END $$;
ALTER FUNCTION public.reconciliation_audit_retention_cleanup() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.reconciliation_audit_retention_cleanup() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.reconciliation_audit_retention_cleanup() TO reconciliation_scheduler;

-- Fixed ownership/search_path and role-specific EXECUTE permissions.
ALTER FUNCTION public.reconciliation_claim_import_jobs(integer) OWNER TO postgres;
ALTER FUNCTION public.reconciliation_import_insert_record(uuid,uuid,text,jsonb,jsonb,text) OWNER TO postgres;
ALTER FUNCTION public.reconciliation_heartbeat_import(uuid,uuid) OWNER TO postgres;
ALTER FUNCTION public.reconciliation_finish_import(uuid,uuid,text,integer,integer,text) OWNER TO postgres;
ALTER FUNCTION public.reconciliation_claim_matching_runs(integer) OWNER TO postgres;
ALTER FUNCTION public.reconciliation_matching_source_records(uuid,uuid) OWNER TO postgres;
ALTER FUNCTION public.reconciliation_heartbeat_matching_run(uuid,uuid) OWNER TO postgres;
ALTER FUNCTION public.reconciliation_matching_write_candidates(uuid,uuid,jsonb) OWNER TO postgres;
ALTER FUNCTION public.reconciliation_finish_matching_run(uuid,uuid,text,integer,integer,text) OWNER TO postgres;

COMMENT ON TABLE public.reconciliation_audit_retention_policy IS
    'Retention is disabled until an approved retention_days policy and approver are recorded.';

-- Run the existing pg_cron job under the dedicated NOLOGIN scheduler role.
SELECT cron.alter_job(jobid,
    command => 'SET ROLE reconciliation_scheduler; SELECT public.reconciliation_audit_retention_cleanup(); RESET ROLE;')
FROM cron.job WHERE jobname = 'reconciliation-audit-retention';
