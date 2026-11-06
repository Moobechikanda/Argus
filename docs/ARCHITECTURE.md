# Arquitetura

Este documento explica **as decisões** por trás do template. Para uso prático, veja [`QUICKSTART.md`](QUICKSTART.md).

---

## 1. Modelo de dados

```
┌─────────────────┐
│  auth.users     │ (gerenciada pelo Supabase Auth — não modificamos)
└────────┬────────┘
         │ 1:1
┌────────▼────────┐
│  profiles       │ Dados públicos do usuário
└────────┬────────┘
         │ N:N (via memberships)
┌────────▼────────┐         ┌─────────────────┐
│  memberships    │◄────────┤   companies     │ Tenant root
│  (role)         │         └────────┬────────┘
└─────────────────┘                  │
                                     │ 1:N
                            ┌────────▼────────┐
                            │  invitations    │
                            │  audit_log      │
                            └─────────────────┘
```

### Por que N:N (memberships)?

A escolha mais importante do template. Alternativas:

| Modelo | Prós | Contras |
|---|---|---|
| 1:1 (`profile.company_id`) | Simples | Usuário só em 1 empresa — limitação séria |
| Empresa como dono do user | Modelo "empresa-first" | Não permite migração entre empresas |
| **N:N via memberships** | Flexível, padrão Slack/Notion/Linear | +1 tabela, RLS um pouco mais complexa |

**Escolhemos N:N** porque:
- Um consultor que atende várias empresas precisa de logins separados se for 1:1 → ruim.
- Quando você decide migrar de 1:1 para N:N depois, é refactor caro (migration de dados + reescrita de policies).
- Slack, Notion, Linear, Vercel — todos usam N:N. É o padrão de mercado.

### Por que `profiles` separada de `auth.users`?

- `auth.users` é gerenciada pelo Supabase Auth (GoTrue). Adicionar colunas pode quebrar com atualizações futuras.
- `profiles` permite RLS-controlled access aos dados públicos sem dar permissões em `auth.users`.
- Trigger `handle_new_user` mantém as duas em sincronia.

### Por que ENUMs em vez de tabela `roles`?

- Lista pequena e estável (4 valores).
- ENUMs são indexáveis e mais performáticos que JOIN com tabela.
- Trade-off: adicionar novo role exige migration. Mas isso é uma decisão estratégica, não corriqueira.

---

## 2. Custom JWT Claims (Auth Hook)

### O problema

Toda RLS policy precisa do role do usuário na empresa. Sem otimização:

```sql
-- Cada query faz 1 lookup adicional em memberships
CREATE POLICY ... USING (
    EXISTS (SELECT 1 FROM memberships
            WHERE user_id = auth.uid() AND company_id = ...)
);
```

Para uma query que toca 5 tabelas, isso é 5 lookups extras — mesmo com cache do planner.

### A solução

`custom_access_token_hook` injeta os memberships no JWT em **um único momento** (login/refresh). RLS lê do JWT em vez do banco:

```sql
-- Hipotético: ler direto do JWT
SELECT (auth.jwt() -> 'app_metadata' -> 'memberships') ...
```

Na prática, mantemos as policies usando helper functions (`has_role_in()`) para legibilidade, mas elas têm `STABLE` que permite o planner cachear o resultado dentro da query.

### Por que `app_metadata` e não `user_metadata`?

| Campo | Quem edita | Uso |
|---|---|---|
| `user_metadata` | Cliente (qualquer authenticated user) | Preferências do usuário |
| `app_metadata` | Apenas backend / service_role | Autorização, roles, flags |

Usar `user_metadata` para roles = vulnerabilidade crítica (usuário se promove a admin via SDK).

---

## 3. Sistema de convites

### Fluxo

