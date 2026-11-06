# Roadmap para MVP — ZamBase

## Status atual

**P0 (Segurança) — Concluído**
- Worker roles least-privilege (sem acesso direto a tabelas, apenas RPCs escopos por job/run)
- RLS forçado em todas as tabelas de reconciliação + pgTAP (99/99 passando)
- Bucket `reconciliation-imports` privado, upload só sob namespace da empresa/ativa, download via signer com claim token e lease ativo
- Contenção de chaves de criptografia legacy (grants revogados, overloads revogados)
- `audit_log` append-only (sem UPDATE/DELETE para papéis de aplicação)
- Email confirmation funcionando: usuário `moobechikanda20@gmail.com` confirmado, é owner da empresa `5kmvp`
- TypeScript `tsc --noEmit` limpo; Python `py_compile` limpo

**P1 (Funcionalidade core) — Em andamento**
- UI de importação existe (`/dashboard/reconciliation/imports`) com upload de CSV/JSON/JSONL (máx 50 MiB)
- Workers definidos (`services/reconciliation/imports/worker.py`, `services/reconciliation/matching/splink_worker.py`)
- Docker Compose orquestra Next.js + worker-import + worker-match
- End-to-end (upload → claim → import → match → candidatos) ainda não foi executado em ambiente local

**P2 (MVP hardening) — Não iniciado**
- UI de revisão de matches (aprovar/rejeitar candidatos com auditoria)
- Política de retenção de auditoria (UI para aprovar `retention_days`)
- Exportação de relatórios de reconciliação
- Documentação de deploy em produção
- Monitoramento e alertas

---

## Prioridades para MVP (próximos 30 dias)

### Semana 1 — Fechamento do loop de reconciliação

| Item | Descrição | Critério de aceitação |
|------|-----------|----------------------|
| E2E local | Rodar `supabase db reset` + `docker compose up --build`, fazer upload de arquivo, verificar que o worker importa e gera candidatos | Upload aparece como job `completed`, registros fonte criados, candidatos de match gravados |
| UI de match | Página `/dashboard/reconciliation/matches` listando candidatos por tenant com botões aprovar/rejeitar | Ação grava em `reconciliation_match_candidates` com `status` alterado e auditoria em `audit_log` |
| Teste de worker | Executar `python -m unittest discover -s services/reconciliation/tests` (quando existir) | Testes de unidade do worker passam |

### Semana 2 — Auditoria e retenção

| Item | Descrição | Critério de aceitação |
|------|-----------|----------------------|
| UI de retenção | Página admin para definir `retention_days` em `reconciliation_audit_retention_policy` (apenas admin/owner) | Apenas valores aprovados são aceitos; limpeza é no-op sem política aprovada |
| Cron de limpeza | Verificar job pg_cron rodando como `reconciliation_scheduler` | `reconciliation_audit_retention_cleanup()` não deleta quando `retention_days` é NULL |
| Auditoria de revisão | Toda decisão de aprovar/rejeitar match gera entrada em `audit_log` | `actor_user_id`, `company_id`, `action` preenchidos corretamente |

### Semana 3 — Export e documentação

| Item | Descrição | Critério de aceitação |
|------|-----------|----------------------|
| Export | Edge Function ou endpoint para exportar resultados de reconciliação de uma empresa (CSV/JSON) | Somente o tenant ativo vê seus próprios dados (RLS) |
| Deploy docs | README atualizado com variáveis de ambiente, senhas de worker, e passos para produção | Nova instância pode ser provisionada seguindo o README |
| Hardening checklist | Revisar `docs/SECURITY.md` checklist de produção | Todos os itens críticos marcados ou com justificativa |

---

## Métricas de definição de "MVP pronto"

- [ ] Usuário se cadastra, confirma email, é associado a uma empresa
- [ ] Admin upload de arquivo de importação → job criado → worker importa registros
- [ ] Worker de matching gera candidatos dentro do mesmo tenant
- [ ] Usuário revisa e aprova/rejeita matches com auditoria
- [ ] Nenhum dado vaza entre tenants (pgTAP RLS passa)
- [ ] Workers não usam `service_role` nem `postgres` (apenas logins dedicados)
- [ ] `supabase test db` passa 100%
- [ ] `tsc --noEmit` e `py_compile` passam

---

## Fora do escopo do MVP (P3+)

- Criptografia de campo em nível de aplicação (atualmente apenas contenção de chaves legacy)
- Gerenciamento de chaves externo (KMS)
- MFA obrigatório (recomendado, não bloqueador)
- OAuth social (Google/GitHub desabilitados no `config.toml`)
- Multi-região / read replicas
