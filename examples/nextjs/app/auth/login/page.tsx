'use client';

import { Suspense, useState } from 'react';
import { useRouter, useSearchParams } from 'next/navigation';
import Link from 'next/link';
import { createClient } from '@/lib/supabase/client';

// Componente real do form, isolado para poder ficar dentro do Suspense.
// useSearchParams() requer Suspense boundary no Next.js 15 quando há
// static generation (build prerendering).
function LoginForm() {
  const router = useRouter();
  const params = useSearchParams();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    setLoading(true);
    const supabase = createClient();
    const { error } = await supabase.auth.signInWithPassword({ email, password });
    setLoading(false);
    if (error) {
      setError(error.message);
      return;
    }
    router.push(params.get('redirect') ?? '/dashboard');
    router.refresh();
  }

  return (
    <form onSubmit={onSubmit} className="card" style={{ marginTop: 16 }}>
      <label className="label">Email</label>
      <input type="email" required value={email} onChange={(e) => setEmail(e.target.value)} className="input" />
      <label className="label">Password</label>
      <input type="password" required value={password} onChange={(e) => setPassword(e.target.value)} className="input" />
      <button className="btn" disabled={loading}>{loading ? 'Signing in…' : 'Sign in'}</button>
      {error && <p className="error">{error}</p>}
    </form>
  );
}

export default function LoginPage() {
  return (
    <div className="container" style={{ maxWidth: 420 }}>
      <h1>Sign in</h1>
      <Suspense fallback={<div className="card" style={{ marginTop: 16 }}>Loading…</div>}>
        <LoginForm />
      </Suspense>
      <p>
        Don't have an account? <Link href="/auth/signup">Create now</Link>
      </p>
    </div>
  );
}