```
1. Admin → POST /invitations
           { company_id, email, role }

2. Edge Function:
   - Gera token (32 bytes via Web Crypto)
   - Calcula hash SHA-256
   - Insere em invitations (apenas hash no DB)
   - Envia email com URL contendo o token em claro

3. Destinatário → clica no link → /invite/<token>

4. Frontend (se não autenticado): redireciona para login/signup

5. Frontend (autenticado) → POST /invitations/accept
                            { token }

6. Edge Function:
   - Recalcula hash do token recebido
   - Busca invitation por token_hash (sem revelar se existe)
   - Valida: status=pending, não expirado, email confere
   - Cria membership + marca como accepted
```

### Por que armazenar apenas hash?

- **Dump do banco não vaza tokens válidos.** Mesmo que um atacante exporte a tabela `invitations`, ele tem hashes inutilizáveis.
- **Comparação por hash é tempo-constante.** Postgres `=` em strings de mesmo tamanho não tem timing leak relevante (e a SHA-256 vai pro mesmo tamanho).

### Por que `gen_random_bytes(32)` (256 bits)?

- 256 bits de entropia = computacionalmente inviável de adivinhar (mesmo com bilhões de tentativas/s).
- Hex-encoded (64 chars) — URL-safe sem precisar URL-encoding.
- Padrão usado por Github, Gitlab, Vercel para tokens de convite/API.

---

## 4. Audit log append-only

### Por que append-only?

Auditoria adulterada perde valor jurídico/forense. Garantimos:
- **Sem policy de UPDATE** → ninguém edita registros.
- **Sem policy de DELETE** → ninguém apaga.
- Mesmo service_role rodando código da app não consegue (a não ser que use `BYPASS RLS` explícito).

### Retenção

Para tabelas pequenas (~1M linhas), não é problema. Para crescer:

```sql
ALTER TABLE public.audit_log PARTITION BY RANGE (created_at);
```

+ partições mensais via `pg_partman`. TRUNCATE de partição antiga é rápido e não fere o append-only (não é DELETE).

---

## 5. Soft delete

Aplicado em `profiles` e `companies`. **Não** aplicado em `memberships` (saída é registrada no audit_log).

### Por quê?

- **Recuperação acidental**: usuário deletou empresa por engano.
- **LGPD com hard delete via anonimização**: troca dados pessoais por placeholders, mantém integridade referencial.
- **Análise temporal**: "quantas empresas foram deletadas no Q1?"

### Como funciona

- Coluna `deleted_at timestamptz`.
- Index parcial `WHERE deleted_at IS NULL` — queries de "registros ativos" são rápidas.
- RLS adiciona `AND deleted_at IS NULL` em policies de SELECT.
- Para "deletar de verdade" (LGPD), use service_role + função admin.

---

## 6. Convenções

### Nomes
- Tabelas: snake_case, plural (`profiles`, `memberships`)
- Funções: snake_case, verbo (`is_member_of`, `has_role_in`, `log_audit`)
- Triggers: tabela_acao (`profiles_set_updated_at`, `on_auth_user_created`)
- Index: tabela_coluna_tipo (`memberships_user_id_idx`)

### Migrations
- Nome: `YYYYMMDDHHMMSS_descricao.sql` (Supabase CLI gera com `--name`)
- Idempotentes: `CREATE ... IF NOT EXISTS`, `DROP POLICY IF EXISTS`
- Comentários explicando POR QUÊ, não apenas O QUÊ

### Funções
- Sempre `LANGUAGE sql` ou `plpgsql` explícito
- `STABLE`/`IMMUTABLE` quando aplicável (planner cacheia)
- `SECURITY DEFINER` + `SET search_path = ''` é obrigatório para qualquer função que bypassa RLS
- `REVOKE EXECUTE FROM PUBLIC` + `GRANT` explícito ao role correto

---

## 7. Decisões deliberadas (e não implementadas)

