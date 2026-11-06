import { redirect } from 'next/navigation';
import Link from 'next/link';
import { createClient } from '@/lib/supabase/server';
import { InviteForm } from '@/components/invite-form';
import { MemberActions } from '@/components/member-actions';

export default async function MembersPage() {
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

  // Lista membros (RLS filtra automaticamente para a company ativa)
  const { data: members } = await supabase
    .from('memberships')
    .select('user_id, role, joined_at, profiles(full_name, email, avatar_url)')
    .eq('company_id', companyId)
    .order('joined_at', { ascending: true });

  // Lista convites pendentes (só admin+ verá pelas RLS)
  const { data: invitations } = await supabase
    .from('invitations')
    .select('id, email, role, status, expires_at, created_at')
    .eq('company_id', companyId)
    .eq('status', 'pending');

  return (
    <div className="container">
      <Link href="/dashboard">← Back to dashboard</Link>
      <h1 style={{ marginTop: 16 }}>Members</h1>

      <div className="card">
        <h2 style={{ marginBottom: 12 }}>Team</h2>
        <table>
          <thead>
            <tr>
              <th>Name</th>
              <th>Email</th>
              <th>Role</th>
              <th>Since</th>
              {canManage && <th></th>}
            </tr>
          </thead>
          <tbody>
            {(members ?? []).map((m: any) => (
              <tr key={m.user_id}>
                <td>{m.profiles?.full_name ?? '—'}</td>
                <td>{m.profiles?.email}</td>
                <td><span className={`badge ${m.role}`}>{m.role}</span></td>
                <td>{new Date(m.joined_at).toLocaleDateString('en-US')}</td>
                {canManage && (
                  <td>
                    <MemberActions
                      userId={m.user_id}
                      currentRole={m.role}
                      isSelf={m.user_id === user.id}
                      callerRole={myRole}
                    />
                  </td>
                )}
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {canManage && (
        <>
          <div className="card">
            <h2 style={{ marginBottom: 12 }}>Invite new member</h2>
            <InviteForm companyId={companyId} />
          </div>

          {invitations && invitations.length > 0 && (
            <div className="card">
              <h2 style={{ marginBottom: 12 }}>Pending invitations</h2>
              <table>
                <thead>
                  <tr>
                    <th>Email</th>
                    <th>Role</th>
                    <th>Expires</th>
                  </tr>
                </thead>
                <tbody>
                  {invitations.map((i) => (
                    <tr key={i.id}>
                      <td>{i.email}</td>
                      <td><span className={`badge ${i.role}`}>{i.role}</span></td>
                      <td>{new Date(i.expires_at).toLocaleDateString('en-US')}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </>
      )}
    </div>
  );
}
