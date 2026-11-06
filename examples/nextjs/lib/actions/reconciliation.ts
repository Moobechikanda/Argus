'use server';

/**
 * Server Actions for the reconciliation module.
 * All operations use the Supabase server-side client (anon key + RLS).
 * service_role is never used here — only in the Python worker.
 */

import { createClient } from '@/lib/supabase/server';
import { revalidatePath } from 'next/cache';

export async function createImportJob(input: { dataSourceId: string; fileRef: string }) {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return { error: 'Not authenticated' };
  const metadata = (user.app_metadata ?? {}) as {
    memberships?: { company_id: string; role: string }[];
    active_company_id?: string;
  };
  const companyId = metadata.active_company_id;
  const role = metadata.memberships?.find((m) => m.company_id === companyId)?.role;
  if (!companyId || (role !== 'owner' && role !== 'admin')) return { error: 'Admin access required' };
  const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  if (!uuid.test(input.dataSourceId) || typeof input.fileRef !== 'string' || input.fileRef.length > 256) {
    return { error: 'Invalid import reference' };
  }
  const parts = input.fileRef.split('/');
  if (parts.length !== 3 || parts[0] !== companyId || parts[1] !== input.dataSourceId ||
      !uuid.test(parts[2].replace(/\.(csv|json|jsonl)$/i, '')) ||
      !/^[0-9a-f-]{36}\.(csv|json|jsonl)$/i.test(parts[2])) {
    return { error: 'Invalid import reference' };
  }
  const { data: source } = await supabase.from('reconciliation_data_sources')
    .select('id').eq('id', input.dataSourceId).eq('company_id', companyId)
    .is('deleted_at', null).maybeSingle();
  if (!source) return { error: 'Data source not found' };
  const { data: job, error } = await supabase.from('reconciliation_import_jobs')
    .insert({ company_id: companyId, data_source_id: source.id, status: 'pending',
      file_ref: input.fileRef, created_by: user.id })
    .select('id').single();
  if (error || !job) return { error: error?.message ?? 'Unable to create import job' };
  revalidatePath('/dashboard/reconciliation/imports');
  revalidatePath('/dashboard/reconciliation');
  return { ok: true, jobId: job.id };
}

export async function createDataSource(formData: FormData) {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return { error: 'Not authenticated' };

  const name = String(formData.get('name') ?? '').trim();
  const description = String(formData.get('description') ?? '').trim();
  const sourceType = String(formData.get('source_type') ?? 'file');
  const connectionConfigRaw = String(formData.get('connection_config') ?? '{}');

  if (!name) return { error: 'Name is required' };

  let connectionConfig: Record<string, unknown> = {};
  try {
    connectionConfig = JSON.parse(connectionConfigRaw);
  } catch {
    return { error: 'connection_config is invalid (JSON expected)' };
  }

  // app_metadata.active_company_id define o tenant ativo
  const appMeta = (user.app_metadata ?? {}) as {
    memberships?: { company_id: string; role: string }[];
    active_company_id?: string;
  };
  const companyId = appMeta.active_company_id;
  if (!companyId) return { error: 'No active company selected' };

  const { error } = await supabase
    .from('reconciliation_data_sources')
    .insert({
      company_id: companyId,
      name,
      description: description || null,
      source_type: sourceType,
      connection_config: connectionConfig,
      created_by: user.id,
    });

  if (error) return { error: error.message };

  revalidatePath('/dashboard/reconciliation/data-sources');
  return { ok: true };
}

export async function deleteDataSource(formData: FormData) {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return { error: 'Not authenticated' };

  const dataSourceId = String(formData.get('data_source_id') ?? '').trim();
  if (!dataSourceId) return { error: 'Data source ID is required' };

  const appMeta = (user.app_metadata ?? {}) as {
    memberships?: { company_id: string; role: string }[];
    active_company_id?: string;
  };
  const companyId = appMeta.active_company_id;
  if (!companyId) return { error: 'No active company selected' };

  const myRole = appMeta.memberships?.find((m) => m.company_id === companyId)?.role ?? 'viewer';
  if (myRole !== 'owner' && myRole !== 'admin') {
    return { error: 'Only admin or owner can delete data sources' };
  }

  // Soft-delete: set deleted_at so the record is hidden but audit history is preserved
  const { error } = await supabase
    .from('reconciliation_data_sources')
    .update({ deleted_at: new Date().toISOString() })
    .eq('id', dataSourceId)
    .eq('company_id', companyId)
    .is('deleted_at', null);

  if (error) return { error: error.message };

  revalidatePath('/dashboard/reconciliation/data-sources');
  return { ok: true };
}