| Decisão | Por que NÃO incluímos |
|---|---|
| Billing/Stripe integration | Específico demais — cada produto tem regras diferentes |
| Email templates customizados | Resend basta para 90% dos casos; trocar é fácil |
| Frontend genérico (não Next.js) | Next.js é o stack mais usado com Supabase; outros são portáveis |
| Notificações in-app | Escopo aumenta muito; Realtime cobre o caso básico |
| Workspace > Project (Notion-like) | Diferentes produtos = diferentes hierarquias — adicione conforme precisar |

---

## 8. Extensões recomendadas

Quando começar a usar para um produto real, considere:

- **`pg_cron`**: jobs agendados dentro do Postgres (limpar convites expirados, etc).
- **`pgvector`**: se for adicionar features de IA.
- Criptografia de aplicação com KMS externo: planejada, mas ainda não implementada; veja [`ENCRYPTION-ARCHITECTURE.md`](ENCRYPTION-ARCHITECTURE.md).
- **`pg_stat_statements`**: identificar queries lentas em produção.

---

## 9. Módulo de reconciliação (ZamBase)

### 9.1 Visão geral

O módulo de reconciliação é uma camada de negócio sobre o template multi-tenant.
O código atual contém importação de arquivos, geração de candidatos com Splink
e telas para revisão e entidades. O fluxo E2E não foi validado e as operações
de revisão, discrepância e exportação ainda têm limitações descritas abaixo.

### 9.2 Modelo de dados (tabelas novas)

Todas as tabelas carregam `company_id` como FK para `public.companies` (tenant
root), possuem RLS `ENABLE` + `FORCED` e policies por comando usando
`public.is_member_of()` / `public.has_role_in()`. Algumas operações gravam em
`public.audit_log` (append-only para papéis de aplicação); não há auditoria de
leitura/decriptação e nem todo fluxo grava uma decisão em
`reconciliation_reviewer_decisions`.

| Tabela | Propósito |
|--------|-----------|
| `reconciliation_data_sources` | Datasets registrados por tenant |
| `reconciliation_import_jobs` | Uma execução de importação (arquivo → staging) |
| `reconciliation_source_records` | Registros fonte imutáveis (sem UPDATE/DELETE) |
| `reconciliation_entities` | Registros ouro (clusters resolvidos) |
| `reconciliation_identifiers` | Cross-reference source_record ↔ entity |
| `reconciliation_reconciliation_runs` | Execução do motor de matching |
| `reconciliation_match_candidates` | Pares candidatos aguardando revisão |
| `reconciliation_discrepancies` | Conflitos de campo dentro de uma entidade |
| `reconciliation_evidence` | Evidências que sustentam decisões |
| `reconciliation_reviewer_decisions` | Decisões humanas sobre matches/correções |

### 9.3 Imutabilidade dos registros fonte

`reconciliation_source_records` não tem policies de UPDATE/DELETE e um trigger
(`guard_source_record_immutable`) rejeita qualquer tentativa. A imutabilidade
também significa que a migração de criptografia não poderá simplesmente
atualizar essas linhas: o desenho proposto usa armazenamento ciphertext
paralelo, preservando os dados originais durante backfill e rollback. O código
atual não gera automaticamente todas as discrepâncias nem mantém um registro
completo em `reconciliation_reviewer_decisions`.

### 9.4 RBAC aplicado à reconciliação

- A RLS das tabelas de reconciliação normalmente permite leitura de dados aos
  membros da empresa e restringe escrita conforme a tabela e o role.
- A UI e as Server Actions impõem restrições adicionais para revisão, mas essas
  verificações não substituem autorização no banco. Por exemplo, a policy de
  UPDATE de candidatos permite `member`; ela não é uma fronteira de autorização
  equivalente à checagem `admin`/`owner` da interface.
- Consulte as policies efetivas em `20261029000001_reconciliation_module.sql`;
  não presuma que uma regra exibida pela UI esteja também imposta por RLS.

### 9.5 Integração com Splink (como dependência, não como cópia)

