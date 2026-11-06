import { redirect } from 'next/navigation';
import Link from 'next/link';
import { createClient } from '@/lib/supabase/server';
import { displayFileRef } from '@/lib/reconciliation/file-ref';
import { retryImportJob } from '@/lib/actions/reconciliation';
import { ImportUploadForm } from './upload-form';

export default async function ImportsPage() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect('/auth/login');

  const appMeta = (user.app_metadata ?? {}) as {
    memberships?: { company_id: string; role: string }[];
    active_company_id?: string;
  };
  const companyId = appMeta.active_company_id;
  if (!companyId) redirect('/dashboard');

  const myRole = appMeta.memberships?.find((m) => m.company_id === companyId)?.role ?? 'viewer';
  const canManage = myRole === 'owner' || myRole === 'admin';

  const { data: importJobs } = await supabase
      .from('reconciliation_import_jobs')
      .select('id, data_source_id, status, file_ref, row_count, error_count, started_at, completed_at, created_at')
      .eq('company_id', companyId)
      .order('created_at', { ascending: false });
  const { data: sources } = await supabase.from('reconciliation_data_sources')
    .select('id, name').eq('company_id', companyId).is('deleted_at', null).order('name');

  async function onRetry(importJobId: string) {
    if (!window.confirm('Retry this failed import job?')) return;
    const formData = new FormData();
    formData.append('import_job_id', importJobId);
    const result = await retryImportJob(formData);
    if (result.error) alert(result.error);
  }

  return (
    <div className="container">
      <Link href="/dashboard/reconciliation">← Back</Link>
      <h1 style={{ marginTop: 16 }}>Imports</h1>
      <p style={{ color: '#666', marginBottom: 24 }}>
        Files upload to private tenant-scoped Storage and are processed only after a worker claims the job.
      </p>

      {canManage && (
        <ImportUploadForm companyId={companyId} sources={sources ?? []} />
      )}

      <div className="card">
        <h2 style={{ marginBottom: 12 }}>Import jobs</h2>
        <table>
          <thead>
            <tr>
              <th>ID</th>
              <th>Source</th>
              <th>Status</th>
              <th>File</th>
              <th>Rows</th>
              <th>Errors</th>
              <th>Started</th>
              <th>Completed</th>
              {canManage && <th>Retry</th>}
            </tr>
          </thead>
          <tbody>
            {(importJobs ?? []).map((j) => (
              <tr key={j.id}>
                <td style={{ fontFamily: 'monospace', fontSize: 12 }}>{j.id.slice(0, 8)}…</td>
                <td>{j.data_source_id.slice(0, 8)}…</td>
                <td><span className={`badge ${j.status}`}>{j.status}</span></td>
                <td>{displayFileRef(j.file_ref)}</td>
                <td>{j.row_count ?? 0}</td>
                <td>{j.error_count ?? 0}</td>
                <td>{j.started_at ? new Date(j.started_at).toLocaleString('en-US') : '—'}</td>
                <td>{j.completed_at ? new Date(j.completed_at).toLocaleString('en-US') : '—'}</td>
                {canManage && (
                  <td>
                    {j.status === 'failed' ? (
                      <button
                        onClick={() => onRetry(j.id)}
                        className="btn"
                        style={{ padding: '4px 10px', fontSize: 12, background: '#f59e0b', borderColor: '#f59e0b' }}
                      >
                        Retry
                      </button>
                    ) : (
                      <span style={{ fontSize: 11, color: '#888' }}>-</span>
                    )}
                  </td>
                )}
              </tr>
            ))}
            {(importJobs?.length ?? 0) === 0 && (
              <tr>
                <td colSpan={canManage ? 9 : 8} style={{ color: '#888', textAlign: 'center', padding: 24 }}>No imports yet.</td>
              </tr>
            )}
          </tbody>
        </table>
      </div>

      {!canManage && (
        <div className="card" style={{ marginTop: 16 }}>
          <p style={{ color: '#666', fontSize: 14 }}>
            You have the <strong>{myRole}</strong> role. Creating imports requires <strong>admin</strong> or <strong>owner</strong> role.
          </p>
        </div>
      )}
    </div>
  );
}
