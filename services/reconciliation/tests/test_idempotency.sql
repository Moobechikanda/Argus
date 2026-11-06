-- Try to insert duplicate (same import_job_id, source_record_id, row_hash) -- should fail with unique violation
INSERT INTO public.reconciliation_source_records (
    import_job_id, company_id, source_record_id, raw_data, normalized_data, row_hash
) VALUES (
    '76c4fe3a-725a-43a3-a201-6214392e54f9',
    'ed3fc8df-30ee-427e-81be-d44ca856599c',
    '1',
    '{"nome": "Alice Silva", "email": "alice@example.com", "cpf": "111.111.111-11", "cidade": "São Paulo"}'::jsonb,
    '{"nome": "Alice Silva", "email": "alice@example.com", "cpf": "111.111.111-11", "cidade": "São Paulo"}'::jsonb,
    'aac99fd7f17f8d309f57728c517f9918a8675892b5ca23501770d000ad8457b3'
);

-- Count should still be 5
SELECT COUNT(*) as source_records_count FROM public.reconciliation_source_records WHERE import_job_id = '76c4fe3a-725a-43a3-a201-6214392e54f9';
