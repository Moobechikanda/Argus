import Link from 'next/link';

export default function Home() {
  return (
    <div className="container">
      <h1>Supabase Multi-tenant Starter</h1>
      <p style={{ margin: '16px 0', color: '#666' }}>
        Open-source template for multi-tenant SaaS with authentication, companies, roles, and invitations.
      </p>
      <div style={{ display: 'flex', gap: 12 }}>
        <Link href="/auth/login" className="btn">Sign in</Link>
        <Link href="/auth/signup" className="btn ghost">Create account</Link>
      </div>
    </div>
  );
}
