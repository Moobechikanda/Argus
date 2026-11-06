-- Immediate containment for the prototype database-held field-encryption keys.
-- The current import/matching paths do not use these functions or columns, so
-- revoke access instead of exposing a caller-supplied ciphertext/company API.

ALTER TABLE public.reconciliation_encryption_keys ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reconciliation_encryption_keys FORCE ROW LEVEL SECURITY;

DO $$
DECLARE _policy record;
BEGIN
    FOR _policy IN
        SELECT policyname FROM pg_policies
         WHERE schemaname = 'public'
           AND tablename = 'reconciliation_encryption_keys'
    LOOP
        EXECUTE format('DROP POLICY %I ON public.reconciliation_encryption_keys', _policy.policyname);
    END LOOP;
END $$;

REVOKE ALL PRIVILEGES ON TABLE public.reconciliation_encryption_keys
    FROM PUBLIC, anon, authenticated, service_role,
         reconciliation_import_worker, reconciliation_matching_worker,
         reconciliation_scheduler;
REVOKE SELECT (key), INSERT (key), UPDATE (key), REFERENCES (key)
    ON TABLE public.reconciliation_encryption_keys
    FROM PUBLIC, anon, authenticated, service_role,
         reconciliation_import_worker, reconciliation_matching_worker,
         reconciliation_scheduler;

-- Retain the legacy function objects for migration compatibility, but make
-- their arbitrary-company/ciphertext APIs unavailable to application roles.
REVOKE ALL PRIVILEGES ON FUNCTION public.reconciliation_encrypt_field(text, uuid)
    FROM PUBLIC, anon, authenticated, service_role,
         reconciliation_import_worker, reconciliation_matching_worker,
         reconciliation_scheduler;
REVOKE ALL PRIVILEGES ON FUNCTION public.reconciliation_decrypt_field(bytea, uuid)
    FROM PUBLIC, anon, authenticated, service_role,
         reconciliation_import_worker, reconciliation_matching_worker,
         reconciliation_scheduler;
ALTER FUNCTION public.reconciliation_encrypt_field(text, uuid) OWNER TO postgres;
ALTER FUNCTION public.reconciliation_decrypt_field(bytea, uuid) OWNER TO postgres;

COMMENT ON TABLE public.reconciliation_encryption_keys IS
    'Legacy prototype key material quarantined from application roles; not an approved production key-management system.';

-- The general audit helper is callable by authenticated application code, so
-- require the caller to belong to the supplied tenant. Trigger-generated
-- events may run after membership deletion; only trusted database triggers
-- are allowed that narrow exception (application users have no trigger DDL).
CREATE OR REPLACE FUNCTION public.log_audit(
    _action         public.audit_action,
    _company_id     uuid    DEFAULT NULL,
    _target_user_id uuid    DEFAULT NULL,
    _target_table   text    DEFAULT NULL,
    _target_id      text    DEFAULT NULL,
    _metadata       jsonb   DEFAULT '{}'::jsonb
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    _id bigint;
    _ip inet;
    _ua text;
BEGIN
    IF auth.role() = 'authenticated' THEN
        IF auth.uid() IS NULL
           OR _company_id IS NULL
           OR (pg_trigger_depth() = 0 AND NOT public.is_member_of(_company_id)) THEN
            RAISE EXCEPTION 'not authorized to write audit event for this tenant'
                USING ERRCODE = '42501';
        END IF;
    ELSIF auth.role() <> 'service_role' AND pg_trigger_depth() = 0 THEN
        RAISE EXCEPTION 'not authorized to write audit events'
            USING ERRCODE = '42501';
    END IF;

    BEGIN
        _ip := nullif(current_setting('request.headers', true)::jsonb ->> 'x-forwarded-for', '')::inet;
    EXCEPTION WHEN OTHERS THEN
        _ip := NULL;
    END;
    BEGIN
        _ua := current_setting('request.headers', true)::jsonb ->> 'user-agent';
    EXCEPTION WHEN OTHERS THEN
        _ua := NULL;
    END;

    INSERT INTO public.audit_log (
        actor_user_id, company_id, action, target_user_id, target_table, target_id,
        ip_address, user_agent, metadata
    ) VALUES (
        auth.uid(), _company_id, _action, _target_user_id, _target_table, _target_id,
        _ip, _ua, COALESCE(_metadata, '{}'::jsonb)
    ) RETURNING id INTO _id;
    RETURN _id;
END;
$$;
ALTER FUNCTION public.log_audit(public.audit_action, uuid, uuid, text, text, jsonb) OWNER TO postgres;
REVOKE ALL PRIVILEGES ON FUNCTION public.log_audit(public.audit_action, uuid, uuid, text, text, jsonb)
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.log_audit(public.audit_action, uuid, uuid, text, text, jsonb)
    TO authenticated, service_role;

-- This helper is intended only for trusted SECURITY DEFINER workflow RPCs.
REVOKE ALL PRIVILEGES ON FUNCTION public.log_reconciliation_audit(public.audit_action, uuid, text, text, jsonb)
    FROM PUBLIC, anon, authenticated, service_role,
         reconciliation_import_worker, reconciliation_matching_worker,
         reconciliation_scheduler;

