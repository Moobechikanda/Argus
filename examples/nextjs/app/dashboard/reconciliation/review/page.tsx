import { redirect } from 'next/navigation';
import Link from 'next/link';
import { createClient } from '@/lib/supabase/server';
import { acceptMatch, rejectMatch } from '@/lib/actions/reconciliation';

export default async function ReviewPage() {
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
  const canReview = myRole === 'owner' || myRole === 'admin';

  const [{ data: candidates }] = await Promise.all([
    supabase
      .from('reconciliation_match_candidates')
      .select('id, record_a_id, record_b_id, match_score, comparison_details, status, reviewer_id, reviewed_at, created_at, reconciliation_source_records!reconciliation_match_candidates_record_a_id_fkey(source_record_id, raw_data), reconciliation_source_records!reconciliation_match_candidates_record_b_id_fkey(source_record_id, raw_data)')
      .eq('company_id', companyId)
      .eq('status', 'pending')
      .order('match_score', { ascending: false })
      .limit(100),
  ]);

  async function onAccept(id: string) {
    const result = await acceptMatch(id);
    if (result.error) alert(result.error);
  }

  async function onReject(id: string) {
    const result = await rejectMatch(id);
    if (result.error) alert(result.error);
  }

  return (
    <div className="container">
      <Link href="/dashboard/reconciliation">← Back</Link>
      <h1 style={{ marginTop: 16 }}>Review Candidate Matches</h1>
      <p style={{ color: '#666', marginBottom: 24 }}>
        The matching engine proposed pairs of source records that may refer to the same entity.
        Review and accept or reject each pair. Decisions require <strong>admin</strong> or <strong>owner</strong> role.
      </p>

      {!canReview && (
        <div className="card" style={{ marginBottom: 24 }}>
          <p style={{ color: '#666', fontSize: 14 }}>
          You have the <strong>{myRole}</strong> role. Reviewing matches requires
          <strong>admin</strong> or <strong>owner</strong> role.
          </p>
        </div>
      )}

      <div className="card">
        <h2 style={{ marginBottom: 12 }}>Candidates pending review</h2>
        <table>
          <thead>
            <tr>
              <th>Score</th>
              <th>Registro A</th>
              <th>Registro B</th>
              <th>Detalhes da comparação</th>
              <th>Ações</th>
            </tr>
          </thead>
          <tbody>
            {(candidates ?? []).map((c: any) => {
              const scorePct = Math.round((c.match_score ?? 0) * 100);
              const recA = c.reconciliation_source_records?.[0] ?? {};
              const recB = c.reconciliation_source_records?.[1] ?? {};
              return (
                <tr key={c.id}>
                  <td>
                    <span className={`badge ${scorePct >= 80 ? 'high' : scorePct >= 50 ? 'med' : 'low'}`}>
                      {scorePct}%
                    </span>
                  </td>
                  <td>
                    <div style={{ fontFamily: 'monospace', fontSize: 11 }}>{recA.source_record_id ?? '—'}</div>
                    <div style={{ fontSize: 11, color: '#666', maxWidth: 200, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                      {JSON.stringify(recA.raw_data ?? {})}
                    </div>
                  </td>
                  <td>
                    <div style={{ fontFamily: 'monospace', fontSize: 11 }}>{recB.source_record_id ?? '—'}</div>
                    <div style={{ fontSize: 11, color: '#666', maxWidth: 200, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                      {JSON.stringify(recB.raw_data ?? {})}
                    </div>
                  </td>
                  <td>
                    <code style={{ fontSize: 10, maxWidth: 250, overflow: 'hidden', textOverflow: 'ellipsis', display: 'block' }}>
                      {JSON.stringify(c.comparison_details ?? {})}
                    </code>
                  </td>
                  <td>
                    {canReview && (
                      <>
                        <button
                          onClick={() => onAccept(c.id)}
                          className="btn"
                          style={{ padding: '4px 10px', fontSize: 12, marginRight: 6, background: '#22c55e', borderColor: '#22c55e' }}
                        >
                          Accept
                        </button>
                        <button
                          onClick={() => onReject(c.id)}
                          className="btn"
                          style={{ padding: '4px 10px', fontSize: 12, background: '#ef4444', borderColor: '#ef4444' }}
                        >
                          Reject
                        </button>
                      </>
                    )}
                  </td>
                </tr>
              );
            })}
            {(candidates?.length ?? 0) === 0 && (
              <tr>
                  <td colSpan={5} style={{ color: '#888', textAlign: 'center', padding: 24 }}>
                    No candidates pending review.
                  </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}
