'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import Link from 'next/link';
import { createClient } from '@/lib/supabase/client';

export default function SignupPage() {
  const router = useRouter();
  const [fullName, setFullName] = useState('');
  const [companyName, setCompanyName] = useState('');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [info, setInfo] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    setInfo(null);

      if (password.length < 12) {
        setError('Password must be at least 12 characters.');
        return;
      }

    setLoading(true);
    const supabase = createClient();
    const { error } = await supabase.auth.signUp({
      email,
      password,
      options: {
        data: { full_name: fullName, company_name: companyName },
        emailRedirectTo: `${location.origin}/auth/callback`,
      },
    });
    setLoading(false);

    if (error) {
      setError(error.message);
      return;
    }

    setInfo('Account created. Check your email to confirm before signing in.');
    setTimeout(() => router.push('/auth/login'), 4000);
  }

  return (
    <div className="container" style={{ maxWidth: 420 }}>
      <h1>Create account</h1>
      <form onSubmit={onSubmit} className="card" style={{ marginTop: 16 }}>
        <label className="label">Full name</label>
        <input required value={fullName} onChange={(e) => setFullName(e.target.value)} className="input" />

        <label className="label">Company/workspace name</label>
        <input required value={companyName} onChange={(e) => setCompanyName(e.target.value)} className="input" placeholder="Ex: My Startup Inc" />

        <label className="label">Email</label>
        <input type="email" required value={email} onChange={(e) => setEmail(e.target.value)} className="input" />

        <label className="label">Password (min. 12 chars, uppercase, lowercase, number, symbol)</label>
        <input type="password" required minLength={12} value={password} onChange={(e) => setPassword(e.target.value)} className="input" />

        <button className="btn" disabled={loading}>{loading ? 'Creating…' : 'Create account'}</button>
        {error && <p className="error">{error}</p>}
        {info && <p className="success">{info}</p>}
      </form>
      <p>
        Already have an account? <Link href="/auth/login">Sign in</Link>
      </p>
    </div>
  );
}
