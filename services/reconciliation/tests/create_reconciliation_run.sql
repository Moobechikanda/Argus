INSERT INTO public.reconciliation_reconciliation_runs (
    company_id, status, blocking_rules, comparison_config, created_by
) VALUES (
    'ed3fc8df-30ee-427e-81be-d44ca856599c',
    'queued',
    '[{"field": "cpf", "op": "exact"}]'::jsonb,
    '{"nome": "levenshtein", "cidade": "exact"}'::jsonb,
    '11111111-1111-1111-1111-111111111111'
)
RETURNING id, status;
