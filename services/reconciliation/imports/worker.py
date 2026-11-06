"""Process jobs using a dedicated DB login and a live claim-bound Storage URL."""

from __future__ import annotations

import csv
import hashlib
import json
import os
import re
import sys
import tempfile
import time
from pathlib import Path
from typing import Iterator
from urllib.parse import urlsplit

import httpx
import psycopg

from services.reconciliation.imports.file_ref import validate_storage_object_ref

POLL_INTERVAL = max(1, int(os.environ.get("RECONCILIATION_POLL_INTERVAL", "5")))
DB_URL = os.environ.get("SUPABASE_IMPORT_WORKER_DB_URL")
SUPABASE_URL = os.environ.get("SUPABASE_URL", "").rstrip("/")
ANON_KEY = os.environ.get("SUPABASE_ANON_KEY")
MAX_FILE_BYTES = 50 * 1024 * 1024
MAX_RECORDS = 1_000_000
_UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.I)


def _require_configuration() -> None:
    if not DB_URL or not SUPABASE_URL or not ANON_KEY:
        raise RuntimeError("Set the import worker DB URL, Supabase URL, and anon API key.")
    if "service_role" in ANON_KEY.lower():
        raise RuntimeError("The import worker must not receive a service-role key.")


def _claim() -> dict | None:
    with psycopg.connect(DB_URL) as conn, conn.cursor() as cur:
        cur.execute("SELECT * FROM public.reconciliation_claim_import_jobs(1)")
        row = cur.fetchone()
        if row is None:
            return None
        return dict(zip((d.name for d in cur.description), row))


def _heartbeat(job_id: str, token: str) -> bool:
    with psycopg.connect(DB_URL) as conn, conn.cursor() as cur:
        cur.execute("SELECT public.reconciliation_heartbeat_import(%s, %s)", (job_id, token))
        row = cur.fetchone()
        return bool(row and row[0])


def _finish(job_id: str, token: str, status: str, rows: int, errors: int, message: str | None = None) -> bool:
    with psycopg.connect(DB_URL) as conn, conn.cursor() as cur:
        cur.execute("SELECT public.reconciliation_finish_import(%s, %s, %s, %s, %s, %s)",
                    (job_id, token, status, rows, errors, message))
        result = cur.fetchone()
        return bool(result and result[0])


def _insert(job_id: str, token: str, source_id: str, raw: dict, row_hash: str) -> bool:
    encoded = json.dumps(raw, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
    with psycopg.connect(DB_URL) as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT public.reconciliation_import_insert_record(%s, %s, %s, %s::jsonb, %s::jsonb, %s)",
            (job_id, token, source_id, encoded, encoded, row_hash),
        )
        result = cur.fetchone()
        return bool(result and result[0])


def _get_download_url(job_id: str, token: str) -> str:
    response = httpx.post(
        f"{SUPABASE_URL}/functions/v1/import-download-url",
        headers={"apikey": ANON_KEY, "authorization": f"Bearer {token}"},
        json={"job_id": job_id}, timeout=15, follow_redirects=False,
    )
    if response.status_code != 200:
        raise RuntimeError("claimed-job download authorization failed")
    value = response.json().get("path")
    if not isinstance(value, str):
        raise RuntimeError("signer returned an invalid response")
    parsed = urlsplit(value)
    if parsed.scheme or parsed.netloc or not parsed.path.startswith("/storage/v1/object/sign/reconciliation-imports/"):
        raise RuntimeError("signer returned an unexpected Storage path")
    return f"{SUPABASE_URL}{value}"


def download_from_storage(file_ref: str, company_id: str, data_source_id: str, job_id: str, token: str) -> str:
    validate_storage_object_ref(file_ref, company_id, data_source_id)
    if not _UUID.fullmatch(job_id) or not _UUID.fullmatch(token):
        raise ValueError("invalid import claim")
    url = _get_download_url(job_id, token)
    directory = os.environ.get("TMPDIR", "/tmp/reconciliation")
    os.makedirs(directory, mode=0o700, exist_ok=True)
    fd, path = tempfile.mkstemp(prefix="import-", suffix=Path(file_ref).suffix.lower(), dir=directory)
    try:
        os.fchmod(fd, 0o600)
        total = 0
        with os.fdopen(fd, "wb") as output, httpx.stream("GET", url, timeout=60,
                                                           follow_redirects=False) as response:
            if response.status_code != 200:
                raise RuntimeError("private Storage download failed")
            for chunk in response.iter_bytes(64 * 1024):
                total += len(chunk)
                if total > MAX_FILE_BYTES:
                    raise RuntimeError("import file exceeds the configured limit")
                output.write(chunk)
        return path
    except Exception:
        try:
            os.close(fd)
        except OSError:
            pass
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
        raise


def _records(path: str) -> Iterator[dict]:
    suffix = Path(path).suffix.lower()
    with open(path, "r", encoding="utf-8-sig", newline="") as source:
        if suffix == ".csv":
            for row in csv.DictReader(source):
                yield dict(row)
        elif suffix == ".jsonl":
            for line in source:
                if line.strip():
                    value = json.loads(line)
                    if not isinstance(value, dict):
                        raise ValueError("each JSONL record must be an object")
                    yield value
        elif suffix == ".json":
            value = json.load(source)
            if not isinstance(value, list) or any(not isinstance(row, dict) for row in value):
                raise ValueError("JSON import must be an array of objects")
            yield from value
        else:
            raise ValueError("unsupported import file type")


class LeaseLost(RuntimeError):
    pass


def process_claim(job: dict) -> None:
    job_id, token = str(job["id"]), str(job["claim_token"])
    path = None
    count = 0
    inserted = 0
    try:
        if not job.get("data_source_id"):
            raise ValueError("import job has no data source")
        path = download_from_storage(job["file_ref"], str(job["company_id"]),
                                     str(job["data_source_id"]), job_id, token)
        if not _heartbeat(job_id, token):
            raise LeaseLost("import lease expired or was reassigned")
        for count, record in enumerate(_records(path), start=1):
            if count > MAX_RECORDS:
                raise ValueError("import exceeds the maximum record count")
            raw = json.dumps(record, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
            row_hash = hashlib.sha256(raw.encode("utf-8")).hexdigest()
            source_id = str(record.get("source_record_id") or record.get("id") or count)[:512]
            inserted += int(_insert(job_id, token, source_id, record, row_hash))
            if count % 250 == 0 and not _heartbeat(job_id, token):
                raise LeaseLost("import lease expired or was reassigned")
        if not _heartbeat(job_id, token):
            raise LeaseLost("import lease expired or was reassigned")
        _finish(job_id, token, "completed", count, count - inserted)
    except LeaseLost:
        # Do not attempt further database writes; a later claimant owns recovery.
        return
    except Exception as exc:
        try:
            # Exception strings from parsers or drivers may include source data.
            _finish(job_id, token, "failed", count, max(1, count - inserted),
                    f"import processing failed ({type(exc).__name__})")
        except Exception:
            # A stale lease is recovered by the database claim RPC after expiry.
            pass
    finally:
        if path:
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass


def run_once() -> int:
    _require_configuration()
    job = _claim()
    if not job:
        return 0
    process_claim(job)
    return 1


def main() -> None:
    _require_configuration()
    while True:
        try:
            claimed = run_once()
        except Exception as exc:
            # Do not log database URLs, claim tokens, object URLs, or row data.
            print(f"[import-worker] processing cycle failed ({type(exc).__name__})", file=sys.stderr)
            claimed = 0
        if not claimed:
            time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
