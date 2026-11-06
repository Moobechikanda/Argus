# Modelo de Segurança

Este documento descreve o **modelo de ameaças**, as **mitigações implementadas** e o **checklist de hardening** para produção.

---

## 1. Modelo de ameaças

| # | Ameaça | Mitigação |
|---|---|---|
| T1 | Usuário lê dados de outra empresa | RLS em todas as tabelas, `is_member_of()` em todas as policies |
| T2 | Usuário escreve em empresa que não pertence | `WITH CHECK` em todas as policies de INSERT/UPDATE |
| T3 | Atacante forja role no JWT | Roles vêm de `app_metadata` (server-only), não `user_metadata` |
| T4 | SQL injection via input | Sem `EXECUTE` dinâmico; queries parametrizadas no Supabase SDK |
| T5 | Schema hijacking em SECURITY DEFINER | Todas as funções têm `SET search_path = ''` e usam nomes qualificados |
| T6 | Vazamento de token de convite | Token nunca armazenado em claro (apenas SHA-256); URL HTTPS only |
| T7 | Timing attack no aceite de convite | Comparação por hash em tempo constante (SHA-256) |
| T8 | Admin se auto-promove a owner | Trigger `guard_membership_change` bloqueia |
| T9 | Último owner removido (empresa órfã) | Trigger bloqueia DELETE/UPDATE que reduz `count_owners()` a 0 |
| T10 | service_role exposto no frontend | Documentação + ausência da chave nos exemplos client-side |
| T11 | Audit log adulterado | Sem policies de UPDATE/DELETE — append-only |
| T12 | DoS via signup em massa | Email confirmation + Supabase rate limit + (recomendado) CAPTCHA |
| T13 | Email enumeration via "esqueci a senha" | Supabase Auth retorna sucesso genérico independente do email existir |
| T14 | Sessão zumbi após logout em um dispositivo | `enable_refresh_token_rotation = true` + JWT curto (1h) |
| T15 | XSS injetando código em campos | Frontend usa React (escape automático); HTML em emails é escapado |
| T16 | Vazamento de registros fonte entre tenants | RLS em `reconciliation_source_records` etc., filtrado por `company_id` via `is_member_of()` |
| T17 | Match confirmado sem revisão humana | Gate de revisão aplicado no app + trigger/RLS; auditoria em `reviewer_decisions` e `audit_log` |
| T18 | Alteração não autorizada de registros fonte (imutáveis) | Sem policies UPDATE/DELETE em `reconciliation_source_records` + trigger `guard_source_record_immutable` |
| T19 | Centralized worker credential compromised | Dedicated non-root workers, separate database logins, claim-scoped RPCs, and bounded runtime; workers remain cross-tenant trusted services |
| T20 | Forja de decisão de revisor | `reviewer_decisions` exige `reviewer_id = auth.uid()` no WITH CHECK; auditoria obrigatória |

---

## 2. Defesa em camadas

### Camada 1: Row Level Security (RLS)

- **TODAS** as tabelas de `public` têm `ENABLE ROW LEVEL SECURITY` + `FORCE ROW LEVEL SECURITY`.
- Sem policy = sem acesso (deny by default).
- Policies separadas por comando (SELECT/INSERT/UPDATE/DELETE) — nunca usar `FOR ALL`.

### Camada 2: Helper functions com SECURITY DEFINER

- `is_member_of()`, `has_role_in()`, etc. rodam como dono da função (bypassa RLS para a query interna), mas:
  - Têm `SET search_path = ''` (previne schema hijacking)
  - Usam nomes totalmente qualificados (`public.memberships`, `auth.uid()`)
  - `REVOKE EXECUTE FROM PUBLIC` + `GRANT` explícito a `authenticated`

### Camada 3: Triggers de invariantes

- `guard_membership_change` impede:
  - Remover/rebaixar último owner
  - Admin auto-promover a owner
- `handle_new_user` é tolerante a erros (não quebra signup se profile falhar)

### Camada 4: Custom JWT Claims (Auth Hook)

- `app_metadata.memberships` é injetado no token pelo backend.
- Cliente **não consegue forjar** (campo é immutable do lado do cliente).
- Permite RLS consultar role sem hit no banco em toda query.

### Camada 5: Auditoria

- Tabela `audit_log` é append-only via RLS.
- Toda mudança crítica passa por `log_audit()`.
- IP e User-Agent capturados automaticamente.

---

