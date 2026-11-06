-- Preserve authenticated audit reads, but make append-only mutation explicit
-- in ACLs as well as RLS. Trusted SECURITY DEFINER wrappers remain functional.
REVOKE INSERT, UPDATE, DELETE ON TABLE public.audit_log
    FROM PUBLIC, anon, authenticated, service_role,
         reconciliation_import_worker, reconciliation_matching_worker,
         reconciliation_scheduler;

