# Usando este template com uma IA (Claude, ChatGPT, Cursor, etc.)

Guia prático para quem quer usar o `supabase-multitenant-starter` como base
e delegar o "recheio" do produto (entidades de negócio, regras, UI específica)
para um agente de IA — sem que ela quebre os padrões de segurança e
arquitetura que o template já estabeleceu.

> **Princípio:** o template já entrega toda a camada base (auth, multi-tenant,
> RBAC, RLS, audit, convites). A IA só precisa adicionar o que é específico
> do **seu** domínio, seguindo padrões já estabelecidos. Quanto mais explícito
> você for sobre esses padrões no briefing, menos retrabalho.

---

## Fluxo recomendado

```
┌──────────────────┐    ┌────────────────────┐    ┌──────────────────────┐
│ 1. Bootstrap do  │ →  │ 2. Briefing pra IA │ →  │ 3. Iteração por fatia │
│    novo projeto  │    │    (este doc)      │    │    (1 entidade/vez)  │
└──────────────────┘    └────────────────────┘    └──────────────────────┘
   (você faz)              (você cola e edita)        (IA implementa,
                                                       você revisa+roda)
```

---

## Parte 1 — Bootstrap (você faz isso, não a IA)

Faça o bootstrap **antes** de envolver a IA. Assim ela começa a partir de
um projeto que já roda.

```bash
# 1. Clone o template para uma pasta nova com o nome do seu projeto
git clone https://github.com/tbarbito/supabase-multitenant-starter.git meu-app
cd meu-app

# 2. Bootstrap — renomeia config.toml, package.json, zera CHANGELOG,
#    remove .git e re-inicializa com histórico limpo
bash scripts/init-project.sh meu-app

# 3. Sobe Supabase local + aplica schema + seed
supabase start
supabase db reset

# 4. Roda o exemplo Next.js
cd examples/nextjs
cp .env.example .env.local
# Edite .env.local com a anon key que apareceu no `supabase start`
npm install
npm run dev
```

