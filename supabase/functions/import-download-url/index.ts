import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.49.1';

const bucket = 'reconciliation-imports';
const maxUrlSeconds = 60;
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(async (request: Request) => {
  if (request.method !== 'POST') return new Response('method not allowed', { status: 405 });
  const auth = request.headers.get('authorization') ?? '';
  const apiKey = request.headers.get('apikey') ?? '';
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const url = Deno.env.get('SUPABASE_URL');
  if (!serviceKey || !url || !apiKey) return new Response('signer unavailable', { status: 503 });

  let body: { job_id?: unknown };
  try { body = await request.json(); } catch { return new Response('invalid request', { status: 400 }); }
  const bearer = auth.match(/^Bearer ([0-9a-f-]{36})$/i)?.[1];
  const jobId = typeof body.job_id === 'string' ? body.job_id : '';
  if (!bearer || !uuid.test(bearer) || !uuid.test(jobId)) return new Response('invalid claim', { status: 401 });

  // Worker credentials are only an API identifier; possession of a live,
  // random claim token is the authorization capability. No user JWT is used.
  const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: job, error } = await admin.from('reconciliation_import_jobs')
    .select('id, company_id, data_source_id, file_ref, status, claim_token, lease_until')
    .eq('id', jobId).maybeSingle();
  if (error || !job || job.status !== 'running' || job.claim_token !== bearer ||
      !job.lease_until || Date.parse(job.lease_until) <= Date.now() ||
      !job.data_source_id || typeof job.file_ref !== 'string') {
    return new Response('claim is not active', { status: 403 });
  }
  const parts = job.file_ref.split('/');
  if (parts.length !== 3 || parts[0] !== job.company_id || parts[1] !== job.data_source_id ||
      !uuid.test(parts[0]) || !uuid.test(parts[1]) || !/^[0-9a-f-]{36}\.(csv|json|jsonl)$/i.test(parts[2])) {
    return new Response('invalid object reference', { status: 403 });
  }
  const { data: signed, error: signError } = await admin.storage.from(bucket)
    .createSignedUrl(job.file_ref, maxUrlSeconds, { download: parts[2] });
  if (signError || !signed?.signedUrl) return new Response('object unavailable', { status: 404 });
  const signedUrl = new URL(signed.signedUrl);
  const signedPath = signedUrl.pathname + signedUrl.search;
  if (!signedPath.startsWith('/storage/v1/object/sign/reconciliation-imports/')) {
    return new Response('invalid signed object path', { status: 500 });
  }
  // Return only a relative Storage path. Workers construct the URL using their
  // configured Supabase origin rather than trusting the Edge network hostname.
  return Response.json({ path: signedPath, expires_in: maxUrlSeconds }, {
    headers: { 'cache-control': 'no-store' },
  });
});