export async function startReconciliationRun(formData: FormData) {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return { error: 'Not authenticated' };

  const appMeta = (user.app_metadata ?? {}) as {
    memberships?: { company_id: string; role: string }[];
    active_company_id?: string;
  };
  const companyId = appMeta.active_company_id;
  if (!companyId) return { error: 'No active company selected' };

  // Apenas admin+ podem iniciar runs de reconciliação
  const myRole = appMeta.memberships?.find((m) => m.company_id === companyId)?.role ?? 'viewer';
  if (myRole !== 'owner' && myRole !== 'admin') {
    return { error: 'Only admin or owner can start reconciliation runs' };
  }

  const { error } = await supabase
    .from('reconciliation_reconciliation_runs')
    .insert({
      company_id: companyId,
      status: 'queued',
      blocking_rules: JSON.parse(String(formData.get('blocking_rules') ?? '[]')),
      comparison_config: JSON.parse(String(formData.get('comparison_config') ?? '{}')),
      created_by: user.id,
    });

  if (error) return { error: error.message };

  revalidatePath('/dashboard/reconciliation/runs');
  return { ok: true };
}

export async function acceptMatch(candidateId: string) {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return { error: 'Not authenticated' };

  const appMeta = (user.app_metadata ?? {}) as {
    memberships?: { company_id: string; role: string }[];
    active_company_id?: string;
  };
  const companyId = appMeta.active_company_id;
  if (!companyId) return { error: 'No active company selected' };

  const myRole = appMeta.memberships?.find((m) => m.company_id === companyId)?.role ?? 'viewer';
  if (myRole !== 'owner' && myRole !== 'admin') {
    return { error: 'Only admin or owner can accept matches' };
  }

  // Busca dados do candidato antes de atualizar (para auditoria e entidade)
  const { data: candidate, error: candErr } = await supabase
    .from('reconciliation_match_candidates')
    .select('record_a_id, record_b_id, match_score, entity_id')
    .eq('id', candidateId)
    .eq('company_id', companyId)
    .eq('status', 'pending')
    .single();

  if (candErr || !candidate) return { error: 'Candidate not found or already reviewed' };

  // Atualiza o candidato para accepted
  const { error: updErr } = await supabase
    .from('reconciliation_match_candidates')
    .update({
      status: 'accepted',
      reviewer_id: user.id,
      reviewed_at: new Date().toISOString(),
    })
    .eq('id', candidateId)
    .eq('company_id', companyId)
    .eq('status', 'pending');

  if (updErr) return { error: updErr.message };

  // --- Human review gate: create entity linking both records (if not already) ---
  let entityId = candidate.entity_id;

  if (!entityId) {
    // Verifica se qualquer um dos registros ja pertence a uma entidade
    const { data: existingIds } = await supabase
      .from('reconciliation_identifiers')
      .select('entity_id, source_record_id')
      .eq('company_id', companyId)
      .in('source_record_id', [candidate.record_a_id, candidate.record_b_id]);

    const existingEntityId = existingIds?.[0]?.entity_id;

    if (existingEntityId) {
      entityId = existingEntityId;
      // Adiciona o outro registro à entidade existente
      const found = existingIds?.find((i) => i.source_record_id === candidate.record_a_id);
      const otherRecordId = found ? candidate.record_b_id : candidate.record_a_id;
      await supabase.from('reconciliation_identifiers').insert({
        entity_id: entityId,
        source_record_id: otherRecordId,
        companyId,
        confidence: candidate.match_score,
      });
    } else {
      // Cria nova entidade com dados mesclados dos dois registros
      const { data: recA } = await supabase
        .from('reconciliation_source_records')
        .select('raw_data')
        .eq('id', candidate.record_a_id)
        .eq('company_id', companyId)
        .single();
      const { data: recB } = await supabase
        .from('reconciliation_source_records')
        .select('raw_data')
        .eq('id', candidate.record_b_id)
        .eq('company_id', companyId)
        .single();

      const canonicalData: Record<string, unknown> = {};
      for (const r of [recA?.raw_data, recB?.raw_data]) {
        if (r && typeof r === 'object') {
          for (const [k, v] of Object.entries(r)) {
            if (!(k in canonicalData)) canonicalData[k] = v;
          }
        }
      }

      const { data: newEntity, error: entErr } = await supabase
        .from('reconciliation_entities')
        .insert({
          company_id: companyId,
          canonical_data: canonicalData,
          survivorship_rule: 'first_non_null_wins',
          record_count: 2,
          status: 'candidate',
          created_by: user.id,
        })
        .select('id')
        .single();

      if (entErr) return { error: entErr.message };
      entityId = newEntity.id;

      // Vincula ambos os registros à entidade
      await supabase.from('reconciliation_identifiers').insert([
        { entity_id: entityId, source_record_id: candidate.record_a_id, companyId, confidence: candidate.match_score },
        { entity_id: entityId, source_record_id: candidate.record_b_id, companyId, confidence: candidate.match_score },
      ]);
    }

    // Atualiza o candidato com o entity_id
    await supabase
      .from('reconciliation_match_candidates')
      .update({ entity_id: entityId })
      .eq('id', candidateId);
  }

  // Audit log da decisao do revisor
  await supabase.rpc('log_audit', {
    _action: 'match.accepted' as const,
    _company_id: companyId,
    _target_table: 'reconciliation_match_candidates',
    _target_id: candidateId,
    _metadata: {
      record_a_id: candidate.record_a_id,
      record_b_id: candidate.record_b_id,
      match_score: candidate.match_score,
      reviewer_id: user.id,
      entity_id: entityId,
    },
  });

  revalidatePath('/dashboard/reconciliation/review');
  revalidatePath('/dashboard/reconciliation/entities');
  return { ok: true, entityId };
}

