# ZamBase — Plataforma multi-tenant de reconciliação de dados

> Aplicação MVP para importar conjuntos de dados por empresa, identificar possíveis duplicatas e apoiar revisão humana. Construída sobre uma base multi-tenant Supabase; ainda não é um serviço pronto para produção com dados sensíveis.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Supabase](https://img.shields.io/badge/Supabase-%23000000.svg?logo=supabase&logoColor=white)](https://supabase.com)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-15-blue.svg)](https://postgresql.org)

---

## O que existe hoje

| Recurso | Status |
|---|---|
| Auth (signup/login/recovery; confirmação de email) | ✅ |
| Multi-tenant **N:N** (um usuário em várias empresas com papéis diferentes) | ✅ |
| RBAC com 4 níveis: `owner`, `admin`, `member`, `viewer` | ✅ |
| **Row Level Security** em tabelas do core e reconciliação, com testes pgTAP | ✅ |
| Convites por email com token criptográfico de 1 uso + expiração | ✅ |
| **Audit log** com grants de mutação revogados para papéis de aplicação | ✅ |
| Soft delete em profiles e companies | ✅ |
| **Custom JWT claims** (memberships e empresa ativa no token) | ✅ |
| Proteções: último owner não pode ser removido, admin não auto-promove | ✅ |
| Importação privada de CSV, JSON e JSONL (até 50 MiB) | ✅ no código; fluxo E2E ainda não verificado |
| Workers Python separados para importação e matching com Splink | ✅ no código; execução E2E ainda não verificada |
| Telas de revisão de matches, entidades, discrepâncias e exportação | ⚠️ MVP; fluxos de persistência/revisão ainda incompletos |
| Criptografia de campos e gerenciamento externo de chaves (KMS) | ❌ não implementados |

O estado atual, incluindo os limites conhecidos de segurança e funcionalidade,
está documentado em [`docs/ENCRYPTION-ARCHITECTURE.md`](docs/ENCRYPTION-ARCHITECTURE.md).

---

## Stack

- **Banco**: PostgreSQL 15 (via Supabase)
- **Auth**: Supabase Auth (GoTrue)
- **Edge Functions**: Deno (TypeScript)
- **Frontend**: Next.js 15 + React 19 + App Router
- **Workers**: Python 3.11, psycopg, Splink 3.7.0
- **Orquestração local**: Docker Compose
- **Testes**: pgTAP e unittest

---

## Começo rápido local

### Pré-requisitos

- [Docker](https://docs.docker.com/get-docker/) (para o Supabase rodar local)
- [Supabase CLI](https://supabase.com/docs/guides/cli) (`npm i -g supabase` ou via brew)
- [Node.js 20+](https://nodejs.org/)

### Passos

```bash
# 1. Inicie os serviços locais do Supabase
supabase start

# 2. Em uma instalação local descartável, aplique migrations e seed
supabase db reset

# 3. Configure as credenciais separadas dos workers conforme docs/WORKERS.md
#    e preencha as variáveis locais em .env (não faça commit desse arquivo).

# 4. Inicie o frontend e os workers
docker compose up --build
```

Abra `http://localhost:3000`. Os workers exigem senhas locais próprias para os
logins Postgres dedicados; não use `postgres`, `service_role` ou uma chave
`service_role` nos workers. Consulte [`docs/WORKERS.md`](docs/WORKERS.md) para
provisionamento local, Storage e variáveis necessárias.

O fluxo disponível inclui cadastro de data source, upload, importação,
execução de matching, revisão de pares e telas de entidades/discrepâncias.
Algumas operações de revisão e exportação ainda são protótipos e o ciclo
completo não foi validado ponta a ponta.

---

## Estado de produção

**Não use o estado atual para processar dados de produção ou dados pessoais
sensíveis.** Os valores de `raw_data`, `normalized_data`, `canonical_data` e
outros campos de reconciliação são armazenados e lidos em plaintext. A tabela e
as funções de criptografia antigas são apenas um protótipo contido; não existe
integração KMS nem um fluxo de criptografia de aplicação. A implantação ainda
precisa de uma arquitetura de criptografia aprovada, testes E2E, revisão dos
fluxos de autorização, monitoramento e procedimentos de backup/recuperação.
Veja [`docs/SECURITY.md`](docs/SECURITY.md) e
[`docs/ENCRYPTION-ARCHITECTURE.md`](docs/ENCRYPTION-ARCHITECTURE.md).

---

## Estrutura do projeto

```
.
├── supabase/
│   ├── migrations/        # SQL versionado (PostgreSQL puro)
│   ├── functions/         # Edge Functions (Deno + TypeScript)
│   ├── tests/             # Testes pgTAP de RLS
│   ├── seed.sql           # Dados de exemplo p/ dev
│   └── config.toml        # Config local do Supabase CLI
├── services/
│   └── reconciliation/    # Workers Python de importação e matching
├── examples/
│   └── nextjs/            # Frontend Next.js (App Router + SSR)
├── docs/
│   ├── ARCHITECTURE.md    # Arquitetura atual e modelo de dados
│   ├── SECURITY.md        # Limites de segurança e hardening
│   ├── ENCRYPTION-ARCHITECTURE.md # Avaliação e proposta da Phase 2A.3
│   ├── QUICKSTART.md      # Guia de início
│   └── WORKERS.md         # Provisionamento e execução local dos workers
├── .github/workflows/     # CI: lint + tests + types
├── .env.example
├── LICENSE                # MIT
└── README.md
```

---

## Documentação

- 📐 [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — modelo de dados e decisões
- 🔐 [`docs/SECURITY.md`](docs/SECURITY.md) — modelo de ameaças, RLS, hardening
- 🚀 [`docs/QUICKSTART.md`](docs/QUICKSTART.md) — tutorial completo passo a passo
- 🔑 [`docs/ENCRYPTION-ARCHITECTURE.md`](docs/ENCRYPTION-ARCHITECTURE.md) — avaliação atual e proposta de criptografia/KMS
- ⚙️ [`docs/WORKERS.md`](docs/WORKERS.md) — credenciais, Storage e workers locais
- 🤖 [`docs/USING-WITH-AI.md`](docs/USING-WITH-AI.md) — como usar o template com Claude/ChatGPT/Cursor sem quebrar os padrões

---

## ⚠️ Avisos críticos de segurança

1. **NUNCA exponha `SUPABASE_SERVICE_ROLE_KEY` no frontend ou workers.** Esta chave bypassa RLS. Use-a apenas em Edge Functions de escopo limitado e manutencao administrativa; workers usam logins de banco separados.
2. **Email confirmation está ativada por padrão** — não desligue em produção.
3. **Política de senha**: mínimo 12 caracteres com maiúscula, minúscula, número e símbolo. Configurável em `supabase/config.toml`.
4. **Auth Hook (custom JWT claims) precisa estar habilitado** no painel Supabase em produção, senão `app_metadata.memberships` ficará vazio.
5. **Rate limit**: o Supabase já protege endpoints de auth, mas considere adicionar limites por IP nas suas Edge Functions.

Veja [`docs/SECURITY.md`](docs/SECURITY.md) para o checklist completo.

---

## Contribuindo

PRs são bem-vindos. Antes de abrir:

1. SQL/pgTAP: `supabase test db`
2. Python: `python -m unittest discover -s services/reconciliation/tests`
3. Frontend: `cd examples/nextjs && npx tsc --noEmit` e `npm run build`
4. Atualize a documentação se mudar comportamento.

No estado atual da árvore, a descoberta completa de testes Python falha ao
importar `services/reconciliation/tests/test_blocking.py` (usa uma API interna
de Splink ausente na versão declarada). Os demais testes unitários Python
passam; o teste de integração com Storage é opcional e exige Supabase local.
`npm run lint` ainda não está configurado e abre o prompt inicial do Next.js.

---

## Licença

MIT — veja [LICENSE](LICENSE).

---

## Créditos

Criado por [Tiago Barbieri (Barbito)](https://github.com/tbarbito).

Inspirações: Supabase docs, [Supabase Auth Helpers](https://github.com/supabase/auth-helpers), padrões de multi-tenancy de Slack, Linear e Vercel.
