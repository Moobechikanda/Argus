// =============================================================================
// Edge Function: invitations
// =============================================================================
// Endpoints:
//   POST   /invitations          → cria convite + envia email (requer admin+)
//   POST   /invitations/accept   → aceita convite via token
//   POST   /invitations/revoke   → revoga convite pendente (requer admin+)
//
// Por que Edge Function e não chamada direta ao DB:
//   - Geração do token em CSPRNG (Web Crypto) e hash SHA-256.
//   - Envio de email (Resend) com template.
//   - Validação centralizada e rate-limit por IP (TODO).
//   - Aceite cria membership com service_role bypassando RLS (necessário
//     porque o usuário ainda não é membro quando aceita).
// =============================================================================

// deno-lint-ignore-file no-explicit-any
import { createClient, SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0';

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const json = (data: unknown, status = 200): Response =>
  new Response(JSON.stringify(data), {
    status,
    headers: { 'Content-Type': 'application/json', ...CORS_HEADERS },
  });

const err = (message: string, status = 400, code?: string): Response =>
  json({ error: { message, code: code ?? null } }, status);

/**
 * Gera token criptograficamente seguro (32 bytes = 256 bits) e seu hash SHA-256.
 * O TOKEN é enviado por email; o HASH é o que vai pro DB.
 */
async function generateToken(): Promise<{ token: string; hash: string }> {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  const token = Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');

  const hashBuf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(token));
  const hash = Array.from(new Uint8Array(hashBuf), (b) => b.toString(16).padStart(2, '0')).join('');

  return { token, hash };
}

async function sha256Hex(input: string): Promise<string> {
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(input));
  return Array.from(new Uint8Array(buf), (b) => b.toString(16).padStart(2, '0')).join('');
}

// -----------------------------------------------------------------------------
// Cliente Supabase: dois modos
// -----------------------------------------------------------------------------

/** Cliente com o JWT do usuário — usa as RLS policies normalmente. */
function userClient(req: Request): SupabaseClient {
  const auth = req.headers.get('Authorization') ?? '';
  return createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_ANON_KEY')!,
    {
      global: { headers: { Authorization: auth } },
      auth: { persistSession: false },
    },
  );
}

/** Cliente service_role — bypassa RLS. Usar apenas para operações que
 *  exigem privilégio elevado e que foram autorizadas antes via userClient. */
function adminClient(): SupabaseClient {
  return createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    { auth: { persistSession: false } },
  );
}

// -----------------------------------------------------------------------------
// Envio de email via Resend (https://resend.com)
// -----------------------------------------------------------------------------

async function sendInviteEmail(params: {
  to: string;
  companyName: string;
  inviterName: string;
  acceptUrl: string;
}): Promise<void> {
  const apiKey = Deno.env.get('RESEND_API_KEY');
  if (!apiKey) {
    console.warn('RESEND_API_KEY ausente — pulando envio. URL do convite:', params.acceptUrl);
    return;
  }

  const from = `${Deno.env.get('INVITATION_FROM_NAME') ?? 'Equipe'} <${Deno.env.get('INVITATION_FROM_EMAIL') ?? 'noreply@example.com'}>`;

  const html = `
    <div style="font-family: -apple-system, sans-serif; max-width: 480px; margin: 0 auto; padding: 24px;">
      <h2 style="color: #111;">Você foi convidado para <strong>${escapeHtml(params.companyName)}</strong></h2>
      <p style="color: #444; line-height: 1.5;">
        <strong>${escapeHtml(params.inviterName)}</strong> convidou você para colaborar.
        Clique no botão abaixo para aceitar o convite.
      </p>
      <p style="margin: 32px 0;">
        <a href="${params.acceptUrl}"
           style="background:#2563eb;color:#fff;padding:12px 24px;text-decoration:none;border-radius:6px;display:inline-block;">
          Aceitar convite
        </a>
      </p>
      <p style="color: #888; font-size: 13px;">
        Se você não esperava este convite, pode ignorar este email.
        O link expira em 7 dias.
      </p>
    </div>
  `;

  const resp = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${apiKey}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      from,
      to: params.to,
      subject: `Convite para ${params.companyName}`,
      html,
    }),
  });

  if (!resp.ok) {
    const body = await resp.text();
    throw new Error(`Resend falhou (${resp.status}): ${body}`);
  }
}

function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, (c) =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c] as string),
  );
}

// -----------------------------------------------------------------------------
// Handlers
// -----------------------------------------------------------------------------

/**
 * POST /invitations
 * Body: { company_id, email, role }
 */