export async function rejectMatch(candidateId: string) {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return { error: 'Not authenticated' };

  const appMeta = (user.app_metadata ?? {}) as {
    memberships?: { company_id: string; role: string }[];
    active_company_id?: string;
  };
  const companyId = appMeta.active_company_id;
  if (!companyId) return { error: 'No active company selected' };

  const myRole = appMeta.memberships?.find((m) => m.company_id === companyId)?.role ?? 'viewer';
  if (myRole !== 'owner' && myRole !== 'admin') {
    return { error: 'Only admin or owner can reject matches' };
  }

  const { data: candidate } = await supabase
    .from('reconciliation_match_candidates')
    .select('record_a_id, record_b_id, match_score')
    .eq('id', candidateId)
    .eq('company_id', companyId)
    .eq('status', 'pending')
    .single();

  const { error: updErr } = await supabase
    .from('reconciliation_match_candidates')
    .update({
      status: 'rejected',
      reviewer_id: user.id,
      reviewed_at: new Date().toISOString(),
    })
    .eq('id', candidateId)
    .eq('company_id', companyId)
    .eq('status', 'pending');

  if (updErr) return { error: updErr.message };

  await supabase.rpc('log_audit', {
    _action: 'match.rejected' as const,
    _company_id: companyId,
    _target_table: 'reconciliation_match_candidates',
    _target_id: candidateId,
    _metadata: {
      record_a_id: candidate?.record_a_id,
      record_b_id: candidate?.record_b_id,
      match_score: candidate?.match_score,
      reviewer_id: user.id,
    },
  });

  revalidatePath('/dashboard/reconciliation/review');
  return { ok: true };
}

export async function confirmEntity(entityId: string) {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return { error: 'Not authenticated' };

  const appMeta = (user.app_metadata ?? {}) as {
    memberships?: { company_id: string; role: string }[];
    active_company_id?: string;
  };
  const companyId = appMeta.active_company_id;
  if (!companyId) return { error: 'No active company selected' };

  const myRole = appMeta.memberships?.find((m) => m.company_id === companyId)?.role ?? 'viewer';
  if (myRole !== 'owner' && myRole !== 'admin') {
    return { error: 'Only admin or owner can confirm entities' };
  }

  const { data: entity } = await supabase
    .from('reconciliation_entities')
    .select('record_count, status')
    .eq('id', entityId)
    .eq('company_id', companyId)
    .eq('status', 'candidate')
    .single();

  const { error: updErr } = await supabase
    .from('reconciliation_entities')
    .update({
      status: 'confirmed',
      updated_at: new Date().toISOString(),
    })
    .eq('id', entityId)
    .eq('company_id', companyId)
    .eq('status', 'candidate');

  if (updErr) return { error: updErr.message };

  await supabase.rpc('log_audit', {
    _action: 'entity.confirmed' as const,
    _company_id: companyId,
    _target_table: 'reconciliation_entities',
    _target_id: entityId,
    _metadata: {
      record_count: entity?.record_count,
      reviewer_id: user.id,
    },
  });

  revalidatePath('/dashboard/reconciliation/entities');
  return { ok: true };
}

