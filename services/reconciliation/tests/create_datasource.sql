INSERT INTO public.reconciliation_data_sources (company_id, name, source_type, connection_config, created_by)
VALUES (
  'ed3fc8df-30ee-427e-81be-d44ca856599c',
  'Clientes CSV',
  'file',
  '{"file_path": "/tmp/clientes.csv"}'::jsonb,
  '11111111-1111-1111-1111-111111111111'
)
RETURNING id, name, company_id;
