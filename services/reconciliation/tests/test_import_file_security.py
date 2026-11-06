"""Read-only checks for import reference and container security boundaries."""

from __future__ import annotations

import unittest
from pathlib import Path
import sys
import uuid


ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "services"))

from reconciliation.imports.file_ref import validate_storage_object_ref  # noqa: E402


COMPANY = "a1000000-0000-0000-0000-000000000001"
SOURCE = "a2000000-0000-0000-0000-000000000002"


class ImportFileSecurityTests(unittest.TestCase):
    def test_accepts_only_tenant_scoped_storage_object_key(self) -> None:
        key = f"{COMPANY}/{SOURCE}/upload_123.csv"
        self.assertEqual(validate_storage_object_ref(key, COMPANY, SOURCE), key)
        self.assertEqual(validate_storage_object_ref(key, uuid.UUID(COMPANY), uuid.UUID(SOURCE)), key)

    def test_rejects_absolute_paths(self) -> None:
        for value in ("/etc/passwd", r"C:\Windows\win.ini", r"C:\Users\example\.env"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                validate_storage_object_ref(value, COMPANY, SOURCE)

    def test_rejects_relative_paths_and_traversal(self) -> None:
        for value in (
            "records.csv", "./records.csv", "../records.csv", "../../.env",
            f"{COMPANY}/{SOURCE}/../secret.csv",
        ):
            with self.subTest(value=value), self.assertRaises(ValueError):
                validate_storage_object_ref(value, COMPANY, SOURCE)

    def test_rejects_arbitrary_urls_and_encoded_paths(self) -> None:
        for value in (
            "https://example.test/data.csv",
            "file:///etc/passwd",
            f"{COMPANY}/{SOURCE}/%2e%2e_secret.csv",
            f"{COMPANY}/{SOURCE}/file.csv?next=https://example.test",
        ):
            with self.subTest(value=value), self.assertRaises(ValueError):
                validate_storage_object_ref(value, COMPANY, SOURCE)

    def test_rejects_invalid_or_foreign_storage_object(self) -> None:
        invalid = (
            f"{COMPANY}/{SOURCE}/file.exe",
            f"b1000000-0000-0000-0000-000000000001/{SOURCE}/file.csv",
            f"{COMPANY}/b2000000-0000-0000-0000-000000000002/file.csv",
        )
        for value in invalid:
            with self.subTest(value=value), self.assertRaises(ValueError):
                validate_storage_object_ref(value, COMPANY, SOURCE)

    def test_worker_cannot_resolve_an_object_unrelated_to_claimed_job(self) -> None:
        other_tenant_key = "b1000000-0000-0000-0000-000000000001/" + SOURCE + "/file.csv"
        other_source_key = COMPANY + "/b2000000-0000-0000-0000-000000000002/file.csv"
        for value in (other_tenant_key, other_source_key):
            with self.subTest(value=value), self.assertRaises(ValueError):
                validate_storage_object_ref(value, COMPANY, SOURCE)

    def test_worker_uses_only_claim_bound_storage_urls(self) -> None:
        worker = (ROOT / "services/reconciliation/imports/worker.py").read_text(encoding="utf-8")
        self.assertNotIn("os.path.isfile(file_ref)", worker)
        self.assertNotIn("urllib.request", worker)
        self.assertIn("validate_storage_object_ref(file_ref, company_id, data_source_id)", worker)
        self.assertIn("reconciliation_claim_import_jobs(1)", worker)
        self.assertIn("/functions/v1/import-download-url", worker)
        self.assertIn("reconciliation_heartbeat_import", worker)
        self.assertIn("LeaseLost", worker)
        self.assertIn("follow_redirects=False", worker)

    def test_tenant_ui_no_longer_accepts_user_supplied_paths(self) -> None:
        page = (ROOT / "examples/nextjs/app/dashboard/reconciliation/imports/page.tsx").read_text(encoding="utf-8")
        actions = (ROOT / "examples/nextjs/lib/actions/reconciliation.ts").read_text(encoding="utf-8")
        self.assertNotIn('name="file_ref"', page)
        self.assertIn("createImportJob", actions)
        self.assertIn("reconciliation-imports", (ROOT / "examples/nextjs/app/dashboard/reconciliation/imports/upload-form.tsx").read_text(encoding="utf-8"))
        self.assertNotIn('name="file_ref"', page)
        self.assertNotIn("createSignedUrl(fileName, 86400)", actions)

    def test_worker_does_not_require_service_role_key(self) -> None:
        worker = (ROOT / "services/reconciliation/imports/worker.py").read_text(encoding="utf-8")
        compose = (ROOT / "docker-compose.yml").read_text(encoding="utf-8")
        self.assertNotIn("SUPABASE_SERVICE_ROLE_KEY", worker)
        self.assertIn("SUPABASE_IMPORT_WORKER_DB_URL", worker)
        self.assertNotIn("SUPABASE_SERVICE_ROLE_KEY", compose)
        import_service = compose.split("  worker-import:", 1)[1].split("  # ---", 1)[0]
        self.assertIn("SUPABASE_IMPORT_WORKER_DB_URL", import_service)
        self.assertIn("SUPABASE_MATCHING_WORKER_DB_URL", compose.split("  worker-match:", 1)[1])

    def test_storage_is_private_and_only_tenant_scoped_insert_is_granted(self) -> None:
        migration = (ROOT / "supabase/migrations/20261101000001_private_import_storage.sql").read_text(encoding="utf-8")
        signer = (ROOT / "supabase/functions/import-download-url/index.ts").read_text(encoding="utf-8")
        config = (ROOT / "supabase/config.toml").read_text(encoding="utf-8")
        self.assertIn("'reconciliation-imports', 'reconciliation-imports', false", migration)
        self.assertIn("FOR INSERT TO authenticated", migration)
        self.assertNotRegex(migration, r"FOR (SELECT|UPDATE|DELETE)")
        self.assertIn("public.has_role_in(ds.company_id, 'admin'", migration)
        self.assertIn("job.claim_token !== bearer", signer)
        self.assertIn("Date.parse(job.lease_until) <= Date.now()", signer)
        self.assertIn("createSignedUrl(job.file_ref, maxUrlSeconds", signer)
        self.assertIn("signedPath", signer)
        self.assertIn("verify_jwt = false", config)

    def test_worker_container_runs_unprivileged_with_restricted_runtime(self) -> None:
        dockerfile = (ROOT / "Dockerfile.worker").read_text(encoding="utf-8")
        compose = (ROOT / "docker-compose.yml").read_text(encoding="utf-8")
        self.assertIn("USER 10001:10001", dockerfile)
        self.assertIn("/tmp/reconciliation", dockerfile)
        self.assertEqual(compose.count("cap_drop:"), 2)
        self.assertEqual(compose.count("no-new-privileges:true"), 2)
        self.assertEqual(compose.count("read_only: true"), 2)

    def test_both_build_contexts_exclude_local_secrets(self) -> None:
        for ignore_file in (ROOT / ".dockerignore", ROOT / "examples/nextjs/.dockerignore"):
            with self.subTest(ignore_file=ignore_file):
                rules = ignore_file.read_text(encoding="utf-8")
                self.assertIn(".env", rules)
                self.assertIn(".env.*", rules)
                self.assertIn("**/.env.*", rules)
                self.assertIn(".git", rules)
                self.assertIn("*.pem", rules)
                self.assertIn("**/*.pem", rules)
                self.assertIn("*.key", rules)
        worker_context = (ROOT / ".dockerignore").read_text(encoding="utf-8")
        self.assertIn("node_modules", worker_context)
        self.assertIn("*.sqlite", worker_context)
        self.assertIn("*.db", worker_context)
        worker_dockerfile = (ROOT / "Dockerfile.worker").read_text(encoding="utf-8")
        next_dockerfile = (ROOT / "examples/nextjs/Dockerfile").read_text(encoding="utf-8")
        self.assertIn("COPY requirements.txt", worker_dockerfile)
        self.assertIn("COPY services/", worker_dockerfile)
        self.assertIn("COPY package.json", next_dockerfile)
        self.assertIn("COPY . .", next_dockerfile)


if __name__ == "__main__":
    unittest.main()