export async function exportEntity(entityId: string) {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return { error: 'Not authenticated' };

  const appMeta = (user.app_metadata ?? {}) as {
    memberships?: { company_id: string; role: string }[];
    active_company_id?: string;
  };
  const companyId = appMeta.active_company_id;
  if (!companyId) return { error: 'No active company selected' };

  const myRole = appMeta.memberships?.find((m) => m.company_id === companyId)?.role ?? 'viewer';
  if (myRole !== 'owner' && myRole !== 'admin' && myRole !== 'member') {
    return { error: 'Only members can export entities' };
  }

  // Busca a entidade (RLS garante acesso apenas à empresa ativa)
  const { data: entity, error: entErr } = await supabase
    .from('reconciliation_entities')
    .select('id, canonical_data, survivorship_rule, record_count, status, created_at, updated_at')
    .eq('id', entityId)
    .eq('company_id', companyId)
    .single();

  if (entErr || !entity) return { error: 'Entity not found' };

  // Busca os registros fonte vinculados à entidade
  const { data: identifiers } = await supabase
    .from('reconciliation_identifiers')
    .select('source_record_id, confidence')
    .eq('entity_id', entityId)
    .eq('company_id', companyId);

  const sourceRecordIds = (identifiers ?? []).map((i) => i.source_record_id);

  const { data: sourceRecords } = await supabase
    .from('reconciliation_source_records')
    .select('id, source_record_id, raw_data, created_at')
    .eq('company_id', companyId)
    .in('id', sourceRecordIds.length > 0 ? sourceRecordIds : ['__none__']);

  // Gera CSV
  const csvLines: string[] = [];
  csvLines.push('entity_id,entity_status,record_count,canonical_data,source_record_id,source_record_raw_data,source_created_at');
  csvLines.push(
    [
      entityId,
      entity.status,
      entity.record_count,
      `"${JSON.stringify(entity.canonical_data).replace(/"/g, '""')}"`,
      '',
      '',
      entity.created_at,
    ].join(',')
  );

  for (const sr of sourceRecords ?? []) {
    csvLines.push(
      [
        '',
        '',
        '',
        '',
        sr.source_record_id,
        `"${JSON.stringify(sr.raw_data).replace(/"/g, '""')}"`,
        sr.created_at,
      ].join(',')
    );
  }

  const csv = csvLines.join('\n');
  const fileName = `entity_${entityId.slice(0, 8)}.csv`;
  const bucket = 'reconciliation-exports';
  const objectPath = `${companyId}/${fileName}`;

  // Faz upload do CSV para o Supabase Storage e gera URL assinada (expira em 1 hora)
  let signedUrl: string | null = null;
  try {
    const { error: upErr } = await supabase.storage
      .from(bucket)
      .upload(objectPath, csv, {
        contentType: 'text/csv',
        upsert: true,
      });

    if (!upErr) {
      const { data: urlData, error: urlErr } = await supabase.storage
        .from(bucket)
        .createSignedUrl(objectPath, 3600);
      if (!urlErr && urlData?.signedUrl) {
        signedUrl = urlData.signedUrl;
      }
    }
  } catch {
    // Storage nao disponível ou bucket nao existe — fallback para CSV inline
    signedUrl = null;
  }

  // Audit log da exportacao
  await supabase.rpc('log_audit', {
    _action: 'entity.exported' as const,
    _company_id: companyId,
    _target_table: 'reconciliation_entities',
    _target_id: entityId,
    _metadata: {
      record_count: entity.record_count,
      exported_by: user.id,
      export_format: 'csv',
      export_delivery: signedUrl ? 'signed_url' : 'inline_fallback',
    },
  });

  if (signedUrl) {
    return { ok: true, signedUrl, filename: fileName };
  }

  return { ok: true, csv, filename: fileName };
}

