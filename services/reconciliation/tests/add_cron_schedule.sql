SELECT cron.schedule(
    'reconciliation-run-queued',
    '*/10 * * * *',
    $$
    SELECT public.log_reconciliation_audit(
        'reconciliation_run.scheduled'::public.audit_action,
        NULL,
        'reconciliation_reconciliation_runs',
        'pg_cron',
        '{"trigger": "pg_cron_queued_runs"}'::jsonb
    );
    $$
);
