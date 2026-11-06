import { redirect } from 'next/navigation';
import Link from 'next/link';
import { createClient } from '@/lib/supabase/server';
import { displayFileRef } from '@/lib/reconciliation/file-ref';

export default async function ReconciliationPage() {
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

  // Estatísticas rápidas da empresa ativa (RLS filtra por company_id)
  const [{ data: dataSources }, { data: importJobs }, { data: sourceRecords }, { data: entities }] =
    await Promise.all([
      supabase.from('reconciliation_data_sources').select('id, status').eq('company_id', companyId),
      supabase
        .from('reconciliation_import_jobs')
        .select('id, data_source_id, status, file_ref, created_at')
        .eq('company_id', companyId)
        .order('created_at', { ascending: false })
        .limit(5),
      supabase.from('reconciliation_source_records').select('id').eq('company_id', companyId),
      supabase.from('reconciliation_entities').select('id, status').eq('company_id', companyId),
    ]);

  const pendingJobs = (importJobs ?? []).filter((j) => j.status === 'pending').length;
  const runningJobs = (importJobs ?? []).filter((j) => j.status === 'running').length;

  return (
    <div className="container">
      <Link href="/dashboard">← Back to dashboard</Link>
      <h1 style={{ marginTop: 16 }}>Data Reconciliation</h1>
      <p style={{ color: '#666', marginBottom: 24 }}>
        Import source records, run probabilistic matching, and review matches with full traceability.
      </p>

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(200px, 1fr))', gap: 16, marginBottom: 32 }}>
        <div className="card" style={{ padding: 16 }}>
                  <div style={{ fontSize: 12, color: '#888', textTransform: 'uppercase', letterSpacing: '0.05em', marginBottom: 8 }}>Data sources</div>
          <div style={{ fontSize: 28, fontWeight: 600 }}>{dataSources?.length ?? 0}</div>
        </div>
        <div className="card" style={{ padding: 16 }}>
                  <div style={{ fontSize: 12, color: '#888', textTransform: 'uppercase', letterSpacing: '0.05em', marginBottom: 8 }}>Import jobs</div>
                  <div style={{ fontSize: 28, fontWeight: 600 }}>{importJobs?.length ?? 0}</div>
                  <div style={{ fontSize: 12, color: '#666', marginTop: 4 }}>{pendingJobs} pending · {runningJobs} running</div>
        </div>
        <div className="card" style={{ padding: 16 }}>
                  <div style={{ fontSize: 12, color: '#888', textTransform: 'uppercase', letterSpacing: '0.05em', marginBottom: 8 }}>Source records</div>
          <div style={{ fontSize: 28, fontWeight: 600 }}>{sourceRecords?.length ?? 0}</div>
        </div>
        <div className="card" style={{ padding: 16 }}>
                  <div style={{ fontSize: 12, color: '#888', textTransform: 'uppercase', letterSpacing: '0.05em', marginBottom: 8 }}>Resolved entities</div>
          <div style={{ fontSize: 28, fontWeight: 600 }}>{entities?.length ?? 0}</div>
        </div>
      </div>

      <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap', marginBottom: 32 }}>
        <Link href="/dashboard/reconciliation/data-sources" className="btn">
          {canManage ? 'New data source' : 'Data sources'}
        </Link>
        <Link href="/dashboard/reconciliation/imports" className="btn">
          {canManage ? 'New import' : 'Imports'}
        </Link>
        <Link href="/dashboard/reconciliation/entities" className="btn ghost">
          Entities
        </Link>
        <Link href="/dashboard/reconciliation/review" className="btn ghost">
          Review matches
        </Link>
        <Link href="/dashboard/reconciliation/discrepancies" className="btn ghost">
          Discrepancies
        </Link>
      </div>

      <div className="card">
        <h2 style={{ marginBottom: 12 }}>Recent imports</h2>
        <table>
          <thead>
            <tr>
              <th>ID</th>
              <th>Source</th>
              <th>Status</th>
              <th>File</th>
              <th>Created</th>
            </tr>
          </thead>
          <tbody>
            {(importJobs ?? []).map((j) => (
              <tr key={j.id}>
                <td style={{ fontFamily: 'monospace', fontSize: 12 }}>{j.id.slice(0, 8)}…</td>
                <td>{j.data_source_id.slice(0, 8)}…</td>
                <td><span className={`badge ${j.status}`}>{j.status}</span></td>
                <td>{displayFileRef(j.file_ref)}</td>
                <td>{new Date(j.created_at).toLocaleString('en-US')}</td>
              </tr>
            ))}
            {(importJobs?.length ?? 0) === 0 && (
              <tr>
                <td colSpan={5} style={{ color: '#888', textAlign: 'center', padding: 24 }}>No imports yet.</td>
              </tr>
            )}
          </tbody>
        </table>
      </div>

      {!canManage && (
        <div className="card" style={{ marginTop: 16 }}>
          <p style={{ color: '#666', fontSize: 14 }}>
          You have the <strong>{myRole}</strong> role in this company. Creating data sources and
          imports requires <strong>admin</strong> or <strong>owner</strong> role.
          </p>
        </div>
      )}
    </div>
  );
}
