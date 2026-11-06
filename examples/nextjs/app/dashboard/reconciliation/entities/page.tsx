import { redirect } from 'next/navigation';
import Link from 'next/link';
import { createClient } from '@/lib/supabase/server';
import { confirmEntity } from '@/lib/actions/reconciliation';

const STATUS_LABELS: Record<string, string> = {
  candidate: 'Candidate',
  confirmed: 'Confirmed',
  rejected: 'Rejected',
  merged: 'Merged',
};

export default async function EntitiesPage() {
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
  const canConfirm = myRole === 'owner' || myRole === 'admin';

  const [{ data: entities }] = await Promise.all([
    supabase
      .from('reconciliation_entities')
      .select('id, canonical_data, survivorship_rule, record_count, status, created_at, updated_at')
      .eq('company_id', companyId)
      .order('created_at', { ascending: false }),
  ]);

  async function onConfirm(id: string) {
    const result = await confirmEntity(id);
    if (result.error) alert(result.error);
  }

  return (
    <div className="container">
      <Link href="/dashboard/reconciliation">← Back</Link>
      <h1 style={{ marginTop: 16 }}>Resolved Entities</h1>
      <p style={{ color: '#666', marginBottom: 24 }}>
        Entities (golden records) resulting from confirmed source record clusters.
        Only entities with status <strong>candidate</strong> can be confirmed.
      </p>

      <div className="card">
        <h2 style={{ marginBottom: 12 }}>Entities</h2>
        <table>
          <thead>
            <tr>
              <th>ID</th>
              <th>Records</th>
              <th>Status</th>
              <th>Canonical data</th>
              <th>Created</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            {(entities ?? []).map((e: any) => (
              <tr key={e.id}>
                <td style={{ fontFamily: 'monospace', fontSize: 11 }}>{e.id.slice(0, 8)}…</td>
                <td>{e.record_count ?? 0}</td>
                <td>
                  <span className={`badge ${e.status}`}>{STATUS_LABELS[e.status] ?? e.status}</span>
                </td>
                <td>
                  <code style={{ fontSize: 10, maxWidth: 300, overflow: 'hidden', textOverflow: 'ellipsis', display: 'block' }}>
                    {JSON.stringify(e.canonical_data ?? {})}
                  </code>
                </td>
                <td>{new Date(e.created_at).toLocaleString('en-US')}</td>
                <td>
                  {e.status === 'candidate' && canConfirm && (
                      <button
                        onClick={() => onConfirm(e.id)}
                        className="btn"
                        style={{ padding: '4px 10px', fontSize: 12, marginRight: 6, background: '#22c55e', borderColor: '#22c55e' }}
                      >
                        Confirm
                      </button>
                  )}
                  <Link
                    href={`/dashboard/reconciliation/entities/${e.id}/export`}
                    className="btn ghost"
                    style={{ padding: '4px 10px', fontSize: 12, borderColor: '#666' }}
                  >
                    Export
                  </Link>
                </td>
              </tr>
            ))}
            {(entities?.length ?? 0) === 0 && (
              <tr>
                  <td colSpan={6} style={{ color: '#888', textAlign: 'center', padding: 24 }}>
                    No resolved entities yet.
                  </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>

      {!canConfirm && (
        <div className="card" style={{ marginTop: 16 }}>
          <p style={{ color: '#666', fontSize: 14 }}>
          You have the <strong>{myRole}</strong> role. Confirming entities requires
          <strong>admin</strong> or <strong>owner</strong> role.
          </p>
        </div>
      )}
    </div>
  );
}
