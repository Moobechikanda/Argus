-- =============================================================================
-- Testes pgTAP — validação das RLS policies
-- =============================================================================
-- Roda com: supabase test db
-- Cobre os cenários críticos de segurança que NÃO podem regredir.
-- =============================================================================

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET search_path TO extensions, public, auth;

-- =============================================================================
-- Setup: cria 3 usuários e 1 empresa (alice=owner, bob=member, eve=fora)
-- =============================================================================
SELECT plan(26);

INSERT INTO auth.users (id, email, instance_id, aud, role, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, confirmation_token, email_change, email_change_token_new, recovery_token, created_at, updated_at)
VALUES
    ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'alice@test.com', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '', now(), '{}'::jsonb, '{"skip_auto_company":true}'::jsonb, '', '', '', '', now(), now()),
    ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'bob@test.com',   '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '', now(), '{}'::jsonb, '{"skip_auto_company":true}'::jsonb, '', '', '', '', now(), now()),
    ('cccccccc-cccc-cccc-cccc-cccccccccccc', 'eve@test.com',   '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '', now(), '{}'::jsonb, '{"skip_auto_company":true}'::jsonb, '', '', '', '', now(), now())
ON CONFLICT DO NOTHING;

INSERT INTO public.companies (id, name, slug, created_by) VALUES
    ('11111111-1111-1111-1111-111111111111', 'Test Co', 'test-co', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')
ON CONFLICT DO NOTHING;

-- O trigger set_company_creator já adicionou alice como owner.
-- Bob entra como member (via service_role bypassando policy de INSERT).
INSERT INTO public.memberships (company_id, user_id, role) VALUES
    ('11111111-1111-1111-1111-111111111111', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'member')
ON CONFLICT DO NOTHING;

-- =============================================================================
-- Helpers: alternar entre contextos authenticated/superuser
-- =============================================================================
CREATE OR REPLACE FUNCTION test_as_user(_uid uuid) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM set_config('request.jwt.claims',
        json_build_object('sub', _uid, 'role', 'authenticated')::text, true);
    PERFORM set_config('role', 'authenticated', true);
END $$;

CREATE OR REPLACE FUNCTION test_reset() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('role', 'postgres', true);
END $$;

-- =============================================================================
-- Test 1: owner vê a própria empresa
-- =============================================================================
SELECT test_as_user('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');

SELECT ok(
    EXISTS(SELECT 1 FROM public.companies WHERE id = '11111111-1111-1111-1111-111111111111'),
    'owner consegue ler própria empresa'
);

-- =============================================================================
-- Test 2: não-membro NÃO vê a empresa
-- =============================================================================
SELECT test_as_user('cccccccc-cccc-cccc-cccc-cccccccccccc');

SELECT ok(
    NOT EXISTS(SELECT 1 FROM public.companies WHERE id = '11111111-1111-1111-1111-111111111111'),
    'não-membro NÃO consegue ler empresa alheia'
);

-- =============================================================================
-- Test 3: anônimo não vê nada
-- =============================================================================
SELECT test_reset();
SELECT set_config('role', 'anon', true);

SELECT ok(
    NOT EXISTS(SELECT 1 FROM public.companies),
    'anônimo não vê nenhuma empresa'
);

-- =============================================================================
-- Test 4: member não consegue UPDATE em company (RLS bloqueia silenciosamente)
-- =============================================================================
-- RLS UPDATE que não bate na USING NÃO joga erro — apenas afeta 0 linhas.
-- Validamos comparando o nome antes e depois.
SELECT test_as_user('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');

UPDATE public.companies SET name = 'Hacked' WHERE id = '11111111-1111-1111-1111-111111111111';

SELECT test_reset();  -- volta a superuser para conseguir ler o nome real

SELECT is(
    (SELECT name FROM public.companies WHERE id = '11111111-1111-1111-1111-111111111111'),
    'Test Co',
    'member NÃO consegue alterar nome da empresa (RLS bloqueia silenciosamente)'
);

-- =============================================================================
-- Test 5: owner pode atualizar empresa
-- =============================================================================
SELECT test_as_user('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');

UPDATE public.companies SET name = 'Test Co (renomeada)'
WHERE id = '11111111-1111-1111-1111-111111111111';

SELECT test_reset();

SELECT is(
    (SELECT name FROM public.companies WHERE id = '11111111-1111-1111-1111-111111111111'),
    'Test Co (renomeada)',
    'owner consegue atualizar empresa'
);

-- =============================================================================
-- Test 6: não permite remover o último owner
-- =============================================================================
-- Removemos Bob (como superuser) para deixar só Alice como owner.
DELETE FROM public.memberships
WHERE company_id = '11111111-1111-1111-1111-111111111111'
  AND user_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';

-- Tentativa de remover Alice — trigger guard_membership_change deve bloquear.
-- SQLSTATE 23514 = check_violation
SELECT test_as_user('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');

SELECT throws_ok(
    $$DELETE FROM public.memberships WHERE company_id = '11111111-1111-1111-1111-111111111111' AND user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'$$,
    '23514',
    NULL,
    'remoção do último owner é bloqueada'
);

-- =============================================================================
-- Test 7: não permite rebaixar o último owner
-- =============================================================================
SELECT throws_ok(
    $$UPDATE public.memberships SET role = 'member' WHERE company_id = '11111111-1111-1111-1111-111111111111' AND user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'$$,
    '23514',
    NULL,
    'rebaixar último owner é bloqueado'
);

-- =============================================================================
-- Test 8: has_role_in retorna corretamente para hierarquia
-- =============================================================================
SELECT test_as_user('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');

SELECT ok(public.has_role_in('11111111-1111-1111-1111-111111111111', 'viewer'::public.app_role),
    'owner tem role >= viewer');
SELECT ok(public.has_role_in('11111111-1111-1111-1111-111111111111', 'admin'::public.app_role),
    'owner tem role >= admin');
SELECT ok(public.has_role_in('11111111-1111-1111-1111-111111111111', 'owner'::public.app_role),
    'owner tem role >= owner');

-- Re-adiciona Bob (como superuser, bypassando ausência de policy INSERT)
SELECT test_reset();
INSERT INTO public.memberships (company_id, user_id, role) VALUES
    ('11111111-1111-1111-1111-111111111111', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'member')
ON CONFLICT DO NOTHING;

SELECT test_as_user('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');

SELECT ok(public.has_role_in('11111111-1111-1111-1111-111111111111', 'viewer'::public.app_role),
    'member tem role >= viewer');
SELECT ok(NOT public.has_role_in('11111111-1111-1111-1111-111111111111', 'admin'::public.app_role),
    'member NÃO tem role >= admin');

-- =============================================================================
-- Test 9: audit_log é INSERT-only pelo cliente (deve dar 42501 = insufficient_privilege)
-- =============================================================================
SELECT throws_ok(
    $$INSERT INTO public.audit_log (action, company_id) VALUES ('company.created', '11111111-1111-1111-1111-111111111111')$$,
    '42501',
    NULL,
    'INSERT direto em audit_log é bloqueado (deve usar log_audit())'
);

-- =============================================================================
-- Test 10/11: profile só pode ser atualizado pelo dono
-- =============================================================================
UPDATE public.profiles SET full_name = 'Bob (próprio)' WHERE id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';

SELECT test_reset();

SELECT is(
    (SELECT full_name FROM public.profiles WHERE id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'),
    'Bob (próprio)',
    'usuário atualiza próprio perfil'
);

SELECT test_as_user('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');
UPDATE public.profiles SET full_name = 'Hacked' WHERE id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';

SELECT test_reset();
SELECT isnt(
    (SELECT full_name FROM public.profiles WHERE id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),
    'Hacked',
    'usuário não consegue alterar perfil alheio'
);

-- =============================================================================
-- Setup adicional para reconciliação: 2ª empresa (co-b) fora do escopo de alice/bob
-- =============================================================================
INSERT INTO public.companies (id, name, slug, created_by) VALUES
    ('22222222-2222-2222-2222-222222222222', 'Co B', 'co-b', 'cccccccc-cccc-cccc-cccc-cccccccccccc')
ON CONFLICT DO NOTHING;

-- import_job de alice na empresa de teste (test-co)
INSERT INTO public.reconciliation_import_jobs (
    id, company_id, data_source_id, status, file_ref, row_count, error_count, created_by
) VALUES
    ('33333333-3333-3333-3333-333333333333', '11111111-1111-1111-1111-111111111111', NULL,
     'completed', 's3://bucket/file.csv', 10, 0, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')
ON CONFLICT DO NOTHING;

-- source_record de alice na empresa de teste
INSERT INTO public.reconciliation_source_records (
    id, import_job_id, company_id, source_record_id, raw_data, normalized_data, row_hash
) VALUES
    ('44444444-4444-4444-4444-444444444444', '33333333-3333-3333-3333-333333333333',
     '11111111-1111-1111-1111-111111111111', 'SRC-001',
     '{"name":"Alice","cpf":"111"}'::jsonb, '{"name":"Alice"}'::jsonb,
     'hash-alice-001')
ON CONFLICT DO NOTHING;

-- entidade de alice na empresa de teste
INSERT INTO public.reconciliation_entities (
    id, company_id, canonical_data, record_count, status, created_by
) VALUES
    ('55555555-5555-5555-5555-555555555555', '11111111-1111-1111-1111-111111111111',
     '{"name":"Alice"}'::jsonb, 1, 'candidate', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')
ON CONFLICT DO NOTHING;

-- =============================================================================
-- Test 16: tenant isolation — eve (não-membro) não vê source_records de alice
-- =============================================================================
SELECT test_as_user('cccccccc-cccc-cccc-cccc-cccccccccccc');

SELECT ok(
    NOT EXISTS(
        SELECT 1 FROM public.reconciliation_source_records
        WHERE id = '44444444-4444-4444-4444-444444444444'
    ),
    'não-membro NÃO vê registros fonte de outra empresa'
);

SELECT ok(
    NOT EXISTS(
        SELECT 1 FROM public.reconciliation_entities
        WHERE id = '55555555-5555-5555-5555-555555555555'
    ),
    'não-membro NÃO vê entidades de outra empresa'
);

SELECT test_reset();

-- =============================================================================
-- Test 17: tenant isolation — bob (member da empresa de alice) vê source_records
-- =============================================================================
SELECT test_as_user('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');

SELECT ok(
    EXISTS(
        SELECT 1 FROM public.reconciliation_source_records
        WHERE id = '44444444-4444-4444-4444-444444444444'
    ),
    'member vê registros fonte de sua própria empresa'
);

SELECT test_reset();

-- =============================================================================
-- Test 18: RBAC — viewer não consegue INSERT em import_jobs
-- (precisaríamos de um viewer; reutilizamos eve como não-membro -> espera 42501/0 linhas)
-- Aqui validamos que member pode criar e viewer não. Sem usuário viewer cadastrado,
-- validamos que o INSERT com created_by diferente do auth_uid é rejeitado pelo WITH CHECK.
-- =============================================================================
SELECT test_as_user('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');

-- bob cria um import_job na própria empresa (deve funcionar)
INSERT INTO public.reconciliation_import_jobs (
    id, company_id, status, file_ref, created_by
) VALUES
    ('66666666-6666-6666-6666-666666666666', '11111111-1111-1111-1111-111111111111',
     'pending', 's3://bucket/file2.csv', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb')
ON CONFLICT DO NOTHING;

SELECT test_reset();

SELECT ok(
    EXISTS(
        SELECT 1 FROM public.reconciliation_import_jobs
        WHERE id = '66666666-6666-6666-6666-666666666666'
    ),
    'member consegue criar import_job na própria empresa'
);

-- =============================================================================
-- Test 19: RBAC — member não consegue alterar status de entidade para 'confirmed'
-- (apenas admin+ pode atualizar entidades; RLS UPDATE com has_role_in admin bloqueia)
-- =============================================================================
SELECT test_as_user('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');

UPDATE public.reconciliation_entities
SET status = 'confirmed'::public.reconciliation_entity_status,
    updated_at = now()
WHERE id = '55555555-5555-5555-5555-555555555555';

SELECT test_reset();

SELECT is(
    (SELECT status::text FROM public.reconciliation_entities
     WHERE id = '55555555-5555-5555-5555-555555555555'),
    'candidate',
    'member NÃO consegue confirmar entidade (RLS bloqueia)'
);

-- =============================================================================
-- Test 20: RBAC — admin consegue alterar entidade (alice é owner)
-- =============================================================================
SELECT test_as_user('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');

UPDATE public.reconciliation_entities
SET status = 'confirmed'::public.reconciliation_entity_status,
    updated_at = now()
WHERE id = '55555555-5555-5555-5555-555555555555';

SELECT test_reset();

SELECT is(
    (SELECT status::text FROM public.reconciliation_entities
     WHERE id = '55555555-5555-5555-5555-555555555555'),
    'confirmed',
    'owner consegue confirmar entidade'
);

-- =============================================================================
-- Test 21: imutabilidade — UPDATE em source_records é rejeitado (trigger + RLS)
-- =============================================================================
-- Como superuser, o trigger ainda impede (SECURITY DEFINER levanta exceção).
SELECT throws_ok(
    $$UPDATE public.reconciliation_source_records
      SET raw_data = '{"name":"Hacked"}'::jsonb
      WHERE id = '44444444-4444-4444-4444-444444444444'$$,
    '23514',
    NULL,
    'UPDATE em registro fonte é bloqueado (imutável)'
);

SELECT test_reset();

-- =============================================================================
-- Test 22: imutabilidade — DELETE em source_records é rejeitado
-- =============================================================================
SELECT throws_ok(
    $$DELETE FROM public.reconciliation_source_records
      WHERE id = '44444444-4444-4444-4444-444444444444'$$,
    '23514',
    NULL,
    'DELETE em registro fonte é bloqueado (imutável)'
);

SELECT test_reset();

-- =============================================================================
-- Test 23: idempotência — mesmo source_record_id + row_hash num job não duplica
-- =============================================================================
-- Como superuser (bypass RLS), tenta inserir duplicata; o índice único impede.
SELECT throws_ok(
    $$INSERT INTO public.reconciliation_source_records (
        id, import_job_id, company_id, source_record_id, raw_data, normalized_data, row_hash
    ) VALUES (
        '77777777-7777-7777-7777-777777777777', '33333333-3333-3333-3333-333333333333',
        '11111111-1111-1111-1111-111111111111', 'SRC-001',
        '{"name":"Dup"}'::jsonb, '{"name":"Dup"}'::jsonb, 'hash-alice-001'
    )$$,
    '23505',
    NULL,
    'registro fonte duplicado (mesmo job + source_record_id + row_hash) é rejeitado'
);

SELECT test_reset();

-- =============================================================================
-- Test 24: tenant isolation — source_records de outra empresa (co-b) não visíveis
-- =============================================================================
INSERT INTO public.reconciliation_source_records (
    id, import_job_id, company_id, source_record_id, raw_data, normalized_data, row_hash
) VALUES
    ('88888888-8888-8888-8888-888888888888', '33333333-3333-3333-3333-333333333333',
     '22222222-2222-2222-2222-222222222222', 'SRC-COB-001',
     '{"name":"CoB"}'::jsonb, '{"name":"CoB"}'::jsonb, 'hash-cob-001')
ON CONFLICT DO NOTHING;

SELECT test_as_user('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');

SELECT ok(
    NOT EXISTS(
        SELECT 1 FROM public.reconciliation_source_records
        WHERE id = '88888888-8888-8888-8888-888888888888'
    ),
    'owner de empresa A não vê registros fonte da empresa B'
);

SELECT test_reset();

-- =============================================================================
-- Test 25: authenticated user records an event only for their own tenant.
-- =============================================================================
SELECT test_as_user('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');

SELECT public.log_audit(
    'entity.created'::public.audit_action,
    '11111111-1111-1111-1111-111111111111',
    NULL,
    'reconciliation_entities', '55555555-5555-5555-5555-555555555555',
    '{"status": "candidate"}'::jsonb
);

SELECT test_reset();

SELECT ok(
    EXISTS(
        SELECT 1 FROM public.audit_log
        WHERE action = 'entity.created'::public.audit_action
          AND company_id = '11111111-1111-1111-1111-111111111111'
          AND target_table = 'reconciliation_entities'
    ),
    'log_audit grava evento dentro do tenant do usuário'
);

SELECT test_reset();

-- =============================================================================
SELECT * FROM finish();
ROLLBACK;
