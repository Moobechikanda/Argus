INSERT INTO public.reconciliation_import_jobs (company_id, data_source_id, status, file_ref, created_by)
VALUES (
  'ed3fc8df-30ee-427e-81be-d44ca856599c',
  'd607321f-7b3e-4962-b24e-3f939dadcaa4',
  'pending',
  '/tmp/clientes.csv',
  '11111111-1111-1111-1111-111111111111'
)
RETURNING id, status, file_ref;