export async function retryImportJob(formData: FormData) {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return { error: 'Not authenticated' };

  const importJobId = String(formData.get('import_job_id') ?? '').trim();
  if (!importJobId) return { error: 'Import job ID is required' };

  const appMeta = (user.app_metadata ?? {}) as {
    memberships?: { company_id: string; role: string }[];
    active_company_id?: string;
  };
  const companyId = appMeta.active_company_id;
  if (!companyId) return { error: 'No active company selected' };

  const myRole = appMeta.memberships?.find((m) => m.company_id === companyId)?.role ?? 'viewer';
  if (myRole !== 'owner' && myRole !== 'admin') {
    return { error: 'Only admin or owner can retry import jobs' };
  }

  const { error } = await supabase
    .from('reconciliation_import_jobs')
    .update({ status: 'pending', started_at: null, completed_at: null, error_count: null, error: null })
    .eq('id', importJobId)
    .eq('company_id', companyId)
    .eq('status', 'failed');

  if (error) return { error: error.message };

  revalidatePath('/dashboard/reconciliation/imports');
  return { ok: true };
}

export async function retryReconciliationRun(formData: FormData) {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return { error: 'Not authenticated' };

  const runId = String(formData.get('run_id') ?? '').trim();
  if (!runId) return { error: 'Run ID is required' };

  const appMeta = (user.app_metadata ?? {}) as {
    memberships?: { company_id: string; role: string }[];
    active_company_id?: string;
  };
  const companyId = appMeta.active_company_id;
  if (!companyId) return { error: 'No active company selected' };

  const myRole = appMeta.memberships?.find((m) => m.company_id === companyId)?.role ?? 'viewer';
  if (myRole !== 'owner' && myRole !== 'admin') {
    return { error: 'Only admin or owner can retry reconciliation runs' };
  }

  const { error } = await supabase
    .from('reconciliation_reconciliation_runs')
    .update({ status: 'queued', started_at: null, completed_at: null, error: null })
    .eq('id', runId)
    .eq('company_id', companyId)
    .eq('status', 'failed');

  if (error) return { error: error.message };

  revalidatePath('/dashboard/reconciliation/runs');
  return { ok: true };
}

export async function resolveDiscrepancy(formData: FormData) {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return { error: 'Not authenticated' };

  const appMeta = (user.app_metadata ?? {}) as {
    memberships?: { company_id: string; role: string }[];
    active_company_id?: string;
  };
  const companyId = appMeta.active_company_id;
  if (!companyId) return { error: 'No active company selected' };

  const myRole = appMeta.memberships?.find((m) => m.company_id === companyId)?.role ?? 'viewer';
  if (myRole !== 'owner' && myRole !== 'admin') {
    return { error: 'Only admin or owner can resolve discrepancies' };
  }

  const discrepancyId = String(formData.get('discrepancy_id') ?? '').trim();
  const resolution = String(formData.get('resolution') ?? '').trim(); // 'winner_source' | 'manual'
  const winningSourceRecordId = String(formData.get('winning_source_record_id') ?? '').trim();
  const manualValueRaw = String(formData.get('manual_value') ?? '').trim();

  if (!discrepancyId) return { error: 'Discrepancy ID is required' };
  if (resolution !== 'winner_source' && resolution !== 'manual') {
    return { error: 'Invalid resolution' };
  }

  // Busca a discrepancia para auditoria
  const { data: discrepancy } = await supabase
    .from('reconciliation_discrepancies')
    .select('entity_id, field_name, competing_value, source_record_id, resolution')
    .eq('id', discrepancyId)
    .eq('company_id', companyId)
    .eq('resolution', 'unresolved')
    .single();

  if (!discrepancy) return { error: 'Discrepancy not found or already resolved' };

  if (resolution === 'winner_source') {
    if (!winningSourceRecordId) return { error: 'Winning source record ID is required' };
  } else {
    if (!manualValueRaw) return { error: 'Manual value is required' };
    try {
      JSON.parse(manualValueRaw);
    } catch {
      // Plain string resolutions are valid; the value itself is never audited.
    }
  }

  const { error: updErr } = await supabase
    .from('reconciliation_discrepancies')
    .update({
      resolution: resolution as any,
      reviewer_id: user.id,
      resolved_at: new Date().toISOString(),
    })
    .eq('id', discrepancyId)
    .eq('company_id', companyId)
    .eq('resolution', 'unresolved');

  if (updErr) return { error: updErr.message };

  await supabase.rpc('log_audit', {
    _action: 'discrepancy.resolved' as const,
    _company_id: companyId,
    _target_table: 'reconciliation_discrepancies',
    _target_id: discrepancyId,
    // Do not persist the selected/manual value or source fields in audit metadata.
    _metadata: {
      discrepancy_id: discrepancyId,
      resolution,
      reviewer_id: user.id,
      previous_state: 'unresolved',
    },
  });

  revalidatePath('/dashboard/reconciliation/discrepancies');
  return { ok: true };
}