Confirme que [http://localhost:3000](http://localhost:3000) abre e que
login com `alice@example.com` / `Teste!Senha#2026` funciona antes de
passar para a Parte 2.

> **Windows:** rode os comandos `bash` via Git Bash, WSL ou similar.
> O `init-project.sh` depende de bash.

---

## Parte 2 — Briefing para a IA

Copie o bloco abaixo, preencha a seção `<IDEIA DO SEU PRODUTO>` e cole
inteiro na sua IA (Claude, ChatGPT, Cursor, etc.) no início de uma nova
conversa/sessão.

````markdown
# Contexto do projeto

Estou construindo um SaaS multi-tenant em cima do template open source
**supabase-multitenant-starter** (autor: Tiago Barbieri / @tbarbito, MIT).
O template já entrega TODA a camada base — você NÃO precisa reimplementar
nada disso, apenas USAR os padrões já estabelecidos:

- Auth completo (Supabase Auth + signup/login/recovery, MFA opt-in, OAuth)
- Multi-tenant N:N: tabelas `profiles`, `companies`, `memberships`,
  `invitations`, `audit_log`
- RBAC 4 níveis: `owner` > `admin` > `member` > `viewer` (ENUM `app_role`)
- Row Level Security FORÇADA em todas as tabelas, com helpers SQL prontos
- Custom JWT hook que injeta `memberships` e `active_company_id` em
  `app_metadata`
- Edge Function `invitations` (create/accept/revoke) com token CSPRNG
  256-bit
- Audit log append-only (sem UPDATE/DELETE)
- Exemplo Next.js 15 + React 19 (App Router + SSR via `@supabase/ssr`)
- CI: lint SQL + testes pgTAP + geração de types

## Stack fixa (não trocar)

- PostgreSQL 15 via Supabase
- Edge Functions: Deno + TypeScript
- Frontend: Next.js 15 (App Router) + React 19 + TypeScript
- Auth: Supabase Auth (NÃO usar NextAuth, NÃO usar outro provider)
- Email: Resend (já integrado)
- Testes de banco: pgTAP

## Estrutura do repo

```
supabase/
  migrations/   # SQL versionado — toda mudança de schema vira migration nova
  functions/    # Edge Functions Deno
  tests/        # pgTAP — testes de RLS obrigatórios pra novas tabelas
  seed.sql      # dados de dev (NÃO roda em prod)
  config.toml
examples/nextjs/
  app/          # App Router (auth/, dashboard/, invite/[token]/)
  components/
  lib/supabase/ # client.ts (browser) e server.ts (SSR/RSC)
  middleware.ts # refresh de sessão
docs/           # ARCHITECTURE.md, SECURITY.md, QUICKSTART.md, USING-WITH-AI.md
```

# O QUE EU QUERO QUE VOCÊ FAÇA

<IDEIA DO SEU PRODUTO — descreva aqui o domínio: que entidades existem,
que regras de negócio, fluxos de UI esperados. Exemplo: "É um SaaS de
gestão de clínicas: cada empresa = uma clínica, com pacientes,
atendimentos, prescrições. Roles têm restrições específicas: viewer só
lê pacientes que ele atende; member faz atendimentos; admin gerencia
agenda; owner configura clínica.">

# REGRAS NÃO-NEGOCIÁVEIS ao implementar

## 1. Toda tabela de negócio NOVA segue este molde:

```sql
CREATE TABLE IF NOT EXISTS public.NOME_TABELA (
    id          uuid PRIMARY KEY DEFAULT extensions.gen_random_uuid(),
    company_id  uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
    -- ... colunas do domínio
    created_by  uuid REFERENCES auth.users(id) ON DELETE SET NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.NOME_TABELA ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.NOME_TABELA FORCE  ROW LEVEL SECURITY;

-- Use SEMPRE os helpers já existentes (estão em
-- supabase/migrations/20260514000007_helper_functions.sql):
--   public.is_member_of(company_id)         -> qualquer membership
--   public.has_role_in(company_id, 'role')  -> role mínimo (hierárquico)
--   public.auth_uid()                       -> auth.uid() seguro

CREATE POLICY NOME_TABELA_select ON public.NOME_TABELA
    FOR SELECT TO authenticated
    USING (public.is_member_of(company_id));

CREATE POLICY NOME_TABELA_insert ON public.NOME_TABELA
    FOR INSERT TO authenticated
    WITH CHECK (public.has_role_in(company_id, 'member')
                AND created_by = public.auth_uid());

CREATE POLICY NOME_TABELA_update ON public.NOME_TABELA
    FOR UPDATE TO authenticated
    USING (public.has_role_in(company_id, 'member'));

CREATE POLICY NOME_TABELA_delete ON public.NOME_TABELA
    FOR DELETE TO authenticated
    USING (public.has_role_in(company_id, 'admin'));

-- Trigger de updated_at (helper já existe)
CREATE TRIGGER set_NOME_TABELA_updated_at
    BEFORE UPDATE ON public.NOME_TABELA
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
```

Cada mudança de schema vai em uma migration NOVA:
`supabase migration new add_NOME_TABELA` — NUNCA edite migrations
existentes do template (`20260514*.sql`).

## 2. Para cada tabela nova, adicione testes pgTAP

Em `supabase/tests/rls.test.sql`, no mínimo:
- `viewer` NÃO consegue inserir
- `member` de OUTRA empresa NÃO vê os dados
- `admin` consegue deletar

Use os testes existentes como modelo.

## 3. NUNCA use `SUPABASE_SERVICE_ROLE_KEY` no frontend

Essa chave bypassa toda RLS. Use APENAS em Edge Functions, scripts admin
de backend, ou jobs de manutenção. Se você precisar de uma operação
privilegiada a partir do frontend, crie uma Edge Function.

## 4. Frontend: rotas autenticadas em `examples/nextjs/app/dashboard/`

- Use `lib/supabase/server.ts` em Server Components / Server Actions
- Use `lib/supabase/client.ts` em Client Components
- A empresa ativa do usuário sai de `app_metadata.active_company_id`
  no JWT — NÃO faça query extra pra descobrir isso
- O `middleware.ts` já cuida do refresh de sessão; NÃO desabilite

## 5. Operações que mudam membership passam por Edge Function

Convidar, remover ou trocar role de usuário DEVE passar pela Edge
Function `invitations` (ou nova Edge Function análoga). NUNCA faça
INSERT/UPDATE/DELETE direto em `memberships` a partir do cliente,
mesmo que a RLS permita. Triggers já bloqueiam casos óbvios (último
owner, auto-promoção) mas a regra é: tudo que afeta acesso passa por
server-side controlado.

## 6. Toda ação sensível registra em audit_log

```sql
SELECT public.log_audit(
    p_company_id := <uuid>,
    p_action     := 'create'::audit_action,  -- create/update/delete/role_change/etc
    p_entity     := 'projects',
    p_entity_id  := <uuid>,
    p_metadata   := '{"name": "..."}'::jsonb
);
```

Faça do lado do servidor (Server Action, Edge Function, ou trigger SQL).

## 7. Depois de mudar schema, rode SEMPRE este ciclo:

```bash
supabase db reset                      # reaplica migrations + seed
supabase test db                       # roda pgTAP
cd examples/nextjs && npm run types    # regenera lib/database.types.ts
npm run build                          # garante que tipos batem
```

Se algum desses falhar, conserte antes de seguir.

## 8. NÃO mexer em:

- Migrations existentes `20260514*.sql` (são o release base)
- `supabase/functions/invitations/` (a menos que solicitado)
- Helpers SQL em `migrations/20260514000007_helper_functions.sql`
- Auth Hook em `migrations/20260514000010_auth_hook.sql`

Se precisar de novo helper, crie migration nova
`2026MMDD*_helpers_DOMINIO.sql`.

## 9. Regras de RBAC do domínio: PERGUNTE antes de assumir

Quando uma policy precisar de lógica além de `is_member_of` /
`has_role_in` (ex.: "viewer só vê os registros que ele criou"),
escreva uma function SQL helper — NUNCA inline policy complexa.
E pergunte primeiro qual é a regra correta.

# Ordem de trabalho que eu espero de você

1. Liste as entidades/tabelas do domínio que você vai criar
2. Para cada uma: migration SQL + policies + testes pgTAP
3. UI Next.js correspondente em `app/dashboard/<entidade>/`
4. Audit log nas ações sensíveis
5. Atualizar `docs/ARCHITECTURE.md` (seção do domínio) com as decisões
   de modelagem que você tomou

Trabalhe em **fatias finas** — uma entidade por vez. Espere meu OK
antes de seguir para a próxima.
````

---

## Parte 3 — Como iterar com a IA

### Dê acesso aos arquivos-chave de uma vez

Anexe ou cole o conteúdo destes arquivos no início da conversa para a
IA não ter que adivinhar os padrões:

- [`supabase/migrations/20260514000007_helper_functions.sql`](../supabase/migrations/20260514000007_helper_functions.sql) — helpers SQL disponíveis
- [`supabase/migrations/20260514000008_rls_policies.sql`](../supabase/migrations/20260514000008_rls_policies.sql) — exemplos de policies prontas
- [`supabase/tests/rls.test.sql`](../supabase/tests/rls.test.sql) — formato dos testes pgTAP
- [`docs/ARCHITECTURE.md`](ARCHITECTURE.md) — decisões e o porquê
- [`docs/SECURITY.md`](SECURITY.md) — modelo de ameaças (o que NÃO pode quebrar)
- Uma página do Next.js de referência, ex.:
  [`examples/nextjs/app/dashboard/members/page.tsx`](../examples/nextjs/app/dashboard/members/page.tsx)

### Itere em fatias finas

Não peça "implementa o produto inteiro". Peça uma entidade por vez:

> "Começa só pela entidade `projects` — migration + teste pgTAP + página
> de listagem em `/dashboard/projects`. Espera meu OK antes da próxima."

Para cada fatia, o ciclo é:

1. IA gera migration + policies + teste + UI
2. Você roda `supabase db reset && supabase test db && npm run build`
3. Cola o output (sucesso ou erro) de volta na IA
4. Quando passa, próxima fatia

### Verifique a saúde a cada passo

```bash
supabase test db                       # 15 testes do template + novos
cd examples/nextjs && npm run build    # tipos + build válidos
```

Se quebrou: **NÃO** deixe a IA "consertar tudo de uma vez". Faça ela
explicar a causa primeiro.

### Sinais de alerta — pause e revise quando a IA:

- Editar migrations existentes do template (`20260514*.sql`)
- Adicionar `SUPABASE_SERVICE_ROLE_KEY` ao `examples/nextjs/` ou a um worker; mantenha-a em Edge Functions estritamente limitadas ou em manuten��o administrativa
- Criar policies sem `FORCE ROW LEVEL SECURITY`
- Fazer INSERT/UPDATE/DELETE em `memberships` direto do client
- Pular o `created_by = public.auth_uid()` no `WITH CHECK` de INSERT
- Esquecer o `company_id` em alguma tabela de negócio

Esses são os caminhos comuns para quebrar o modelo de segurança do
template. Se você ver qualquer um, peça pra ela revisar contra
`docs/SECURITY.md`.

---

## Para projetos mais complexos: subagentes

Se sua IA suporta agentes paralelos (Claude Code, Cursor com background
agents), divida assim:

- **Agente "schema"**: cria migration + policies + pgTAP
- **Agente "frontend"**: cria UI Next.js consumindo os tipos gerados
- **Agente "review"**: roda os comandos de validação e reporta

Faça os dois primeiros em paralelo a partir de um contrato (a estrutura
da tabela), depois o terceiro valida.

---

## FAQ

**P: A IA pode rodar `supabase db reset` por mim?**
R: Se ela tem terminal access (Claude Code, Cursor), sim — desde que
você confirme. Caso contrário, ela te dá o comando e você roda.

**P: Devo deixar a IA editar `docs/ARCHITECTURE.md`?**
R: Sim, é onde decisões de modelagem do **seu** domínio devem ficar
documentadas. Mas revise — a IA tende a inflar prosa.

**P: Posso pular o teste pgTAP "só dessa vez"?**
R: Não recomendo. Foi assim que os 5 cenários de ataque catalogados
no CHANGELOG do template foram pegos antes de virarem bug.

**P: A IA quer mudar a stack (trocar Next.js por X, Resend por Y).**
R: Diga não. Se você quer trocar, faça você mesmo num PR dedicado —
não delegue troca de stack pra IA no meio de feature work.
