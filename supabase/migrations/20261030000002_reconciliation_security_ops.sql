-- =============================================================================
-- 20261030000002 — Segurança e operações do módulo de reconciliação
-- =============================================================================
-- Objetivo: adicionar camadas de seguranca e operacao ao modulo de
-- reconciliacao, sem alterar o schema base (migration 20261029000001).
--
-- 1. Criptografia de nivel de campo (pgsodium) para dados sensiveis em
--    reconciliation_source_records (raw_data / normalized_data).
-- 2. pg_cron para agendamento de jobs de importacao e execucoes de
--    reconciliacao (fila de processamento dentro do proprio Postgres).
-- 3. Politica de retencao de public.audit_log (limpeza mensal de entradas
--    com mais de 12 meses).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Extensoes de seguranca
-- -----------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pgsodium;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- -----------------------------------------------------------------------------
-- 2. Gerenciamento de chaves de criptografia (pgsodium crypto_secretbox)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.reconciliation_encryption_keys (
    id              uuid PRIMARY KEY DEFAULT extensions.gen_random_uuid(),
    company_id      uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
    key_name        text NOT NULL DEFAULT 'master',
    key             bytea NOT NULL, -- 32 bytes (crypto_secretbox key)
    active          boolean NOT NULL DEFAULT true,
    created_by      uuid REFERENCES auth.users(id) ON DELETE SET NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (company_id, key_name)
);

CREATE INDEX IF NOT EXISTS reconciliation_encryption_keys_company_idx
    ON public.reconciliation_encryption_keys (company_id)
    WHERE active;

COMMENT ON TABLE public.reconciliation_encryption_keys IS
    'Chaves simetricas (32 bytes) para criptografia de campo com pgsodium crypto_secretbox.';

-- -----------------------------------------------------------------------------
-- 3. Colunas criptografadas em reconciliation_source_records
-- -----------------------------------------------------------------------------
ALTER TABLE public.reconciliation_source_records
    ADD COLUMN IF NOT EXISTS raw_data_encrypted bytea,
    ADD COLUMN IF NOT EXISTS normalized_data_encrypted bytea;

COMMENT ON COLUMN public.reconciliation_source_records.raw_data_encrypted IS
    'Criptografado com pgsodium crypto_secretbox usando chave da empresa.';
COMMENT ON COLUMN public.reconciliation_source_records.normalized_data_encrypted IS
    'Criptografado com pgsodium crypto_secretbox usando chave da empresa.';

-- Indice para consultas por source_record_id (nao criptografado, necessario para RLS/JOIN)
CREATE INDEX IF NOT EXISTS reconciliation_source_records_source_record_id_idx
    ON public.reconciliation_source_records (source_record_id);

-- -----------------------------------------------------------------------------
-- 4. Funcoes de criptografia/descriptografia (SECURITY DEFINER, search_path='')
-- -----------------------------------------------------------------------------

-- encrypt_field(plaintext text, company_id uuid) -> bytea
-- Criptografa usando a chave ativa da empresa (pgsodium crypto_secretbox).
-- Retorna nonce(24 bytes) || ciphertext.
CREATE OR REPLACE FUNCTION public.reconciliation_encrypt_field(
    _plaintext text,
    _company_id uuid
)
RETURNS bytea
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    _key bytea;
    _nonce bytea;
    _ciphertext bytea;
