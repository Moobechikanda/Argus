import { redirect } from 'next/navigation';
import Link from 'next/link';
import { createClient } from '@/lib/supabase/server';
import { resolveDiscrepancy } from '@/lib/actions/reconciliation';

export default async function DiscrepanciesPage() {
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
  const canResolve = myRole === 'owner' || myRole === 'admin';

  const [{ data: discrepancies }] = await Promise.all([
    supabase
      .from('reconciliation_discrepancies')
      .select('id, entity_id, field_name, source_record_id, competing_value, resolution, reviewer_id, resolved_at, created_at, reconciliation_entities!reconciliation_discrepancies_entity_id_fkey(canonical_data, record_count)')
      .eq('company_id', companyId)
      .eq('resolution', 'unresolved')
      .order('created_at', { ascending: false })
      .limit(100),
  ]);

  async function onResolve(
    discrepancyId: string,
    resolution: string,
    winningSourceRecordId: string,
    manualValue: string,
  ) {
    const formData = new FormData();
    formData.append('discrepancy_id', discrepancyId);
    formData.append('resolution', resolution);
    if (winningSourceRecordId) formData.append('winning_source_record_id', winningSourceRecordId);
    if (manualValue) formData.append('manual_value', manualValue);

    const result = await resolveDiscrepancy(formData);
    if (result.error) alert(result.error);
    else window.location.reload();
  }

  return (
    <div className="container">
      <Link href="/dashboard/reconciliation">← Back</Link>
      <h1 style={{ marginTop: 16 }}>Field Discrepancies</h1>
      <p style={{ color: '#666', marginBottom: 24 }}>
        Field conflicts within resolved entities that require a reviewer decision. Choose the
        winning source value or enter a manual value. Requires <strong>admin</strong> or <strong>owner</strong> role.
      </p>

      {!canResolve && (
        <div className="card" style={{ marginBottom: 24 }}>
          <p style={{ color: '#666', fontSize: 14 }}>
          You have the <strong>{myRole}</strong> role. Resolving discrepancies requires
          <strong>admin</strong> or <strong>owner</strong> role.
          </p>
        </div>
      )}

      <div className="card">
        <h2 style={{ marginBottom: 12 }}>Unresolved Discrepancies</h2>
        <table>
          <thead>
            <tr>
              <th>Entity</th>
              <th>Field</th>
              <th>Competing Value</th>
              <th>Source Record</th>
              <th>Created</th>
              <th>Resolution</th>
            </tr>
          </thead>
          <tbody>
            {(discrepancies ?? []).map((d: any) => {
              const entity = d.reconciliation_entities?.[0] ?? {};
              return (
                <tr key={d.id}>
                  <td style={{ fontFamily: 'monospace', fontSize: 11 }}>{d.entity_id.slice(0, 8)}…</td>
                  <td>{d.field_name}</td>
                  <td>
                    <code style={{ fontSize: 10, maxWidth: 200, overflow: 'hidden', textOverflow: 'ellipsis', display: 'block' }}>
                      {JSON.stringify(d.competing_value ?? {})}
                    </code>
                  </td>
                  <td style={{ fontFamily: 'monospace', fontSize: 11 }}>{d.source_record_id?.slice(0, 8) ?? '—'}…</td>
                  <td>{new Date(d.created_at).toLocaleString('en-US')}</td>
                  <td>
                    {canResolve && (
                      <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                        <button
                          onClick={() => onResolve(d.id, 'winner_source', d.source_record_id ?? '', '')}
                          className="btn"
                          style={{ padding: '4px 8px', fontSize: 11, background: '#22c55e', borderColor: '#22c55e' }}
                        >
                          Use Source Value
                        </button>
                        <button
                          onClick={() => {
                            const v = window.prompt('Enter manual value:');
                            if (v !== null) onResolve(d.id, 'manual', '', v);
                          }}
                          className="btn"
                          style={{ padding: '4px 8px', fontSize: 11, background: '#3b82f6', borderColor: '#3b82f6' }}
                        >
                          Manual Value
                        </button>
                      </div>
                    )}
                  </td>
                </tr>
              );
            })}
            {(discrepancies?.length ?? 0) === 0 && (
              <tr>
                <td colSpan={6} style={{ color: '#888', textAlign: 'center', padding: 24 }}>
                  No unresolved discrepancies.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}
