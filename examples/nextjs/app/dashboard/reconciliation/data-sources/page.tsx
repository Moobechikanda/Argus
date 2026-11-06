import { redirect } from 'next/navigation';
import Link from 'next/link';
import { createClient } from '@/lib/supabase/server';
import { createDataSource, deleteDataSource } from '@/lib/actions/reconciliation';

export default async function DataSourcesPage() {
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

  const { data: dataSources } = await supabase
    .from('reconciliation_data_sources')
    .select('id, name, description, source_type, connection_config, created_at, deleted_at')
    .eq('company_id', companyId)
    .is('deleted_at', null)
    .order('created_at', { ascending: false });

  async function onCreate(formData: FormData) {
    const result = await createDataSource(formData);
    if (result.error) alert(result.error);
  }

  async function onDelete(dataSourceId: string) {
    if (!window.confirm('Deactivate this data source? This cannot be undone.')) return;
    const formData = new FormData();
    formData.append('data_source_id', dataSourceId);
    const result = await deleteDataSource(formData);
    if (result.error) alert(result.error);
  }

  return (
    <div className="container">
      <Link href="/dashboard/reconciliation">← Back</Link>
      <h1 style={{ marginTop: 16 }}>Data Sources</h1>
      <p style={{ color: '#666', marginBottom: 24 }}>
        Register source datasets to be imported and reconciled. Each source belongs to the active company.
      </p>

      {canManage && (
        <div className="card" style={{ marginBottom: 24 }}>
          <h2 style={{ marginBottom: 12 }}>Register new data source</h2>
          <form action={onCreate} style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(240px, 1fr))', gap: 12 }}>
            <div>
              <label style={{ display: 'block', fontSize: 12, color: '#666', marginBottom: 6 }}>Name</label>
              <input name="name" required style={{ width: '100%', padding: 8, border: '1px solid #ddd', borderRadius: 6 }} placeholder="Ex: Clients CSV" />
            </div>
            <div>
              <label style={{ display: 'block', fontSize: 12, color: '#666', marginBottom: 6 }}>Description</label>
              <input name="description" style={{ width: '100%', padding: 8, border: '1px solid #ddd', borderRadius: 6 }} placeholder="Optional" />
            </div>
            <div>
              <label style={{ display: 'block', fontSize: 12, color: '#666', marginBottom: 6 }}>Type</label>
              <select name="source_type" style={{ width: '100%', padding: 8, border: '1px solid #ddd', borderRadius: 6 }}>
                <option value="file">File (CSV/JSON)</option>
                <option value="database">Database</option>
                <option value="api">External API</option>
              </select>
            </div>
            <div>
              <label style={{ display: 'block', fontSize: 12, color: '#666', marginBottom: 6 }}>Configuration (JSON)</label>
              <textarea name="connection_config" rows={3} style={{ width: '100%', padding: 8, border: '1px solid #ddd', borderRadius: 6, fontFamily: 'monospace', fontSize: 12 }} placeholder='{"file_path": "/tmp/dados.csv"}'>{'{"file_path": "/tmp/dados.csv"}'}</textarea>
              <p style={{ fontSize: 11, color: '#888', marginTop: 4 }}>File path or connection config used by the Python worker.</p>
            </div>
            <div style={{ gridColumn: '1 / -1' }}>
              <button type="submit" className="btn">Register source</button>
            </div>
          </form>
        </div>
      )}

      <div className="card">
        <h2 style={{ marginBottom: 12 }}>Registered sources</h2>
        <table>
          <thead>
            <tr>
              <th>Name</th>
              <th>Type</th>
              <th>Description</th>
              <th>Config</th>
              <th>Created</th>
              <th>Status</th>
              {canManage && <th>Actions</th>}
            </tr>
          </thead>
          <tbody>
            {(dataSources ?? []).map((ds) => (
              <tr key={ds.id}>
                <td>{ds.name}</td>
                <td><span className={`badge ${ds.source_type}`}>{ds.source_type}</span></td>
                <td>{ds.description ?? '—'}</td>
                <td><code style={{ fontSize: 11 }}>{JSON.stringify(ds.connection_config ?? {})}</code></td>
                <td>{new Date(ds.created_at).toLocaleString('en-US')}</td>
                <td>{ds.deleted_at ? <span className="badge deleted">inactive</span> : <span className="badge active">active</span>}</td>
                {canManage && (
                  <td>
                    {ds.deleted_at ? (
                      <span style={{ fontSize: 11, color: '#888' }}>-</span>
                    ) : (
                      <button
                        onClick={() => onDelete(ds.id)}
                        className="btn"
                        style={{ padding: '4px 10px', fontSize: 12, background: '#ef4444', borderColor: '#ef4444' }}
                      >
                        Deactivate
                      </button>
                    )}
                  </td>
                )}
              </tr>
            ))}
            {(dataSources?.length ?? 0) === 0 && (
              <tr>
                <td colSpan={canManage ? 7 : 6} style={{ color: '#888', textAlign: 'center', padding: 24 }}>No sources registered.</td>
              </tr>
            )}
          </tbody>
        </table>
      </div>

      {!canManage && (
        <div className="card" style={{ marginTop: 16 }}>
          <p style={{ color: '#666', fontSize: 14 }}>
            You have the <strong>{myRole}</strong> role. Creating sources requires <strong>admin</strong> or <strong>owner</strong> role.
          </p>
        </div>
      )}
    </div>
  );
}
