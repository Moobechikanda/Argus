'use client';

import { useRouter } from 'next/navigation';
import { useState } from 'react';
import { createClient } from '@/lib/supabase/client';

type Props = {
  userId: string;
  currentRole: string;
  isSelf: boolean;
  callerRole: string;
};

export function MemberActions({ userId, currentRole, isSelf, callerRole }: Props) {
  const router = useRouter();
  const [loading, setLoading] = useState(false);
  const supabase = createClient();

  // Apenas owner promove a owner. Admin não pode mexer em owner.
  const canChangeRole = callerRole === 'owner' || (callerRole === 'admin' && currentRole !== 'owner');
  const canRemove = !isSelf && canChangeRole;

  async function onRoleChange(e: React.ChangeEvent<HTMLSelectElement>) {
    const newRole = e.target.value;
    if (newRole === currentRole) return;
    if (!confirm(`Change role to "${newRole}"?`)) return;

    setLoading(true);
    const { error } = await supabase
      .from('memberships')
      .update({ role: newRole })
      .eq('user_id', userId);
    setLoading(false);

    if (error) {
      alert('Error: ' + error.message);
      return;
    }
    router.refresh();
  }

  async function onRemove() {
    if (!confirm('Remove this member from the company?')) return;
    setLoading(true);
    const { error } = await supabase
      .from('memberships')
      .delete()
      .eq('user_id', userId);
    setLoading(false);

    if (error) {
      alert('Error: ' + error.message);
      return;
    }
    router.refresh();
  }

  return (
    <div style={{ display: 'flex', gap: 8 }}>
      {canChangeRole && (
        <select defaultValue={currentRole} onChange={onRoleChange} disabled={loading} className="select" style={{ marginBottom: 0, padding: '4px 8px', fontSize: 12, width: 'auto' }}>
          {callerRole === 'owner' && <option value="owner">owner</option>}
          <option value="admin">admin</option>
          <option value="member">member</option>
          <option value="viewer">viewer</option>
        </select>
      )}
      {canRemove && (
        <button className="btn danger" style={{ padding: '4px 8px', fontSize: 12 }} onClick={onRemove} disabled={loading}>
          Remove
        </button>
      )}
    </div>
  );
}
