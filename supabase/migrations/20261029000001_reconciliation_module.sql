-- =============================================================================
-- 20261029000001 — Módulo de reconciliação de dados (ZamBase)
-- =============================================================================
-- Objetivo: adicionar as tabelas base do módulo de reconciliação, reutilizando
-- os padrões já estabelecidos pelo template (multi-tenant N:N, RBAC hierárquico,
-- RLS forçada, helpers SECURITY DEFINER, audit_log append-only).
--
-- Todas as novas tabelas carregam company_id como FK para public.companies e
-- possuem RLS habilitada + FORCED, com policies separadas por comando usando
-- public.is_member_of() / public.has_role_in().
--
-- Fonte de dados de origem é preservada: reconciliation_source_records não tem
-- policies de UPDATE/DELETE (imutável). Correções passam por discrepancies +
-- reviewer_decisions + novas entidades.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- ENUMs de domínio da reconciliação
-- -----------------------------------------------------------------------------

-- Status de um job de importação (arquivo -> registros fonte).
DO $$ BEGIN
    CREATE TYPE public.reconciliation_import_status AS ENUM (
        'pending',   -- job criado, ainda não processado
        'running',   -- processamento em andamento
        'completed', -- processado com sucesso
        'failed',    -- falhou durante o processamento
        'cancelled'  -- cancelado pelo usuário
    );
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

-- Status de uma entidade resolvida (registro ouro / golden record).
DO $$ BEGIN
    CREATE TYPE public.reconciliation_entity_status AS ENUM (
        'candidate', -- proposta, aguardando revisão humana
        'confirmed', -- confirmada por revisor
        'rejected',  -- rejeitada pelo revisor
        'merged'     -- fundida em outra entidade
    );
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

-- Status de um par candidato a match.
DO $$ BEGIN
    CREATE TYPE public.reconciliation_match_status AS ENUM (
        'pending',   -- aguardando decisão do revisor
        'accepted',  -- revisor aceitou o match
        'rejected',  -- revisor rejeitou o match
        'escalated'  -- encaminhado para revisão de nível superior
    );
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

-- Resolução de uma discrepância de campo dentro de uma entidade.
DO $$ BEGIN
    CREATE TYPE public.reconciliation_discrepancy_resolution AS ENUM (
        'unresolved', -- ainda não resolvida
        'winner_source', -- valor de um registro fonte escolhido como vencedor
        'manual'    -- valor corrigido manualmente pelo revisor
    );
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

-- Tipo de decisão do revisor.
DO $$ BEGIN
    CREATE TYPE public.reconciliation_decision AS ENUM (
        'accept_match',  -- aceitar par candidato como match
        'reject_match',  -- rejeitar par candidato
        'merge_entities',-- fundir duas entidades
        'split_entity',  -- separar uma entidade em duas
        'correct_field'  -- corrigir valor de um campo
    );
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

-- Estende o ENUM existente public.audit_action com ações de reconciliação.
-- NOTA: ALTER TYPE ... ADD VALUE não é reversível dentro de uma transação e
-- não pode ser removido sem recriar objetos dependentes. Documentado aqui.
DO $$ BEGIN
    ALTER TYPE public.audit_action ADD VALUE 'data_source.created';
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
    ALTER TYPE public.audit_action ADD VALUE 'data_source.updated';
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
    ALTER TYPE public.audit_action ADD VALUE 'data_source.deleted';
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
    ALTER TYPE public.audit_action ADD VALUE 'import_job.started';
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
    ALTER TYPE public.audit_action ADD VALUE 'import_job.completed';
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
    ALTER TYPE public.audit_action ADD VALUE 'import_job.failed';
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
    ALTER TYPE public.audit_action ADD VALUE 'reconciliation_run.started';
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
    ALTER TYPE public.audit_action ADD VALUE 'reconciliation_run.completed';
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
    ALTER TYPE public.audit_action ADD VALUE 'reconciliation_run.failed';
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
    ALTER TYPE public.audit_action ADD VALUE 'entity.created';
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
    ALTER TYPE public.audit_action ADD VALUE 'entity.confirmed';
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
    ALTER TYPE public.audit_action ADD VALUE 'entity.rejected';
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
    ALTER TYPE public.audit_action ADD VALUE 'entity.merged';
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
    ALTER TYPE public.audit_action ADD VALUE 'match.accepted';
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
    ALTER TYPE public.audit_action ADD VALUE 'match.rejected';
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
    ALTER TYPE public.audit_action ADD VALUE 'discrepancy.resolved';
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
    ALTER TYPE public.audit_action ADD VALUE 'reviewer.decision';
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- -----------------------------------------------------------------------------
-- 1. reconciliation_data_sources — datasets registrados por tenant
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.reconciliation_data_sources (
    id                  uuid PRIMARY KEY DEFAULT extensions.gen_random_uuid(),
    company_id          uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
    name                text NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 200),
    description         text,
    source_type         text NOT NULL DEFAULT 'file' -- file, database, api, etc.
                      CHECK (source_type IN ('file','database','api')),
    connection_config   jsonb NOT NULL DEFAULT '{}'::jsonb, -- caminho do arquivo, credenciais, etc.
    created_by          uuid REFERENCES auth.users(id) ON DELETE SET NULL,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    deleted_at          timestamptz -- soft delete
);

