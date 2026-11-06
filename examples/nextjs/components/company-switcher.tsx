'use client';

import { useRouter } from 'next/navigation';
import { useState } from 'react';
import { createClient } from '@/lib/supabase/client';

type Props = {
  companies: { id: string; name: string }[];
  activeCompanyId?: string;
};

export function CompanySwitcher({ companies, activeCompanyId }: Props) {
  const router = useRouter();
  const [loading, setLoading] = useState(false);

  async function onChange(e: React.ChangeEvent<HTMLSelectElement>) {
    const newId = e.target.value;
    setLoading(true);
    const supabase = createClient();

    // 1. Chama RPC que atualiza user_metadata.active_company_id
    const { error } = await supabase.rpc('set_active_company', { _company_id: newId });
    if (error) {
      setLoading(false);
      alert('Error switching company: ' + error.message);
      return;
    }

    // 2. Força refresh do JWT — sem isso, o app_metadata fica desatualizado
    await supabase.auth.refreshSession();

    // 3. Refresh da rota (re-roda os Server Components)
    router.refresh();
    setLoading(false);
  }

  return (
    <select className="select" value={activeCompanyId} onChange={onChange} disabled={loading}>
      {companies.map((c) => (
        <option key={c.id} value={c.id}>{c.name}</option>
      ))}
    </select>
  );
}
