# Reconciliation workers

The import and matching workers connect as separate PostgreSQL logins. They must
not use `postgres`, `service_role`, a Supabase service-role API key, or a shared
application connection string. Migration `20261031000001_worker_and_audit_security.sql`
creates the `reconciliation_import_worker` and `reconciliation_matching_worker`
roles and grants each role only its job-scoped RPCs. The RPCs claim jobs
atomically and derive tenant IDs from the claimed job/run. This remains a
centralized cross-tenant worker trust boundary: each worker can claim jobs for
all tenants over time. Separate database logins do not provide tenant-level
worker isolation.

## Local setup

1. Start the local Supabase stack and apply pending migrations without resetting
   the database:

   ```sh
   supabase start
   supabase migration up --local
   supabase test db
   ```

2. Set separate strong passwords for the two database roles using local Supabase
   SQL (do not commit or print the passwords):

   ```sql
   ALTER ROLE reconciliation_import_worker PASSWORD 'set-a-local-secret';
   ALTER ROLE reconciliation_matching_worker PASSWORD 'set-another-local-secret';
   ```

3. Add both worker database URLs to the untracked root `.env` with distinct
   credentials. The import worker also needs the public anon API key and local
   Supabase URL to request its claim-bound download URL; the service-role key
   remains only in the Edge Function runtime.
4. Start services with `docker compose up --build`.

Migration `20261101000001_private_import_storage.sql` creates the private
`reconciliation-imports` bucket. Authenticated admins can upload only beneath
their own company and active data source. There is no client read, update, or
delete policy. The `import-download-url` Edge Function checks the job ID,
claim token, and live lease before signing its fixed bucket object for 60
seconds. It requires the public anon API key at the gateway but keeps the
service-role key inside the function runtime.

The import worker claims one job through its RPC, requests the signer with the
claim token, validates the returned URL host and Storage path, streams at most
50 MiB to a mode-0600 temporary file, and renews its lease while importing.
It exits processing when renewal fails. Input formats are CSV, JSON arrays of
objects, and JSONL objects. Database inserts are idempotent per job, source
record ID, and row hash. Temporary input files are removed after processing.
Import jobs can be created by the UI and are processed when a worker with valid
credentials is started; the application does not globally pause imports.

The Next.js container receives only its public Supabase URL, anon key, and site
URL. Each worker receives only its own database URL. No worker receives a
database superuser or service-role key.

## Operational notes

- Configure the two role passwords out of band in each environment. Do not reuse
  the local role credentials in staging or production.
- The roles are `LOGIN`, `NOSUPERUSER`, `NOBYPASSRLS`, `NOCREATEDB`, and
  `NOCREATEROLE`; direct table access is revoked. The `SECURITY DEFINER` RPCs are
  owned by `postgres`, use an empty `search_path`, and validate job/run claim
  tokens before writing or returning tenant records.
- Audit retention is disabled unless an approved value is recorded in
  `reconciliation_audit_retention_policy`. Only a database administrator should
  set the approved retention period and approval metadata. The scheduled cleanup
  executes as the `reconciliation_scheduler` role.
- Migrations `20261101000004_recover_missing_worker_leases.sql` and
  `20261101000006_enforce_import_finish_lease.sql` reclaim running jobs/runs
  with missing or expired leases. Verify that both are applied before starting
  workers in a target environment.
- The matching worker validates tenant-controlled field names and excludes unsafe source headers before creating Splink SQL. It fails closed when lease renewal fails; a synchronous Splink call is allowed to finish in memory but its result is not written after lease loss.
- Source records, matching inputs, and some review/export views remain plaintext.
  The import worker handles source files in tmpfs and matching handles records
  in process memory; neither is field encryption.
- Migrations `20261101000003_contain_encryption_keys_and_audit.sql` and
  `20261101000007_revoke_all_legacy_crypto_overloads.sql` remove application
  role access to prototype key bytes and revoke every legacy crypto overload.
  Migration `20261101000005_revoke_audit_mutation_grants.sql` removes direct
  audit table mutation grants. Current import and matching paths do not use
  the crypto functions.
- The migration has not been applied to any remote database by this change.
- Run `python -m unittest discover -s services/reconciliation/tests` for local
  checks. `test_local_storage_integration.py` is opt-in and requires local API,
  anon, service-role, JWT secret, and local DB-container values in process
  environment; it creates a synthetic user/tenant/job, exercises the real
  Storage API and signer, then removes only those fixtures and its uniquely
  named object.
