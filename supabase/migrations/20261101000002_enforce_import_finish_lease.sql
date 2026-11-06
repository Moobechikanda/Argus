-- A stale claimant must not be able to finalize after its lease expires.
CREATE OR REPLACE FUNCTION public.reconciliation_finish_import(
    _job_id uuid, _claim_token uuid, _status text, _row_count integer,
    _error_count integer, _error text DEFAULT NULL
) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE _company_id uuid; _action public.audit_action;
BEGIN
    IF _status NOT IN ('completed', 'failed') THEN RAISE EXCEPTION 'invalid terminal status'; END IF;
    IF _row_count < 0 OR _error_count < 0 THEN RAISE EXCEPTION 'invalid import counts'; END IF;
    UPDATE public.reconciliation_import_jobs j
       SET status = _status::public.reconciliation_import_status, completed_at = now(),
           row_count = _row_count, error_count = _error_count, error = left(_error, 10000),
           lease_until = NULL, claim_token = NULL
     WHERE j.id = _job_id AND j.status = 'running' AND j.claim_token = _claim_token
       AND j.lease_until > now()
     RETURNING j.company_id INTO _company_id;
    IF _company_id IS NULL THEN RETURN false; END IF;
    _action := CASE WHEN _status = 'completed' THEN 'import_job.completed'::public.audit_action
                    ELSE 'import_job.failed'::public.audit_action END;
    PERFORM public.log_reconciliation_audit(_action, _company_id, 'reconciliation_import_jobs',
        _job_id::text, jsonb_build_object('row_count', _row_count, 'error_count', _error_count));
    RETURN true;
END $$;
ALTER FUNCTION public.reconciliation_finish_import(uuid,uuid,text,integer,integer,text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.reconciliation_finish_import(uuid,uuid,text,integer,integer,text)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reconciliation_finish_import(uuid,uuid,text,integer,integer,text)
    TO reconciliation_import_worker;
