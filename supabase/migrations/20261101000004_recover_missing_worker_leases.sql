-- A running row with no lease expiration cannot be owned and must be recoverable.
CREATE OR REPLACE FUNCTION public.reconciliation_claim_import_jobs(_limit integer DEFAULT 1)
RETURNS TABLE(id uuid, company_id uuid, data_source_id uuid, file_ref text, created_by uuid, claim_token uuid)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
    IF _limit < 1 OR _limit > 10 THEN RAISE EXCEPTION 'invalid claim limit'; END IF;
    UPDATE public.reconciliation_import_jobs j
       SET status = 'pending', claim_token = NULL, lease_until = NULL, started_at = NULL
     WHERE j.status = 'running' AND (j.lease_until IS NULL OR j.lease_until <= now());
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

CREATE OR REPLACE FUNCTION public.reconciliation_claim_matching_runs(_limit integer DEFAULT 1)
RETURNS TABLE(id uuid, company_id uuid, blocking_rules jsonb, comparison_config jsonb, claim_token uuid)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
    IF _limit < 1 OR _limit > 10 THEN RAISE EXCEPTION 'invalid claim limit'; END IF;
    UPDATE public.reconciliation_reconciliation_runs r
       SET status = 'queued', claim_token = NULL, lease_until = NULL, started_at = NULL
     WHERE r.status = 'running' AND (r.lease_until IS NULL OR r.lease_until <= now());
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

CREATE OR REPLACE FUNCTION public.reconciliation_finish_matching_run(
    _run_id uuid, _claim_token uuid, _status text, _pairs integer, _matches integer, _error text DEFAULT NULL
) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE _company_id uuid;
BEGIN
    IF _status NOT IN ('completed', 'failed') THEN RAISE EXCEPTION 'invalid terminal status'; END IF;
    IF _pairs < 0 OR _matches < 0 THEN RAISE EXCEPTION 'invalid matching counts'; END IF;
    UPDATE public.reconciliation_reconciliation_runs r
       SET status = _status, completed_at = now(), record_pairs_compared = _pairs,
           matches_found = _matches, error = left(_error, 1000), lease_until = NULL, claim_token = NULL
     WHERE r.id = _run_id AND r.status = 'running' AND r.claim_token = _claim_token
       AND r.lease_until > now()
     RETURNING r.company_id INTO _company_id;
    IF _company_id IS NULL THEN RETURN false; END IF;
    PERFORM public.log_reconciliation_audit(
        CASE WHEN _status = 'completed' THEN 'reconciliation_run.completed'::public.audit_action
             ELSE 'reconciliation_run.failed'::public.audit_action END,
        _company_id, 'reconciliation_reconciliation_runs', _run_id::text,
        jsonb_build_object('pairs', _pairs, 'matches', _matches));
    RETURN true;
END $$;

ALTER FUNCTION public.reconciliation_claim_import_jobs(integer) OWNER TO postgres;
ALTER FUNCTION public.reconciliation_claim_matching_runs(integer) OWNER TO postgres;
ALTER FUNCTION public.reconciliation_finish_matching_run(uuid,uuid,text,integer,integer,text) OWNER TO postgres;