## 3. Boas práticas críticas

### ✅ FAÇA

- Use `getUser()` (revalida JWT) em vez de `getSession()` (só lê cookie) em SSR.
- Habilite **email confirmation** (`enable_confirmations = true`).
- Use **MFA** para owners e admins.
- Rote a **anon key** se suspeitar de vazamento (no painel do Supabase).
- Configure **Site URL** corretamente — JWT é válido apenas para o site configurado.
- Use HTTPS em produção (Supabase já força).
- Habilite o **Custom Access Token Hook** no painel.
- Configure **alertas** no painel para tentativas de login anormais.
- Faça **backups regulares** (Supabase faz, mas confira retenção do seu plano).
- Use **branch deployments** do Supabase para testar migrations antes de prod.

### ❌ NÃO FAÇA

- ❌ Nunca exponha `SUPABASE_SERVICE_ROLE_KEY` no frontend (incluindo `NEXT_PUBLIC_*`).
- ❌ Nunca desabilite RLS "só pra testar" e esqueça ligado.
- ❌ Nunca confie em `user_metadata` para autorização — é editável pelo próprio usuário.
- ❌ Nunca crie função `SECURITY DEFINER` sem `SET search_path = ''`.
- ❌ Nunca armazene tokens de convite em claro.
- ❌ Nunca permita criação de admin/owner via API pública sem autorização explícita.
- ❌ Nunca use `FOR ALL` em policy — sempre separe por comando.
- ❌ Nunca skip de hooks de pre-commit (incluindo SQL lint).

---

## 4. Checklist de produção

Antes de ir pro ar:

- [ ] Site URL configurada corretamente no painel
- [ ] Email confirmation habilitada
- [ ] Política de senha forte habilitada (mín. 12 chars + classes)
- [ ] Custom Access Token Hook habilitado e apontando para `public.custom_access_token_hook`
- [ ] MFA habilitado (opcional para member, obrigatório para admin/owner)
- [ ] CAPTCHA configurado nos endpoints públicos (signup, reset password)
- [ ] Webhook de alertas configurado (login from new device, etc)
- [ ] Backup automático ativo
- [ ] `RESEND_API_KEY` (ou SMTP) configurado nos secrets das Edge Functions
- [ ] Service role key NÃO está no repositório nem em variáveis públicas
- [ ] CORS configurado restritivo nas Edge Functions (não `*` em produção)
- [ ] Rate limiting adicional configurado se o caso de uso exigir
- [ ] Logs do Supabase sendo retidos ou enviados para SIEM externo
- [ ] LGPD/GDPR: política de retenção de `audit_log` documentada
- [ ] LGPD/GDPR: rota de exportação/anonimização do usuário implementada

---

## 5. LGPD / GDPR

### Direito ao esquecimento

Usar **anonimização** em vez de DELETE completo, para preservar audit_log:

```sql
-- Exemplo de função admin (rodar como service_role)
UPDATE auth.users
SET email = 'anonymized-' || id || '@deleted.local'
WHERE id = '<user_id>';

UPDATE public.profiles
SET email = 'anonymized@deleted.local',
    full_name = '[anonimizado]',
    avatar_url = NULL,
    deleted_at = now()
WHERE id = '<user_id>';
```

### Direito ao acesso (export)

Implementar Edge Function `/me/export` que retorna JSON com:
- Profile do usuário
- Lista de memberships
- Audit log das próprias ações (`WHERE actor_user_id = auth.uid()`)

### Retenção de audit log

Por padrão, audit_log não é purgado. Sugestões:
- Manter 1 ano completo
- Após 1 ano, manter apenas ações críticas (`company.deleted`, `ownership.transferred`)
- Job de retenção rodando como service_role (fora do RLS)

---

## 6. Reportando vulnerabilidades

Se você encontrou uma falha de segurança neste template, **NÃO abra issue pública**.