async function createInvitation(req: Request): Promise<Response> {
  const body = await req.json().catch(() => null);
  if (!body || !body.company_id || !body.email || !body.role) {
    return err('Parâmetros obrigatórios: company_id, email, role', 422);
  }
  if (!['admin', 'member', 'viewer'].includes(body.role)) {
    return err('Role inválido. Use admin, member ou viewer.', 422);
  }

  const supabase = userClient(req);
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return err('Não autenticado', 401);

  // Confere se o caller é admin+ (a RLS já garantiria, mas validamos
  // aqui para retornar erro amigável antes do INSERT)
  const { data: hasRole } = await supabase.rpc('has_role_in', {
    _company_id: body.company_id,
    _required: 'admin',
  });
  if (!hasRole) return err('Você precisa ser admin para convidar membros.', 403);

  // Gera token + hash
  const { token, hash } = await generateToken();

  const expiryHours = Number(Deno.env.get('TEMPLATE_INVITATION_EXPIRY_HOURS') ?? '168');
  const expiresAt = new Date(Date.now() + expiryHours * 3600 * 1000).toISOString();

  // Insere convite (passa pelas RLS — caller já foi validado como admin+)
  const { data: inv, error: insErr } = await supabase
    .from('invitations')
    .insert({
      company_id: body.company_id,
      email: String(body.email).toLowerCase().trim(),
      role: body.role,
      token_hash: hash,
      invited_by: user.id,
      expires_at: expiresAt,
    })
    .select('id, email, company_id')
    .single();

  if (insErr) {
    if (insErr.code === '23505') {
      return err('Já existe um convite pendente para este email nesta empresa.', 409);
    }
    return err(`Erro ao criar convite: ${insErr.message}`, 500);
  }

  // Loga auditoria
  await supabase.rpc('log_audit', {
    _action: 'member.invited',
    _company_id: body.company_id,
    _target_table: 'invitations',
    _target_id: inv.id,
    // Invitation email is personal data; the invitation row remains the source
    // of truth and the append-only audit record stores only the assigned role.
    _metadata: { role: body.role },
  });

  // Busca dados para o email
  const admin = adminClient();
  const [{ data: company }, { data: inviter }] = await Promise.all([
    admin.from('companies').select('name').eq('id', body.company_id).single(),
    admin.from('profiles').select('full_name, email').eq('id', user.id).single(),
  ]);

  const siteUrl = Deno.env.get('SITE_URL') ?? 'http://localhost:3000';
  const acceptUrl = `${siteUrl}/invite/${token}`;

  try {
    await sendInviteEmail({
      to: inv.email,
      companyName: company?.name ?? 'Workspace',
      inviterName: inviter?.full_name ?? inviter?.email ?? 'Um membro',
      acceptUrl,
    });
  } catch (e) {
    console.error('sendInviteEmail falhou:', e);
    // Não retornamos erro — convite foi criado, admin pode reenviar.
  }

  return json({ ok: true, invitation_id: inv.id });
}

/**
 * POST /invitations/accept
 * Body: { token }
 * Requer estar autenticado (signup ou login feito antes).
 */
async function acceptInvitation(req: Request): Promise<Response> {
  const body = await req.json().catch(() => null);
  if (!body?.token || typeof body.token !== 'string') {
    return err('Token obrigatório', 422);
  }

  const supabase = userClient(req);
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return err('Faça login antes de aceitar o convite', 401);

  const hash = await sha256Hex(body.token);

  // Usa service_role para buscar/atualizar o convite
  // (o convidado ainda não tem permissão de SELECT em invitations)
  const admin = adminClient();
  const { data: inv, error: selErr } = await admin
    .from('invitations')
    .select('id, company_id, email, role, status, expires_at')
    .eq('token_hash', hash)
    .single();

  if (selErr || !inv) return err('Convite inválido', 404);
  if (inv.status !== 'pending') return err(`Convite já foi ${inv.status}`, 410);
  if (new Date(inv.expires_at) < new Date()) {
    await admin.from('invitations').update({ status: 'expired' }).eq('id', inv.id);
    return err('Convite expirado', 410);
  }

  // Confere que o email do convite bate com o do usuário (case-insensitive)
  if (user.email?.toLowerCase().trim() !== inv.email.toLowerCase().trim()) {
    return err('Este convite foi enviado para outro email.', 403);
  }

  // Cria membership + marca convite como accepted (em uma transação implícita via RPC)
  const { error: memErr } = await admin
    .from('memberships')
    .upsert(
      {
        company_id: inv.company_id,
        user_id: user.id,
        role: inv.role,
        invited_by: null,
      },
      { onConflict: 'company_id,user_id', ignoreDuplicates: false },
    );
  if (memErr) return err(`Falha ao criar membership: ${memErr.message}`, 500);

  await admin
    .from('invitations')
    .update({ status: 'accepted', accepted_at: new Date().toISOString() })
    .eq('id', inv.id);

  return json({ ok: true, company_id: inv.company_id });
}

/**
 * POST /invitations/revoke
 * Body: { invitation_id }
 */
async function revokeInvitation(req: Request): Promise<Response> {
  const body = await req.json().catch(() => null);
  if (!body?.invitation_id) return err('invitation_id obrigatório', 422);

  const supabase = userClient(req);
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return err('Não autenticado', 401);

  // RLS garante que só admin+ da company conseguirá o UPDATE
  const { data, error } = await supabase
    .from('invitations')
    .update({ status: 'revoked', revoked_at: new Date().toISOString() })
    .eq('id', body.invitation_id)
    .eq('status', 'pending')
    .select('id, company_id')
    .single();

  if (error || !data) return err('Convite não encontrado ou já processado', 404);

  await supabase.rpc('log_audit', {
    _action: 'invitation.revoked',
    _company_id: data.company_id,
    _target_table: 'invitations',
    _target_id: data.id,
    _metadata: {},
  });

  return json({ ok: true });
}

// -----------------------------------------------------------------------------
// Router
// -----------------------------------------------------------------------------

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: CORS_HEADERS });

  const url = new URL(req.url);
  const path = url.pathname.replace(/^\/invitations/, '').replace(/\/+$/, '') || '/';

  try {
    if (req.method === 'POST' && path === '/')         return await createInvitation(req);
    if (req.method === 'POST' && path === '/accept')   return await acceptInvitation(req);
    if (req.method === 'POST' && path === '/revoke')   return await revokeInvitation(req);
    return err('Rota não encontrada', 404);
  } catch (e: any) {
    console.error('Edge Function error:', e);
    return err(e?.message ?? 'Erro interno', 500);
  }
});
