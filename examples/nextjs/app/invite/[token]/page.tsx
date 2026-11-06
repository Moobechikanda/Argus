'use client';

import { useEffect, useState } from 'react';
import { useParams, useRouter } from 'next/navigation';
import Link from 'next/link';
import { createClient } from '@/lib/supabase/client';

export default function InvitePage() {
  const { token } = useParams<{ token: string }>();
  const router = useRouter();
  const [status, setStatus] = useState<'idle' | 'loading' | 'ok' | 'err' | 'no-auth'>('idle');
  const [message, setMessage] = useState('');

  async function accept() {
    setStatus('loading');
    const supabase = createClient();
    const { data: { session } } = await supabase.auth.getSession();
    if (!session) {
      setStatus('no-auth');
      return;
    }

    const url = `${process.env.NEXT_PUBLIC_SUPABASE_URL}/functions/v1/invitations/accept`;
    const resp = await fetch(url, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${session.access_token}`,
        apikey: process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
      },
      body: JSON.stringify({ token }),
    });
    const body = await resp.json();
    if (!resp.ok) {
      setStatus('err');
      setMessage(body.error?.message ?? 'Error accepting invitation');
      return;
    }

    // Atualiza a empresa ativa para a recém-aceita
    await supabase.rpc('set_active_company', { _company_id: body.company_id });
    await supabase.auth.refreshSession();

    setStatus('ok');
    setTimeout(() => router.push('/dashboard'), 1500);
  }

  useEffect(() => { accept(); /* eslint-disable-next-line react-hooks/exhaustive-deps */ }, []);

  return (
    <div className="container" style={{ maxWidth: 480 }}>
      <h1>Invitation</h1>
      <div className="card">
        {status === 'loading' && <p>Processing invitation…</p>}
        {status === 'ok' && <p className="success">Invitation accepted! Redirecting…</p>}
        {status === 'err' && <p className="error">{message}</p>}
        {status === 'no-auth' && (
          <>
            <p>You need to be logged in to accept the invitation.</p>
            <div style={{ display: 'flex', gap: 12, marginTop: 16 }}>
              <Link href={`/auth/login?redirect=/invite/${token}`} className="btn">Sign in</Link>
              <Link href={`/auth/signup?redirect=/invite/${token}`} className="btn ghost">Create account</Link>
            </div>
          </>
        )}
      </div>
    </div>
  );
}
