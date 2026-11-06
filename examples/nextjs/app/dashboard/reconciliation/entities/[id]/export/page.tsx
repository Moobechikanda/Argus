import { redirect } from 'next/navigation';
import Link from 'next/link';
import { createClient } from '@/lib/supabase/server';
import { exportEntity } from '@/lib/actions/reconciliation';

export default async function ExportPage({
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

  const myRole = appMeta.memberships?.find((m) => m.company_id === companyId)?.role ?? 'viewer';
  const canExport = myRole === 'owner' || myRole === 'admin' || myRole === 'member';
  if (!canExport) redirect('/dashboard/reconciliation/entities');

  const { data: entity } = await supabase
    .from('reconciliation_entities')
    .select('id, canonical_data, survivorship_rule, record_count, status, created_at, updated_at')
    .eq('id', id)
    .eq('company_id', companyId)
    .single();

  if (!entity) redirect('/dashboard/reconciliation/entities');

  const result = await exportEntity(id);

  const downloadUrl = result.ok
    ? result.signedUrl ?? `data:text/csv;charset=utf-8,${encodeURIComponent(result.csv ?? '')}`
    : null;

  return (
    <div className="container">
      <Link href="/dashboard/reconciliation/entities">← Back to entities</Link>
      <h1 style={{ marginTop: 16 }}>Export Entity</h1>
      <p style={{ color: '#666', marginBottom: 24 }}>
        Export entity <strong>{entity.id.slice(0, 8)}…</strong> ({entity.record_count} source records) to CSV.
      </p>

      <div className="card" style={{ marginBottom: 24 }}>
        <table>
          <tbody>
            <tr>
              <td style={{ width: 140, fontSize: 12, color: '#666' }}>Entity ID</td>
              <td style={{ fontFamily: 'monospace', fontSize: 12 }}>{entity.id}</td>
            </tr>
            <tr>
              <td style={{ fontSize: 12, color: '#666' }}>Status</td>
              <td><span className={`badge ${entity.status}`}>{entity.status}</span></td>
            </tr>
            <tr>
              <td style={{ fontSize: 12, color: '#666' }}>Source records</td>
              <td>{entity.record_count}</td>
            </tr>
            <tr>
              <td style={{ fontSize: 12, color: '#666' }}>Survivorship rule</td>
              <td>{entity.survivorship_rule}</td>
            </tr>
            <tr>
              <td style={{ fontSize: 12, color: '#666' }}>Created</td>
              <td>{new Date(entity.created_at).toLocaleString('en-US')}</td>
            </tr>
          </tbody>
        </table>
      </div>

      {result.error && (
        <div className="card" style={{ marginBottom: 24, border: '1px solid #ef4444', background: '#fef2f2' }}>
          <p style={{ color: '#c00', margin: 0, fontSize: 13 }}>Error: {result.error}</p>
        </div>
      )}

      {downloadUrl && (
        <div className="card" style={{ marginBottom: 24 }}>
          <a
            href={downloadUrl}
            download={result.filename}
            className="btn"
            style={{ background: '#22c55e', borderColor: '#22c55e' }}
          >
            {result.signedUrl ? 'Download CSV (signed URL)' : 'Download CSV'}
          </a>
          <p style={{ fontSize: 11, color: '#666', marginTop: 8 }}>
            {result.signedUrl
              ? 'Signed URL expires in 1 hour.'
              : 'CSV includes entity metadata plus one row per linked source record.'}
          </p>
        </div>
      )}
    </div>
  );
}
