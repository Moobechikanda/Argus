import { redirect } from 'next/navigation';
import Link from 'next/link';
import { createClient } from '@/lib/supabase/server';
import { displayFileRef } from '@/lib/reconciliation/file-ref';

export default async function ImportJobPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect('/auth/login');

  const appMeta = (user.app_metadata ?? {}) as {
    memberships?: { company_id: string; role: string }[];
    active_company_id?: string;
  };
  const companyId = appMeta.active_company_id;
  if (!companyId) redirect('/dashboard');

  const { data: job } = await supabase
    .from('reconciliation_import_jobs')
    .select('*')
    .eq('id', id)
    .eq('company_id', companyId)
    .single();

  if (!job) redirect('/dashboard/reconciliation/imports');

  const { data: sourceRecords } = await supabase
    .from('reconciliation_source_records')
    .select('id, source_record_id, raw_data, normalized_data, row_hash, created_at')
    .eq('import_job_id', id)
    .eq('company_id', companyId)
    .order('created_at', { ascending: true })
    .limit(50);

  return (
    <div className="container">
      <Link href="/dashboard/reconciliation/imports">← Back to imports</Link>
      <h1 style={{ marginTop: 16 }}>Import Details</h1>

      <div className="card" style={{ marginBottom: 24 }}>
        <table>
          <tbody>
            <tr>
              <td style={{ width: 140, fontSize: 12, color: '#666' }}>ID</td>
              <td style={{ fontFamily: 'monospace', fontSize: 12 }}>{job.id}</td>
            </tr>
            <tr>
              <td style={{ fontSize: 12, color: '#666' }}>Data source</td>
              <td>{job.data_source_id}</td>
            </tr>
            <tr>
              <td style={{ fontSize: 12, color: '#666' }}>Status</td>
              <td><span className={`badge ${job.status}`}>{job.status}</span></td>
            </tr>
            <tr>
              <td style={{ fontSize: 12, color: '#666' }}>File</td>
              <td>{displayFileRef(job.file_ref)}</td>
            </tr>
            <tr>
              <td style={{ fontSize: 12, color: '#666' }}>Rows imported</td>
              <td>{job.row_count ?? 0}</td>
            </tr>
            <tr>
              <td style={{ fontSize: 12, color: '#666' }}>Errors</td>
              <td>{job.error_count ?? 0}</td>
            </tr>
            <tr>
              <td style={{ fontSize: 12, color: '#666' }}>Started at</td>
              <td>{job.started_at ? new Date(job.started_at).toLocaleString('en-US') : '—'}</td>
            </tr>
            <tr>
              <td style={{ fontSize: 12, color: '#666' }}>Completed at</td>
              <td>{job.completed_at ? new Date(job.completed_at).toLocaleString('en-US') : '—'}</td>
            </tr>
            <tr>
              <td style={{ fontSize: 12, color: '#666' }}>Created by</td>
              <td>{job.created_by}</td>
            </tr>
          </tbody>
        </table>
      </div>

      <div className="card">
        <h2 style={{ marginBottom: 12 }}>Source Records (first 50)</h2>
        <p style={{ color: '#666', marginBottom: 12 }}>
          Source records are immutable. Corrections go through discrepancies + reviewer decisions.
        </p>
        <table>
          <thead>
            <tr>
              <th>ID</th>
              <th>Source Record ID</th>
              <th>Raw Data</th>
              <th>Row Hash</th>
              <th>Created</th>
            </tr>
          </thead>
          <tbody>
            {(sourceRecords ?? []).map((r) => (
              <tr key={r.id}>
                <td style={{ fontFamily: 'monospace', fontSize: 11 }}>{r.id.slice(0, 8)}…</td>
                <td style={{ fontFamily: 'monospace', fontSize: 11 }}>{r.source_record_id}</td>
                <td><code style={{ fontSize: 10, maxWidth: 300, overflow: 'hidden', textOverflow: 'ellipsis', display: 'block' }}>{JSON.stringify(r.raw_data)}</code></td>
                <td style={{ fontFamily: 'monospace', fontSize: 11 }}>{r.row_hash?.slice(0, 16)}…</td>
                <td>{new Date(r.created_at).toLocaleString('en-US')}</td>
              </tr>
            ))}
            {(sourceRecords?.length ?? 0) === 0 && (
              <tr>
                <td colSpan={5} style={{ color: '#888', textAlign: 'center', padding: 24 }}>No source records yet.</td>
              </tr>
            )}
          </tbody>
        </table>
        {(sourceRecords?.length ?? 0) > 50 && (
          <p style={{ color: '#888', fontSize: 12, marginTop: 8 }}>
            Showing first 50 of {sourceRecords?.length ?? 0} records.
          </p>
        )}
      </div>
    </div>
  );
}
