'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { createClient } from '@/lib/supabase/client';

export function InviteForm({ companyId }: { companyId: string }) {
  const router = useRouter();
  const [email, setEmail] = useState('');
  const [role, setRole] = useState('member');
  const [loading, setLoading] = useState(false);
  const [message, setMessage] = useState<{ kind: 'success' | 'error'; text: string } | null>(null);

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    setLoading(true);
    setMessage(null);

    const supabase = createClient();
    const { data: { session } } = await supabase.auth.getSession();
    const url = `${process.env.NEXT_PUBLIC_SUPABASE_URL}/functions/v1/invitations`;

    const resp = await fetch(url, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${session?.access_token}`,
        apikey: process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
      },
      body: JSON.stringify({ company_id: companyId, email, role }),
    });

    const body = await resp.json();
    setLoading(false);

    if (!resp.ok) {
      setMessage({ kind: 'error', text: body.error?.message ?? 'Unknown error' });
      return;
    }

    setMessage({ kind: 'success', text: 'Invitation sent!' });
    setEmail('');
    router.refresh();
  }

  return (
    <form onSubmit={onSubmit} style={{ display: 'flex', gap: 12, alignItems: 'flex-end', flexWrap: 'wrap' }}>
      <div style={{ flex: 1, minWidth: 200 }}>
        <label className="label">Email</label>
        <input type="email" required value={email} onChange={(e) => setEmail(e.target.value)} className="input" style={{ marginBottom: 0 }} />
      </div>
      <div style={{ width: 140 }}>
        <label className="label">Role</label>
        <select value={role} onChange={(e) => setRole(e.target.value)} className="select" style={{ marginBottom: 0 }}>
          <option value="admin">Admin</option>
          <option value="member">Member</option>
          <option value="viewer">Viewer</option>
        </select>
      </div>
      <button className="btn" disabled={loading}>{loading ? 'Sending…' : 'Invite'}</button>
      {message && <p className={message.kind === 'error' ? 'error' : 'success'}>{message.text}</p>}
    </form>
  );
}
