import { redirect } from 'next/navigation';
import Link from 'next/link';
import { createClient } from '@/lib/supabase/server';

const ACTION_LABELS: Record<string, string> = {
  'company.created': 'Company created',
  'company.updated': 'Company updated',
  'company.deleted': 'Company removed',
  'member.invited': 'Member invited',
  'member.joined': 'Member joined',
  'member.role_changed': 'Role changed',
  'member.removed': 'Member removed',
  'member.left': 'Member left',
  'invitation.revoked': 'Invitation revoked',
  'ownership.transferred': 'Ownership transferred',
};

export default async function AuditPage() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect('/auth/login');

  // RLS filtra automaticamente: só admin+ vê o log da empresa ativa
  const { data: logs } = await supabase
    .from('audit_log')
    .select('id, action, actor_user_id, target_user_id, metadata, created_at, profiles!audit_log_actor_user_id_fkey(full_name, email)')
    .order('created_at', { ascending: false })
    .limit(100);

  return (
    <div className="container">
      <Link href="/dashboard">← Back to dashboard</Link>
      <h1 style={{ marginTop: 16 }}>Audit</h1>
      <p style={{ color: '#666', marginBottom: 16 }}>Last 100 actions on the active company.</p>

      <div className="card">
        <table>
          <thead>
            <tr>
              <th>When</th>
              <th>Who</th>
              <th>Action</th>
              <th>Details</th>
            </tr>
          </thead>
          <tbody>
            {(logs ?? []).map((l: any) => (
              <tr key={l.id}>
                <td>{new Date(l.created_at).toLocaleString('en-US')}</td>
                <td>{l.profiles?.full_name ?? l.profiles?.email ?? 'system'}</td>
                <td>{ACTION_LABELS[l.action] ?? l.action}</td>
                <td><code style={{ fontSize: 12 }}>{JSON.stringify(l.metadata)}</code></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