Splink é uma dependência Python executada pelo worker de matching. Os workers
usam logins PostgreSQL separados e RPCs `SECURITY DEFINER` limitadas por claim
e lease; não recebem `service_role` nem acesso direto às tabelas. A fronteira
continua sendo um serviço centralizado confiável que pode processar todos os
tenants ao longo do tempo.

O worker obtém `raw_data`/`normalized_data` plaintext pela RPC
`reconciliation_matching_source_records`, cria um DataFrame e passa os campos
para o Splink. As regras atualmente aceitas são igualdade exata em campos
selecionados; os candidatos escritos contêm score e `comparison_details`
vazio. O worker não cria entidades ou discrepâncias: a criação de entidade
ocorre na Server Action de aceite. O código atual não é um pipeline fuzzy de
comparadores avançados nem uma implementação de survivorship completa.

Não há cópia do fonte do Splink no repositório; a dependência é gerenciada via
`pip install -r requirements.txt` com versão fixa.

### 9.6 Gate de revisão humana

Os candidatos ficam pendentes e a UI fornece ações de aceitar/rejeitar para
`admin`/`owner`. Ao aceitar, a Server Action lê os registros fonte, forma um
`canonical_data` simples e tenta criar/vincular uma entidade. A ação atual não
insere uma linha em `reconciliation_reviewer_decisions`; portanto, não se deve
descrever essa tabela como um histórico completo de cada revisão. A tela de
discrepâncias lê `competing_value`, mas a ação de resolução atual só atualiza o
status e registra metadados; o valor manual não é persistido como valor
canônico. O export monta CSV contendo `canonical_data` e dados fonte, tenta
armazená-lo no bucket `reconciliation-exports` e pode retornar o CSV inline.

### 9.7 Convenções de migration

- Arquivo novo: `YYYYMMDDHHMMSS_descricao.sql` (não editar migrations
  existentes `20260514*.sql`).
- Idempotente: `CREATE ... IF NOT EXISTS`, `DROP POLICY IF EXISTS`.
- `ALTER TYPE ... ADD VALUE` para ENUMs (não reversível dentro de transação;
  documentado no arquivo).
- Comentários em PT-BR explicando POR QUÊ.

---

## 10. Limites atuais de proteção de dados

As colunas criptografadas e funções `pgsodium` introduzidas em
`20261030000002_reconciliation_security_ops.sql` são um protótipo legado. A
migração `20261101000003_contain_encryption_keys_and_audit.sql` removeu
policies/grants de aplicação e revogou as funções antigas; a migração
`20261101000007_revoke_all_legacy_crypto_overloads.sql` também revoga
sobrecargas legadas. O worker e as telas não usam essas colunas ou funções.
`raw_data`, `normalized_data`, `canonical_data` e valores relacionados
continuam plaintext no banco, no Storage de importação, em memória nos workers
e em fluxos de revisão/exportação.

RLS fornece isolamento por tenant, não criptografia nem autorização por campo:
em particular, os leitores autenticados com membership podem ler registros
fonte em plaintext. `connection_config` é JSON arbitrário e é exibido na tela
de data sources; não deve conter credenciais. O uso de Storage privado e de
logins de worker dedicados reduz a superfície de exposição, mas não altera o
formato de armazenamento dos dados.

O desenho de classificação, envelope encryption, KMS, migração segura,
autorização de decrypt, matching e recuperação está em
[`ENCRYPTION-ARCHITECTURE.md`](ENCRYPTION-ARCHITECTURE.md). Tudo ali é uma
proposta para Phase 2A.3, não uma capacidade já entregue.

O contrato de classificação e criptografia da Phase 2A.3.2, incluindo
requisitos verificáveis de interoperabilidade, autorização, migração e
recuperação, está em [`ENCRYPTION-CONTRACT.md`](ENCRYPTION-CONTRACT.md). O
documento é uma proposta pendente de aprovação dos responsáveis; a criptografia
de aplicação continua não implementada e a Phase 2A.3.3 não está liberada para
implementação.
