"""Opt-in HTTP integration test against the explicitly local Supabase stack."""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import subprocess
import time
import unittest
import uuid

import httpx


def _b64url(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


def _jwt(secret: str, user_id: str, email: str) -> str:
    now = int(time.time())
    header = _b64url(b'{"alg":"HS256","typ":"JWT"}')
    payload = _b64url(json.dumps({
        "iss": "supabase", "aud": "authenticated", "role": "authenticated",
        "sub": user_id, "email": email, "iat": now, "exp": now + 900,
        "app_metadata": {"provider": "email", "providers": ["email"]},
        "user_metadata": {},
    }, separators=(",", ":")).encode())
    signature = _b64url(hmac.new(secret.encode(), f"{header}.{payload}".encode(), hashlib.sha256).digest())
    return f"{header}.{payload}.{signature}"


class LocalStorageIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.url = os.environ.get("SUPABASE_LOCAL_URL", "").rstrip("/")
        cls.anon_key = os.environ.get("SUPABASE_LOCAL_ANON_KEY", "")
        cls.service_key = os.environ.get("SUPABASE_LOCAL_SERVICE_ROLE_KEY", "")
        cls.jwt_secret = os.environ.get("SUPABASE_LOCAL_JWT_SECRET", "")
        cls.db_container = os.environ.get("SUPABASE_LOCAL_DB_CONTAINER", "")
        if not all((cls.url, cls.anon_key, cls.service_key, cls.jwt_secret, cls.db_container)):
            raise unittest.SkipTest("local Supabase API, JWT, service, and DB container values are required")
        if httpx.URL(cls.url).host not in {"localhost", "127.0.0.1", "host.docker.internal"}:
            raise RuntimeError("integration test refuses a non-local Supabase URL")
        cls.service_headers = {"apikey": cls.service_key, "authorization": f"Bearer {cls.service_key}"}
        cls.anon_headers = {"apikey": cls.anon_key}

    def _psql(self, sql: str) -> None:
        result = subprocess.run(
            ["docker", "exec", "-i", self.db_container, "psql", "-v", "ON_ERROR_STOP=1",
             "-U", "supabase_admin", "-d", "postgres"],
            input=sql, text=True, capture_output=True, timeout=30, check=False,
        )
        if result.returncode:
            self.fail("local synthetic fixture SQL failed: " + result.stderr[:400])

    def test_storage_tenant_upload_private_read_and_claim_signer(self) -> None:
        user_id, company_id, source_id, job_id, token, user_b_id, company_b_id, source_b_id, job_b_id, token_b = (
            str(uuid.uuid4()) for _ in range(10)
        )
        email = f"storage-{user_id}@example.invalid"
        email_b = f"storage-{user_b_id}@example.invalid"
        object_key = f"{company_id}/{source_id}/{uuid.uuid4()}.csv"
        slug = f"st-{user_id[:12]}"
        slug_b = f"st-{user_b_id[:12]}"
        uploaded = False
        rest = f"{self.url}/rest/v1"
        storage = f"{self.url}/storage/v1/object"
        try:
            self._psql(f"""
                INSERT INTO auth.users(id, aud, role, email, encrypted_password, email_confirmed_at,
                    raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
                VALUES ('{user_id}', 'authenticated', 'authenticated', '{email}', 'test-only', now(),
                    '{{"provider":"email","providers":["email"]}}', '{{"skip_auto_company":true}}', now(), now());
                INSERT INTO public.companies(id, name, slug, created_by)
                VALUES ('{company_id}', 'Synthetic Storage Test', '{slug}', '{user_id}');
                INSERT INTO public.memberships(company_id, user_id, role)
                VALUES ('{company_id}', '{user_id}', 'owner') ON CONFLICT DO NOTHING;
                INSERT INTO public.reconciliation_data_sources(id, company_id, name, source_type, connection_config, created_by)
                VALUES ('{source_id}', '{company_id}', 'Synthetic Storage Test', 'file', '{{}}', '{user_id}');
                INSERT INTO public.reconciliation_import_jobs(id, company_id, data_source_id, status, file_ref, created_by,
                    claim_token, lease_until)
                VALUES ('{job_id}', '{company_id}', '{source_id}', 'running', '{object_key}', '{user_id}',
                    '{token}', now() + interval '15 minutes');
                INSERT INTO auth.users(id, aud, role, email, encrypted_password, email_confirmed_at,
                    raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
                VALUES ('{user_b_id}', 'authenticated', 'authenticated', '{email_b}', 'test-only', now(),
                    '{{"provider":"email","providers":["email"]}}', '{{"skip_auto_company":true}}', now(), now());
                INSERT INTO public.companies(id, name, slug, created_by)
                VALUES ('{company_b_id}', 'Synthetic Other Tenant', '{slug_b}', '{user_b_id}');
                INSERT INTO public.memberships(company_id, user_id, role)
                VALUES ('{company_b_id}', '{user_b_id}', 'owner') ON CONFLICT DO NOTHING;
                INSERT INTO public.reconciliation_data_sources(id, company_id, name, source_type, connection_config, created_by)
                VALUES ('{source_b_id}', '{company_b_id}', 'Synthetic Other Tenant', 'file', '{{}}', '{user_b_id}');
                INSERT INTO public.reconciliation_import_jobs(id, company_id, data_source_id, status, file_ref, created_by,
                    claim_token, lease_until)
                VALUES ('{job_b_id}', '{company_b_id}', '{source_b_id}', 'running',
                    '{company_b_id}/{source_b_id}/{uuid.uuid4()}.csv', '{user_b_id}', '{token_b}', now() + interval '15 minutes');
            """)
            user_headers = {
                "apikey": self.anon_key,
                "authorization": f"Bearer {_jwt(self.jwt_secret, user_id, email)}",
            }
            upload = httpx.post(
                f"{storage}/reconciliation-imports/{object_key}",
                headers={**user_headers, "content-type": "text/csv", "x-upsert": "false"},
                content=b"id,name\n1,synthetic\n", timeout=30,
            )
            self.assertIn(upload.status_code, (200, 201), upload.text[:200])
            uploaded = True

            private_read = httpx.get(f"{storage}/reconciliation-imports/{object_key}",
                                     headers=self.anon_headers, timeout=30)
            self.assertIn(private_read.status_code, (400, 401, 403, 404), private_read.text[:200])
            tenant_b_headers = {
                "apikey": self.anon_key,
                "authorization": f"Bearer {_jwt(self.jwt_secret, user_b_id, email_b)}",
            }
            foreign_read = httpx.get(f"{storage}/reconciliation-imports/{object_key}",
                                     headers=tenant_b_headers, timeout=30)
            self.assertIn(foreign_read.status_code, (400, 401, 403, 404), foreign_read.text[:200])

            foreign_path = f"{uuid.uuid4()}/{source_id}/{uuid.uuid4()}.csv"
            foreign_upload = httpx.post(
                f"{storage}/reconciliation-imports/{foreign_path}",
                headers={**user_headers, "content-type": "text/csv", "x-upsert": "false"},
                content=b"id\n1\n", timeout=30,
            )
            self.assertIn(foreign_upload.status_code, (400, 401, 403), foreign_upload.text[:200])

            signed = httpx.post(
                f"{self.url}/functions/v1/import-download-url",
                headers={**self.anon_headers, "authorization": f"Bearer {token}"},
                json={"job_id": job_id}, timeout=30,
            )
            self.assertEqual(signed.status_code, 200, signed.text[:200])
            downloaded = httpx.get(self.url + signed.json()["path"], timeout=30, follow_redirects=False)
            self.assertEqual(downloaded.status_code, 200)
            self.assertEqual(downloaded.content, b"id,name\n1,synthetic\n")

            other_tenant_claim = httpx.post(
                f"{self.url}/functions/v1/import-download-url",
                headers={**self.anon_headers, "authorization": f"Bearer {token_b}"},
                json={"job_id": job_id}, timeout=30,
            )
            self.assertEqual(other_tenant_claim.status_code, 403, other_tenant_claim.text[:200])

            invalid = httpx.post(
                f"{self.url}/functions/v1/import-download-url",
                headers={**self.anon_headers, "authorization": f"Bearer {uuid.uuid4()}"},
                json={"job_id": job_id}, timeout=30,
            )
            self.assertEqual(invalid.status_code, 403, invalid.text[:200])
            self._psql(f"UPDATE public.reconciliation_import_jobs SET lease_until = now() - interval '1 second' WHERE id = '{job_id}';")
            expired = httpx.post(
                f"{self.url}/functions/v1/import-download-url",
                headers={**self.anon_headers, "authorization": f"Bearer {token}"},
                json={"job_id": job_id}, timeout=30,
            )
            self.assertEqual(expired.status_code, 403, expired.text[:200])
        finally:
            if uploaded:
                httpx.delete(f"{storage}/reconciliation-imports/{object_key}",
                             headers=self.service_headers, timeout=30)
            self._psql(f"""
                BEGIN;
                ALTER TABLE public.memberships DISABLE TRIGGER USER;
                DELETE FROM public.companies WHERE id = '{company_b_id}';
                DELETE FROM public.companies WHERE id = '{company_id}';
                DELETE FROM auth.users WHERE id = '{user_b_id}';
                DELETE FROM auth.users WHERE id = '{user_id}';
                ALTER TABLE public.memberships ENABLE TRIGGER USER;
                COMMIT;
            """)


if __name__ == "__main__":
    unittest.main()