Envie via [GitHub Security Advisory](https://github.com/tbarbito/supabase-multitenant-starter/security/advisories/new) (disclosure privado).

Aceitamos disclosure responsável e creditamos quem reportar.

---

## 7. Reconciliation module � verified limitations

### 7.1 Encryption status

- Field-level encryption is **not implemented in the processing path**. The `raw_data_encrypted` and `normalized_data_encrypted` columns are nullable and current import/matching paths use `raw_data` and `normalized_data` plaintext.
- The legacy table `reconciliation_encryption_keys` stores raw key bytes in the database. Corrective migrations `20261101000003_contain_encryption_keys_and_audit.sql` and `20261101000007_revoke_all_legacy_crypto_overloads.sql` remove application-role table grants/policies and revoke every legacy encrypt/decrypt overload.
- Do not insert keys or call those legacy functions. The table is not an external KMS and this change is containment, not an encryption architecture.

### 7.2 Worker and Storage boundary

- Import and matching use separate PostgreSQL logins and scoped claim RPCs. The workers are a **centralized cross-tenant trusted service**: each can claim work from every tenant over time. RPCs scope each operation to its active job or run, but the worker process and its credential remain a cross-tenant trust boundary.
- The import bucket is private. Authenticated tenant admins can upload to a company/data-source namespace; reads are available through a short-lived claim-bound signer. Workers do not accept local paths or user-supplied URLs.
- Workers use non-root containers, read-only root filesystems, dropped Linux capabilities, `no-new-privileges`, and bounded private temporary storage. Splink field identifiers are validated and quoted; unsafe source headers are excluded from generated SQL.
- Imports are **enabled when the import worker has credentials and is started**. Do not start/restart workers in a shared environment until separate least-privilege DB credentials, local Storage/signer behavior, monitoring, and authorized data-handling requirements are verified.

### 7.3 Audit and data handling

- Retention cleanup is disabled without an approved value. Only the dedicated `reconciliation_scheduler` role can execute its wrapper; tenant users have no audit table mutation grants after `20261101000005_revoke_audit_mutation_grants.sql`. The local cron job was disabled during local verification and must be deliberately reconfigured per environment.
- Authenticated calls to `log_audit` now require membership in the supplied tenant; trigger-generated events retain their database-trigger path. The internal reconciliation audit helper is not executable by application roles.
- Audit metadata must contain references and operational counts only. Do not log record values, invitation emails, credentials, encryption keys, or signed Storage URLs. Reconciliation review pages and exports still render plaintext source fields to authorized tenant users.
- log_audit still permits an authenticated member to submit fabricated action/metadata for their own tenant; the current containment prevents cross-tenant entries but does not make tenant audit events tamper-proof.

### 7.4 Verification status

- Implemented and locally exercised: private Storage upload/download boundary, claim signer, import path validation, worker role boundaries, matching SQL field validation, and container builds.
- Corrective key containment and audit tenant checks were applied locally and passed 21 pgTAP assertions. Lease and worker RPC checks passed 46 assertions; Storage policy checks passed 6; base RLS checks passed 26.
- Not implemented: field encryption, external key management, encrypted import and matching, controlled decryption for review, and a key rotation/recovery process.
- No security-standard, legal-compliance, government-readiness, or production-readiness claim is made by these repository checks.

## 8. Phase 2A.3 encryption assessment

The current reconciliation data path is **plaintext**, despite the legacy
`raw_data_encrypted` / `normalized_data_encrypted` columns and old
`pgsodium` functions. Current import and matching RPCs use the JSONB plaintext
columns, and the most recent containment migrations revoke application access
to the database-held prototype keys and legacy crypto functions. There is no
external KMS adapter, envelope-encryption workflow, authorized decrypt
endpoint, or key recovery process.

RLS currently provides tenant isolation, not field-level authorization: a
company member can read sensitive source data through the existing table
policies, and current review/export flows materialize plaintext in server and
browser contexts. The private import bucket also stores the uploaded source
file as plaintext at the application layer. The matching worker receives
plaintext JSON through its run-scoped RPC.

Do not treat the legacy key table as a production key store, add keys to it, or
restore the old crypto function grants. Do not process production sensitive
data until an approved application-level encryption, key-management,
authorization, migration, and recovery design has been implemented and tested.

The proposed controls, data inventory, complete plaintext path, provider
interface, schema additions, staged migration, rotation/recovery requirements,
and security test plan are in
[`ENCRYPTION-ARCHITECTURE.md`](ENCRYPTION-ARCHITECTURE.md). That document is an
architecture proposal only; it does not claim that any of those controls are
implemented.

The more detailed Phase 2A.3.2 field classification, cryptographic profile,
authorization contract, migration/recovery requirements, and acceptance tests
are in [`ENCRYPTION-CONTRACT.md`](ENCRYPTION-CONTRACT.md). They remain
provisional pending accountable owner approval; current plaintext behavior,
RLS limitations, and legacy-key containment described above are unchanged.