BEGIN
    SELECT key INTO _key
    FROM public.reconciliation_encryption_keys
    WHERE company_id = _company_id
      AND active
    ORDER BY created_at DESC
    LIMIT 1;

    IF _key IS NULL THEN
        RAISE EXCEPTION 'Nenhuma chave de criptografia ativa para a empresa %.', _company_id
            USING ERRCODE = 'P0001';
    END IF;

    _nonce := pgsodium.crypto_secretbox_noncegen();

    SELECT pgsodium.crypto_secretbox(
        _plaintext::bytea,
        _nonce,
        _key
    ) INTO _ciphertext;

    RETURN _nonce || _ciphertext;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.reconciliation_encrypt_field(text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.reconciliation_encrypt_field(text, uuid) TO authenticated, service_role;

-- decrypt_field(ciphertext bytea, company_id uuid) -> text
-- Descriptografa usando a chave ativa da empresa.
CREATE OR REPLACE FUNCTION public.reconciliation_decrypt_field(
    _ciphertext bytea,
    _company_id uuid
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    _key bytea;
    _nonce bytea;
    _ct bytea;
    _plaintext bytea;
BEGIN
    SELECT key INTO _key
    FROM public.reconciliation_encryption_keys
    WHERE company_id = _company_id
      AND active
    ORDER BY created_at DESC
    LIMIT 1;

    IF _key IS NULL THEN
        RAISE EXCEPTION 'Nenhuma chave de criptografia ativa para a empresa %.', _company_id
            USING ERRCODE = 'P0001';
    END IF;

    _nonce := substring(_ciphertext FROM 1 FOR 24);
    _ct := substring(_ciphertext FROM 25);

    SELECT pgsodium.crypto_secretbox_open(
        _ct,
        _nonce,
        _key
    ) INTO _plaintext;

    RETURN convert_from(_plaintext, 'UTF8');
END;
$$;
REVOKE EXECUTE ON FUNCTION public.reconciliation_decrypt_field(bytea, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.reconciliation_decrypt_field(bytea, uuid) TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 5. RLS para chaves de criptografia
-- -----------------------------------------------------------------------------
ALTER TABLE public.reconciliation_encryption_keys ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reconciliation_encryption_keys FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS reconciliation_encryption_keys_select ON public.reconciliation_encryption_keys;
DROP POLICY IF EXISTS reconciliation_encryption_keys_insert ON public.reconciliation_encryption_keys;
DROP POLICY IF EXISTS reconciliation_encryption_keys_update ON public.reconciliation_encryption_keys;
CREATE POLICY reconciliation_encryption_keys_select ON public.reconciliation_encryption_keys
    FOR SELECT TO authenticated USING (public.is_member_of(company_id));
CREATE POLICY reconciliation_encryption_keys_insert ON public.reconciliation_encryption_keys
    FOR INSERT TO authenticated WITH CHECK (public.has_role_in(company_id, 'admin'));
CREATE POLICY reconciliation_encryption_keys_update ON public.reconciliation_encryption_keys
    FOR UPDATE TO authenticated USING (public.has_role_in(company_id, 'admin'))
    WITH CHECK (public.has_role_in(company_id, 'admin'));

-- -----------------------------------------------------------------------------
-- 6. pg_cron: job de sincronizacao periodica de importacoes pendentes
-- -----------------------------------------------------------------------------
-- O worker Python continua sendo o consumidor principal; este job serve como
-- fallback/garantia de que nenhum job fique esquecido em 'pending'.
SELECT cron.schedule(
    'reconciliation-import-pending',
    '*/5 * * * *',
    $$
    SELECT public.log_reconciliation_audit(
        'import_job.scheduled'::public.audit_action,
        NULL,
        'reconciliation_import_jobs',
        'pg_cron',
        '{"trigger": "pg_cron_pending_imports"}'::jsonb
    );
    $$
);

-- Agenda execucao de runs de reconciliacao em fila (queued) a cada 10 minutos.
-- Garante que runs criados via UI sejam processados mesmo se o worker Python
-- estiver temporariamente offline.
SELECT cron.schedule(
    'reconciliation-run-queued',
    '*/10 * * * *',
    $$
    SELECT public.log_reconciliation_audit(
        'reconciliation_run.scheduled'::public.audit_action,
        NULL,
        'reconciliation_reconciliation_runs',
        'pg_cron',
        '{"trigger": "pg_cron_queued_runs"}'::jsonb
    );
    $$
);

-- -----------------------------------------------------------------------------
-- 7. Politica de retencao de public.audit_log (limpeza por idade)
-- -----------------------------------------------------------------------------
-- Como audit_log nao e particionada (tabela existente da migration base),
-- usamos uma funcao de limpeza que remove linhas mais antigas que 12 meses.
-- Em producao, considere converter audit_log em tabela particionada por mes
-- para permitir DROP PARTITION (mais eficiente que DELETE em massa).

CREATE OR REPLACE FUNCTION public.reconciliation_audit_retention_cleanup()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    _deleted_count bigint;
BEGIN
    DELETE FROM public.audit_log
    WHERE created_at < (now() - interval '12 months');

    GET DIAGNOSTICS _deleted_count = ROW_COUNT;

    SELECT public.log_reconciliation_audit(
        'audit_log.retention_cleanup'::public.audit_action,
        NULL,
        'audit_log',
        'pg_cron',
        jsonb_build_object('deleted_rows', _deleted_count)
    );
END;
$$;
REVOKE EXECUTE ON FUNCTION public.reconciliation_audit_retention_cleanup() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.reconciliation_audit_retention_cleanup() TO authenticated, service_role;

-- Agenda limpeza mensal (dia 1, 00:00)
SELECT cron.schedule(
    'reconciliation-audit-retention',
    '0 0 1 * *',
    $$
    SELECT public.reconciliation_audit_retention_cleanup();
    $$
);

-- -----------------------------------------------------------------------------
-- 8. Indice de auditoria por acao + empresa (consultas frequentes de auditoria)
-- -----------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS audit_log_action_company_idx
    ON public.audit_log (action, company_id)
    WHERE company_id IS NOT NULL;

COMMENT ON TABLE public.audit_log IS
    'Log de auditoria append-only. Politica de retencao: 12 meses (limpeza mensal via pg_cron).';
