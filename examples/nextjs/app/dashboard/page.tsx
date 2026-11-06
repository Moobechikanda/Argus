import { redirect } from 'next/navigation';
import Link from 'next/link';
import { createClient } from '@/lib/supabase/server';
import { CompanySwitcher } from '@/components/company-switcher';

export default async function DashboardPage() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect('/auth/login');

  // Read app_metadata from JWT (populated by custom_access_token_hook)
  const appMeta = (user.app_metadata ?? {}) as {
    memberships?: { company_id: string; role: string }[];
    active_company_id?: string;
  };

  const activeCompanyId = appMeta.active_company_id ?? appMeta.memberships?.[0]?.company_id;

  // Load company data in parallel
  const { data: companies } = await supabase
    .from('companies')
    .select('id, name, slug, plan');

  const { data: profile } = await supabase
    .from('profiles')
    .select('full_name, email')
    .eq('id', user.id)
    .single();

  const activeCompany = companies?.find((c) => c.id === activeCompanyId);
  const myRole = appMeta.memberships?.find((m) => m.company_id === activeCompanyId)?.role ?? 'viewer';

  return (
    <div className="container">
      <header style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 24 }}>
        <div>
          <h1>{profile?.full_name ?? user.email}</h1>
          <small style={{ color: '#666' }}>{user.email}</small>
        </div>
        <form action="/auth/logout" method="post">
          <button className="btn ghost">Logout</button>
        </form>
      </header>

      <div className="card">
        <label className="label">Active company</label>
        <CompanySwitcher
          companies={companies ?? []}
          activeCompanyId={activeCompanyId}
        />
        {activeCompany && (
          <div style={{ marginTop: 16 }}>
            <strong>{activeCompany.name}</strong>
            <span className={`badge ${myRole}`} style={{ marginLeft: 8 }}>{myRole}</span>
            <small style={{ display: 'block', color: '#666', marginTop: 4 }}>
              Plan: {activeCompany.plan} · Slug: {activeCompany.slug}
            </small>
          </div>
        )}
      </div>

      <div className="card">
        <h2 style={{ marginBottom: 12 }}>Actions</h2>
        <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap' }}>
          <Link href="/dashboard/members" className="btn">Manage members</Link>
          <Link href="/dashboard/audit" className="btn ghost">Audit history</Link>
          <Link href="/dashboard/reconciliation" className="btn">Data Reconciliation</Link>
        </div>
      </div>
    </div>
  );
}