CREATE INDEX IF NOT EXISTS reconciliation_data_sources_company_idx
    ON public.reconciliation_data_sources (company_id)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS reconciliation_data_sources_created_by_idx
    ON public.reconciliation_data_sources (created_by);

COMMENT ON TABLE public.reconciliation_data_sources IS
    'Dataset de origem cadastrado por um tenant. Reutiliza companies como tenant root.';

-- -----------------------------------------------------------------------------
-- 2. reconciliation_import_jobs — uma execução de importação (arquivo -> staging)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.reconciliation_import_jobs (
    id                  uuid PRIMARY KEY DEFAULT extensions.gen_random_uuid(),
    company_id          uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
    data_source_id      uuid REFERENCES public.reconciliation_data_sources(id) ON DELETE SET NULL,
    status              public.reconciliation_import_status NOT NULL DEFAULT 'pending',
    file_ref            text NOT NULL, -- referência ao arquivo (Storage ou caminho temporário)
    row_count           integer DEFAULT 0,
    error_count         integer DEFAULT 0,
    error               text,
    started_at          timestamptz,
    completed_at        timestamptz,
    created_by          uuid REFERENCES auth.users(id) ON DELETE SET NULL,
    created_at          timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS reconciliation_import_jobs_company_idx
    ON public.reconciliation_import_jobs (company_id, status);
CREATE INDEX IF NOT EXISTS reconciliation_import_jobs_data_source_idx
    ON public.reconciliation_import_jobs (data_source_id);

COMMENT ON TABLE public.reconciliation_import_jobs IS
    'Uma execução de importação. Um job produz muitos registros fonte imutáveis.';

-- -----------------------------------------------------------------------------
-- 3. reconciliation_source_records — registros fonte imutáveis (nunca UPDATE/DELETE)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.reconciliation_source_records (
    id                  uuid PRIMARY KEY DEFAULT extensions.gen_random_uuid(),
    import_job_id       uuid NOT NULL REFERENCES public.reconciliation_import_jobs(id) ON DELETE CASCADE,
    company_id          uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
    source_record_id    text NOT NULL, -- chave natural do registro na origem
    raw_data            jsonb NOT NULL DEFAULT '{}'::jsonb, -- dados brutos preservados exatamente
    normalized_data     jsonb NOT NULL DEFAULT '{}'::jsonb, -- dados após normalização (para o Splink)
    row_hash            text NOT NULL, -- hash do conteúdo para idempotência/dedup
    created_at          timestamptz NOT NULL DEFAULT now()
);

-- Idempotência: mesmo source_record_id + row_hash dentro de um job não duplica.
CREATE UNIQUE INDEX IF NOT EXISTS reconciliation_source_records_unique_per_job
    ON public.reconciliation_source_records (import_job_id, source_record_id, row_hash);

CREATE INDEX IF NOT EXISTS reconciliation_source_records_company_idx
    ON public.reconciliation_source_records (company_id);
CREATE INDEX IF NOT EXISTS reconciliation_source_records_job_idx
    ON public.reconciliation_source_records (import_job_id);

COMMENT ON TABLE public.reconciliation_source_records IS
    'Registros fonte imutáveis. Sem policies de UPDATE/DELETE: correções geram novas entidades, nunca alteram a origem.';
COMMENT ON COLUMN public.reconciliation_source_records.row_hash IS
    'Hash determinístico do conteúdo da linha. Usado para dedup e detecção de re-importação.';

-- -----------------------------------------------------------------------------
-- 4. reconciliation_entities — registros ouro (clusters resolvidos)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.reconciliation_entities (
    id                  uuid PRIMARY KEY DEFAULT extensions.gen_random_uuid(),
    company_id          uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
    canonical_data      jsonb NOT NULL DEFAULT '{}'::jsonb, -- valores sobreviventes (survivorship)
    survivorship_rule   text NOT NULL DEFAULT 'latest_wins',
    record_count        integer NOT NULL DEFAULT 0,
    status              public.reconciliation_entity_status NOT NULL DEFAULT 'candidate',
    created_by          uuid REFERENCES auth.users(id) ON DELETE SET NULL,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    deleted_at          timestamptz -- soft delete
);

CREATE INDEX IF NOT EXISTS reconciliation_entities_company_idx
    ON public.reconciliation_entities (company_id)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS reconciliation_entities_status_idx
    ON public.reconciliation_entities (company_id, status);

COMMENT ON TABLE public.reconciliation_entities IS
    'Registro ouro (golden record) resultante de um cluster de registros fonte.';

-- -----------------------------------------------------------------------------
-- 5. reconciliation_identifiers — cross-reference source_record <-> entity
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.reconciliation_identifiers (
    entity_id           uuid NOT NULL REFERENCES public.reconciliation_entities(id) ON DELETE CASCADE,
    source_record_id    uuid NOT NULL REFERENCES public.reconciliation_source_records(id) ON DELETE CASCADE,
    company_id          uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
    confidence          double precision NOT NULL DEFAULT 1.0,
    created_at          timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (entity_id, source_record_id)
);

CREATE INDEX IF NOT EXISTS reconciliation_identifiers_source_idx
    ON public.reconciliation_identifiers (source_record_id);

COMMENT ON TABLE public.reconciliation_identifiers IS
    'Mapeamento muitos-para-muitos entre entidades e registros fonte, com confiança.';

-- -----------------------------------------------------------------------------
-- 6. reconciliation_reconciliation_runs — execução do motor de matching
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.reconciliation_reconciliation_runs (
    id                  uuid PRIMARY KEY DEFAULT extensions.gen_random_uuid(),
    company_id          uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
    status              text NOT NULL DEFAULT 'queued', -- queued, running, completed, failed
    blocking_rules      jsonb NOT NULL DEFAULT '[]'::jsonb, -- regras de bloqueio usadas pelo Splink
    comparison_config   jsonb NOT NULL DEFAULT '{}'::jsonb, -- colunas comparadas e similaridades
    record_pairs_compared integer DEFAULT 0,
    matches_found       integer DEFAULT 0,
    created_by          uuid REFERENCES auth.users(id) ON DELETE SET NULL,
    created_at          timestamptz NOT NULL DEFAULT now(),
    started_at          timestamptz,
    completed_at        timestamptz,
    error               text
);

CREATE INDEX IF NOT EXISTS reconciliation_reconciliation_runs_company_idx
    ON public.reconciliation_reconciliation_runs (company_id, status);

COMMENT ON TABLE public.reconciliation_reconciliation_runs IS
    'Execução do motor de reconciliação (Splink). Um run gera candidatos e entidades.';

-- -----------------------------------------------------------------------------
-- 7. reconciliation_match_candidates — pares candidatos aguardando revisão
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.reconciliation_match_candidates (
    id                  uuid PRIMARY KEY DEFAULT extensions.gen_random_uuid(),
    company_id          uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
    record_a_id         uuid NOT NULL REFERENCES public.reconciliation_source_records(id) ON DELETE CASCADE,
    record_b_id         uuid NOT NULL REFERENCES public.reconciliation_source_records(id) ON DELETE CASCADE,
    entity_id           uuid REFERENCES public.reconciliation_entities(id) ON DELETE SET NULL,
    match_score         double precision NOT NULL,
    comparison_details  jsonb NOT NULL DEFAULT '{}'::jsonb, -- detalhes por campo (Splink)
    status              public.reconciliation_match_status NOT NULL DEFAULT 'pending',
    reviewer_id         uuid REFERENCES auth.users(id) ON DELETE SET NULL,
    reviewed_at         timestamptz,
    created_at          timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS reconciliation_match_candidates_company_idx
    ON public.reconciliation_match_candidates (company_id, status);
CREATE INDEX IF NOT EXISTS reconciliation_match_candidates_entity_idx
    ON public.reconciliation_match_candidates (entity_id);
CREATE UNIQUE INDEX IF NOT EXISTS reconciliation_match_candidates_unique_pair
    ON public.reconciliation_match_candidates (record_a_id, record_b_id)
    WHERE status = 'pending';

COMMENT ON TABLE public.reconciliation_match_candidates IS
    'Pares de registros candidatos a match, gerados pelo Splink e revisados por humanos.';

-- -----------------------------------------------------------------------------
-- 8. reconciliation_discrepancies — conflitos de campo dentro de uma entidade
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.reconciliation_discrepancies (
    id                  uuid PRIMARY KEY DEFAULT extensions.gen_random_uuid(),
    entity_id           uuid NOT NULL REFERENCES public.reconciliation_entities(id) ON DELETE CASCADE,
    company_id          uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
    field_name          text NOT NULL,
    source_record_id    uuid REFERENCES public.reconciliation_source_records(id) ON DELETE SET NULL,
    competing_value     jsonb NOT NULL DEFAULT '{}'::jsonb,
    resolution          public.reconciliation_discrepancy_resolution NOT NULL DEFAULT 'unresolved',
    reviewer_id         uuid REFERENCES auth.users(id) ON DELETE SET NULL,
    resolved_at         timestamptz,
    created_at          timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS reconciliation_discrepancies_entity_idx
    ON public.reconciliation_discrepancies (entity_id);
CREATE INDEX IF NOT EXISTS reconciliation_discrepancies_unresolved_idx
    ON public.reconciliation_discrepancies (company_id)
    WHERE resolution = 'unresolved';

COMMENT ON TABLE public.reconciliation_discrepancies IS
    'Conflitos de campo dentro de uma entidade, exigindo decisão do revisor.';

-- -----------------------------------------------------------------------------
-- 9. reconciliation_evidence — evidências que sustentam uma decisão
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.reconciliation_evidence (
    id                  uuid PRIMARY KEY DEFAULT extensions.gen_random_uuid(),
    company_id          uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
    match_candidate_id  uuid REFERENCES public.reconciliation_match_candidates(id) ON DELETE CASCADE,
    discrepancy_id      uuid REFERENCES public.reconciliation_discrepancies(id) ON DELETE CASCADE,
    evidence_type       text NOT NULL, -- similarity, rule, manual, external
    evidence            jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at          timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS reconciliation_evidence_candidate_idx
    ON public.reconciliation_evidence (match_candidate_id);
CREATE INDEX IF NOT EXISTS reconciliation_evidence_discrepancy_idx
    ON public.reconciliation_evidence (discrepancy_id);

COMMENT ON TABLE public.reconciliation_evidence IS
    'Evidências que sustentam decisões de match ou correção de campo.';

-- -----------------------------------------------------------------------------
-- 10. reconciliation_reviewer_decisões — decisões humanas sobre matches/correções
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.reconciliation_reviewer_decisions (
    id                  uuid PRIMARY KEY DEFAULT extensions.gen_random_uuid(),
    company_id          uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
    decision_target_table text NOT NULL, -- tabela alvo da decisão
    decision_target_id  text NOT NULL,   -- id do alvo
    decision            public.reconciliation_decision NOT NULL,
    rationale           text,
    previous_state      jsonb NOT NULL DEFAULT '{}'::jsonb,
    new_state           jsonb NOT NULL DEFAULT '{}'::jsonb,
    reviewer_id         uuid NOT NULL REFERENCES auth.users(id) ON DELETE SET NULL,
    reviewed_at         timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS reconciliation_reviewer_decisions_company_idx
    ON public.reconciliation_reviewer_decisions (company_id, reviewed_at DESC);
CREATE INDEX IF NOT EXISTS reconciliation_reviewer_decisions_target_idx
    ON public.reconciliation_reviewer_decisions (decision_target_table, decision_target_id);

COMMENT ON TABLE public.reconciliation_reviewer_decisions IS
    'Decisões humanas sobre matches e correções. Sempre acompanhadas por entrada em audit_log.';

-- -----------------------------------------------------------------------------
-- RLS policies — todas as novas tabelas: ENABLE + FORCE ROW LEVEL SECURITY
-- -----------------------------------------------------------------------------

-- --- data_sources ---
ALTER TABLE public.reconciliation_data_sources ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reconciliation_data_sources FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS reconciliation_data_sources_select ON public.reconciliation_data_sources;
DROP POLICY IF EXISTS reconciliation_data_sources_insert ON public.reconciliation_data_sources;
DROP POLICY IF EXISTS reconciliation_data_sources_update ON public.reconciliation_data_sources;
DROP POLICY IF EXISTS reconciliation_data_sources_delete ON public.reconciliation_data_sources;
CREATE POLICY reconciliation_data_sources_select ON public.reconciliation_data_sources
    FOR SELECT TO authenticated USING (public.is_member_of(company_id));
CREATE POLICY reconciliation_data_sources_insert ON public.reconciliation_data_sources
    FOR INSERT TO authenticated WITH CHECK (public.has_role_in(company_id, 'member'));
CREATE POLICY reconciliation_data_sources_update ON public.reconciliation_data_sources
    FOR UPDATE TO authenticated USING (public.has_role_in(company_id, 'admin'))
    WITH CHECK (public.has_role_in(company_id, 'admin'));
CREATE POLICY reconciliation_data_sources_delete ON public.reconciliation_data_sources
    FOR DELETE TO authenticated USING (public.has_role_in(company_id, 'owner'));

-- --- import_jobs ---
ALTER TABLE public.reconciliation_import_jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reconciliation_import_jobs FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS reconciliation_import_jobs_select ON public.reconciliation_import_jobs;
DROP POLICY IF EXISTS reconciliation_import_jobs_insert ON public.reconciliation_import_jobs;
DROP POLICY IF EXISTS reconciliation_import_jobs_update ON public.reconciliation_import_jobs;
DROP POLICY IF EXISTS reconciliation_import_jobs_delete ON public.reconciliation_import_jobs;
CREATE POLICY reconciliation_import_jobs_select ON public.reconciliation_import_jobs
    FOR SELECT TO authenticated USING (public.is_member_of(company_id));
CREATE POLICY reconciliation_import_jobs_insert ON public.reconciliation_import_jobs
    FOR INSERT TO authenticated WITH CHECK (public.has_role_in(company_id, 'member') AND created_by = public.auth_uid());
CREATE POLICY reconciliation_import_jobs_update ON public.reconciliation_import_jobs
    FOR UPDATE TO authenticated USING (public.has_role_in(company_id, 'admin'))
    WITH CHECK (public.has_role_in(company_id, 'admin'));
CREATE POLICY reconciliation_import_jobs_delete ON public.reconciliation_import_jobs
    FOR DELETE TO authenticated USING (public.has_role_in(company_id, 'owner'));

-- --- source_records (imutável: sem UPDATE/DELETE) ---
ALTER TABLE public.reconciliation_source_records ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reconciliation_source_records FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS reconciliation_source_records_select ON public.reconciliation_source_records;
DROP POLICY IF EXISTS reconciliation_source_records_insert ON public.reconciliation_source_records;
CREATE POLICY reconciliation_source_records_select ON public.reconciliation_source_records
    FOR SELECT TO authenticated USING (public.is_member_of(company_id));
CREATE POLICY reconciliation_source_records_insert ON public.reconciliation_source_records
    FOR INSERT TO authenticated WITH CHECK (public.has_role_in(company_id, 'member'));
-- Sem UPDATE/DELETE policies: registros fonte são imutáveis por design.

-- --- entities ---
ALTER TABLE public.reconciliation_entities ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reconciliation_entities FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS reconciliation_entities_select ON public.reconciliation_entities;
DROP POLICY IF EXISTS reconciliation_entities_insert ON public.reconciliation_entities;
DROP POLICY IF EXISTS reconciliation_entities_update ON public.reconciliation_entities;
DROP POLICY IF EXISTS reconciliation_entities_delete ON public.reconciliation_entities;
CREATE POLICY reconciliation_entities_select ON public.reconciliation_entities
    FOR SELECT TO authenticated USING (public.is_member_of(company_id));
CREATE POLICY reconciliation_entities_insert ON public.reconciliation_entities
    FOR INSERT TO authenticated WITH CHECK (public.has_role_in(company_id, 'member'));
CREATE POLICY reconciliation_entities_update ON public.reconciliation_entities
    FOR UPDATE TO authenticated USING (public.has_role_in(company_id, 'admin'))
    WITH CHECK (public.has_role_in(company_id, 'admin'));
CREATE POLICY reconciliation_entities_delete ON public.reconciliation_entities
    FOR DELETE TO authenticated USING (public.has_role_in(company_id, 'owner'));

-- --- identifiers ---
ALTER TABLE public.reconciliation_identifiers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reconciliation_identifiers FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS reconciliation_identifiers_select ON public.reconciliation_identifiers;
DROP POLICY IF EXISTS reconciliation_identifiers_insert ON public.reconciliation_identifiers;
DROP POLICY IF EXISTS reconciliation_identifiers_update ON public.reconciliation_identifiers;
DROP POLICY IF EXISTS reconciliation_identifiers_delete ON public.reconciliation_identifiers;
CREATE POLICY reconciliation_identifiers_select ON public.reconciliation_identifiers
    FOR SELECT TO authenticated USING (public.is_member_of(company_id));
CREATE POLICY reconciliation_identifiers_insert ON public.reconciliation_identifiers
    FOR INSERT TO authenticated WITH CHECK (public.has_role_in(company_id, 'member'));
-- identifiers é gerenciado pelo sistema; UPDATE/DELETE direto bloqueados por omissão de policy.

-- --- reconciliation_runs ---
ALTER TABLE public.reconciliation_reconciliation_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reconciliation_reconciliation_runs FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS reconciliation_reconciliation_runs_select ON public.reconciliation_reconciliation_runs;
DROP POLICY IF EXISTS reconciliation_reconciliation_runs_insert ON public.reconciliation_reconciliation_runs;
DROP POLICY IF EXISTS reconciliation_reconciliation_runs_update ON public.reconciliation_reconciliation_runs;
DROP POLICY IF EXISTS reconciliation_reconciliation_runs_delete ON public.reconciliation_reconciliation_runs;
CREATE POLICY reconciliation_reconciliation_runs_select ON public.reconciliation_reconciliation_runs
    FOR SELECT TO authenticated USING (public.is_member_of(company_id));
CREATE POLICY reconciliation_reconciliation_runs_insert ON public.reconciliation_reconciliation_runs
    FOR INSERT TO authenticated WITH CHECK (public.has_role_in(company_id, 'member') AND created_by = public.auth_uid());
CREATE POLICY reconciliation_reconciliation_runs_update ON public.reconciliation_reconciliation_runs
    FOR UPDATE TO authenticated USING (public.has_role_in(company_id, 'admin'))
    WITH CHECK (public.has_role_in(company_id, 'admin'));
-- runs não é deletado pelo cliente (histórico de execução).

-- --- match_candidates ---
ALTER TABLE public.reconciliation_match_candidates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reconciliation_match_candidates FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS reconciliation_match_candidates_select ON public.reconciliation_match_candidates;
DROP POLICY IF EXISTS reconciliation_match_candidates_insert ON public.reconciliation_match_candidates;
DROP POLICY IF EXISTS reconciliation_match_candidates_update ON public.reconciliation_match_candidates;
DROP POLICY IF EXISTS reconciliation_match_candidates_delete ON public.reconciliation_match_candidates;
CREATE POLICY reconciliation_match_candidates_select ON public.reconciliation_match_candidates
    FOR SELECT TO authenticated USING (public.is_member_of(company_id));
CREATE POLICY reconciliation_match_candidates_insert ON public.reconciliation_match_candidates
    FOR INSERT TO authenticated WITH CHECK (public.has_role_in(company_id, 'member'));
CREATE POLICY reconciliation_match_candidates_update ON public.reconciliation_match_candidates
    FOR UPDATE TO authenticated USING (public.has_role_in(company_id, 'member'))
    WITH CHECK (public.has_role_in(company_id, 'member'));
-- delete bloqueado por omissão de policy.

-- --- discrepancies ---
ALTER TABLE public.reconciliation_discrepancies ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reconciliation_discrepancies FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS reconciliation_discrepancies_select ON public.reconciliation_discrepancies;
DROP POLICY IF EXISTS reconciliation_discrepancies_insert ON public.reconciliation_discrepancies;
DROP POLICY IF EXISTS reconciliation_discrepancies_update ON public.reconciliation_discrepancies;
DROP POLICY IF EXISTS reconciliation_discrepancies_delete ON public.reconciliation_discrepancies;
CREATE POLICY reconciliation_discrepancies_select ON public.reconciliation_discrepancies
    FOR SELECT TO authenticated USING (public.is_member_of(company_id));
CREATE POLICY reconciliation_discrepancies_insert ON public.reconciliation_discrepancies
    FOR INSERT TO authenticated WITH CHECK (public.has_role_in(company_id, 'member'));
CREATE POLICY reconciliation_discrepancies_update ON public.reconciliation_discrepancies
    FOR UPDATE TO authenticated USING (public.has_role_in(company_id, 'admin'))
    WITH CHECK (public.has_role_in(company_id, 'admin'));
-- delete bloqueado por omissão de policy.

-- --- evidence ---
ALTER TABLE public.reconciliation_evidence ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reconciliation_evidence FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS reconciliation_evidence_select ON public.reconciliation_evidence;
DROP POLICY IF EXISTS reconciliation_evidence_insert ON public.reconciliation_evidence;
CREATE POLICY reconciliation_evidence_select ON public.reconciliation_evidence
    FOR SELECT TO authenticated USING (public.is_member_of(company_id));
CREATE POLICY reconciliation_evidence_insert ON public.reconciliation_evidence
    FOR INSERT TO authenticated WITH CHECK (public.has_role_in(company_id, 'member'));
-- evidence não é atualizada/deletada pelo cliente.

-- --- reviewer_decisions ---
ALTER TABLE public.reconciliation_reviewer_decisions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reconciliation_reviewer_decisions FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS reconciliation_reviewer_decisions_select ON public.reconciliation_reviewer_decisions;
DROP POLICY IF EXISTS reconciliation_reviewer_decisions_insert ON public.reconciliation_reviewer_decisions;
CREATE POLICY reconciliation_reviewer_decisions_select ON public.reconciliation_reviewer_decisions
    FOR SELECT TO authenticated USING (public.is_member_of(company_id));
CREATE POLICY reconciliation_reviewer_decisions_insert ON public.reconciliation_reviewer_decisions
    FOR INSERT TO authenticated WITH CHECK (public.has_role_in(company_id, 'member') AND reviewer_id = public.auth_uid());
-- reviewer_decisions é append-only: sem UPDATE/DELETE policies.

-- -----------------------------------------------------------------------------
-- Helper functions específicas do módulo de reconciliação
-- -----------------------------------------------------------------------------

-- has_reconciliation_role(company_id, required_role) — wrapper para consistência
-- com as convenções do template (reutiliza has_role_in internamente).
CREATE OR REPLACE FUNCTION public.has_reconciliation_role(_company_id uuid, _required public.app_role)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT public.has_role_in(_company_id, _required)
$$;
REVOKE EXECUTE ON FUNCTION public.has_reconciliation_role(uuid, public.app_role) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.has_reconciliation_role(uuid, public.app_role) TO authenticated, service_role;

-- log_reconciliation_audit — wrapper sobre log_audit() preenchendo company_id
-- e action a partir de um contexto de reconciliação. Usado pelos workers/server.
CREATE OR REPLACE FUNCTION public.log_reconciliation_audit(
    _action         public.audit_action,
    _company_id     uuid    DEFAULT NULL,
    _target_table   text    DEFAULT NULL,
    _target_id      text    DEFAULT NULL,
    _metadata       jsonb   DEFAULT '{}'::jsonb
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    _id bigint;
BEGIN
    INSERT INTO public.audit_log (
        actor_user_id, company_id, action,
        target_user_id, target_table, target_id,
        ip_address, user_agent, metadata
    ) VALUES (
        auth.uid(), _company_id, _action,
        NULL, _target_table, _target_id,
        NULL, NULL, COALESCE(_metadata, '{}'::jsonb)
    )
    RETURNING id INTO _id;
    RETURN _id;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.log_reconciliation_audit(public.audit_action, uuid, text, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.log_reconciliation_audit(public.audit_action, uuid, text, text, jsonb) TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Trigger: source_records imutáveis (rejeita UPDATE/DELETE)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.guard_source_record_immutable()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    IF TG_OP = 'UPDATE' OR TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'Registros fonte são imutáveis: não é permitido UPDATE ou DELETE.'
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN CASE TG_OP WHEN 'DELETE' THEN OLD ELSE NEW END;
END;
$$;

DROP TRIGGER IF EXISTS source_records_immutable ON public.reconciliation_source_records;
CREATE TRIGGER source_records_immutable
    BEFORE UPDATE OR DELETE ON public.reconciliation_source_records
    FOR EACH ROW EXECUTE FUNCTION public.guard_source_record_immutable();

COMMENT ON TRIGGER source_records_immutable ON public.reconciliation_source_records IS
    'Impede UPDATE/DELETE em registros fonte. Correções passam por discrepancies + reviewer_decisions.';


