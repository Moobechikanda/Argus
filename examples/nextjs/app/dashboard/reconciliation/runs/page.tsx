import { redirect } from 'next/navigation';
import Link from 'next/link';
import { createClient } from '@/lib/supabase/server';
import { startReconciliationRun, retryReconciliationRun } from '@/lib/actions/reconciliation';

const STATUS_LABELS: Record<string, string> = {
  queued: 'Queued',
  running: 'Running',
  completed: 'Completed',
  failed: 'Failed',
};

const BLOCKING_RULES_PLACEHOLDER = '[{ "field": "cpf", "op": "exact" }]';
const COMPARISON_CONFIG_PLACEHOLDER = '{ "nome": "levenshtein", "cidade": "exact" }';

export default async function RunsPage() {
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

  const [{ data: runs }, { data: dataSources }] = await Promise.all([
    supabase
      .from('reconciliation_reconciliation_runs')
      .select('id, status, blocking_rules, comparison_config, record_pairs_compared, matches_found, started_at, completed_at, created_at, error')
      .eq('company_id', companyId)
      .order('created_at', { ascending: false }),
    supabase
      .from('reconciliation_data_sources')
      .select('id, name')
      .eq('company_id', companyId)
      .is('deleted_at', null)
      .order('name', { ascending: true }),
  ]);

  async function onStart(formData: FormData) {
    const result = await startReconciliationRun(formData);
    if (result.error) alert(result.error);
  }

  async function onRetry(runId: string) {
    if (!window.confirm('Retry this failed reconciliation run?')) return;
    const formData = new FormData();
    formData.append('run_id', runId);
    const result = await retryReconciliationRun(formData);
    if (result.error) alert(result.error);
  }

  return (
    <div className="container">
      <Link href="/dashboard/reconciliation">← Back</Link>
      <h1 style={{ marginTop: 16 }}>Reconciliation Runs</h1>
      <p style={{ color: '#666', marginBottom: 24 }}>
        Run the probabilistic matching engine (Splink) on the active company's source records.
        Each run generates candidate pairs that need human review before confirming entities.
      </p>

      {canManage && (
        <div className="card" style={{ marginBottom: 24 }}>
          <h2 style={{ marginBottom: 12 }}>Start new run</h2>
          <form action={onStart} style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(260px, 1fr))', gap: 12 }}>
            <div>
              <label style={{ display: 'block', fontSize: 12, color: '#666', marginBottom: 6 }}>Select a source</label>
              <select name="data_source_id" required style={{ width: '100%', padding: 8, border: '1px solid #ddd', borderRadius: 6 }}>
                <option value="">Select a source</option>
                {(dataSources ?? []).map((ds) => (
                  <option key={ds.id} value={ds.id}>{ds.name}</option>
                ))}
              </select>
            </div>
            <div>
              <label style={{ display: 'block', fontSize: 12, color: '#666', marginBottom: 6 }}>Blocking rules (JSON)</label>
              <textarea name="blocking_rules" rows={3} style={{ width: '100%', padding: 8, border: '1px solid #ddd', borderRadius: 6, fontFamily: 'monospace', fontSize: 12 }} placeholder={BLOCKING_RULES_PLACEHOLDER}>{BLOCKING_RULES_PLACEHOLDER}</textarea>
              <p style={{ fontSize: 11, color: '#888', marginTop: 4 }}>Splink blocking rules to reduce comparison space.</p>
            </div>
            <div>
              <label style={{ display: 'block', fontSize: 12, color: '#666', marginBottom: 6 }}>Comparison config (JSON)</label>
              <textarea name="comparison_config" rows={3} style={{ width: '100%', padding: 8, border: '1px solid #ddd', borderRadius: 6, fontFamily: 'monospace', fontSize: 12 }} placeholder={COMPARISON_CONFIG_PLACEHOLDER}>{COMPARISON_CONFIG_PLACEHOLDER}</textarea>
            </div>
            <div style={{ gridColumn: '1 / -1' }}>
              <button type="submit" className="btn">Start run</button>
            </div>
          </form>
        </div>
      )}

      <div className="card">
        <h2 style={{ marginBottom: 12 }}>Runs</h2>
        <table>
          <thead>
            <tr>
              <th>ID</th>
              <th>Status</th>
              <th>Pairs compared</th>
              <th>Matches found</th>
              <th>Started</th>
              <th>Completed</th>
              <th>Error</th>
              {canManage && <th>Retry</th>}
            </tr>
          </thead>
          <tbody>
            {(runs ?? []).map((r) => (
              <tr key={r.id}>
                <td style={{ fontFamily: 'monospace', fontSize: 12 }}>{r.id.slice(0, 8)}…</td>
                <td><span className={`badge ${r.status}`}>{STATUS_LABELS[r.status] ?? r.status}</span></td>
                <td>{r.record_pairs_compared ?? 0}</td>
                <td>{r.matches_found ?? 0}</td>
                <td>{r.started_at ? new Date(r.started_at).toLocaleString('en-US') : '—'}</td>
                <td>{r.completed_at ? new Date(r.completed_at).toLocaleString('en-US') : '—'}</td>
                <td>{r.error ? <code style={{ fontSize: 11, color: '#c00' }}>{r.error.slice(0, 60)}…</code> : '—'}</td>
                {canManage && (
                  <td>
                    {r.status === 'failed' ? (
                      <button
                        onClick={() => onRetry(r.id)}
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
            {(runs?.length ?? 0) === 0 && (
              <tr>
                <td colSpan={canManage ? 8 : 7} style={{ color: '#888', textAlign: 'center', padding: 24 }}>No runs yet.</td>
              </tr>
            )}
          </tbody>
        </table>
      </div>

      {!canManage && (
        <div className="card" style={{ marginTop: 16 }}>
          <p style={{ color: '#666', fontSize: 14 }}>
            You have the <strong>{myRole}</strong> role. Starting runs requires <strong>admin</strong> or <strong>owner</strong> role.
          </p>
        </div>
      )}
    </div>
  );
}
