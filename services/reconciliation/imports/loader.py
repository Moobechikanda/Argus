# =============================================================================
# services/reconciliation/imports/loader.py
# =============================================================================
# Carrega registros fonte de um arquivo para a tabela
# reconciliation_source_records, de forma idempotente e imutável.
#
# Idempotência: mesma (import_job_id, source_record_id, row_hash) não duplica
# (índice único no banco). Registros fonte nunca são UPDATE/DELETE após criação.
# =============================================================================

from __future__ import annotations

import csv
import hashlib
import json
import os
from typing import Any, Iterable

import psycopg


def row_hash(record: dict[str, Any]) -> str:
    """Hash determinístico do conteúdo do registro para dedup e detecção de re-importação."""
    payload = json.dumps(record, sort_keys=True, ensure_ascii=False).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def iter_csv_rows(file_path: str) -> Iterable[dict[str, Any]]:
    """Lê um arquivo CSV e yields dicts (chave = cabeçalho da coluna)."""
    with open(file_path, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            yield {k: (v if v != "" else None) for k, v in row.items()}


def iter_jsonl_rows(file_path: str) -> Iterable[dict[str, Any]]:
    """Lê um arquivo JSONL (uma linha = um JSON) e yields dicts."""
    with open(file_path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            yield json.loads(line)


def iter_json_array_rows(file_path: str) -> Iterable[dict[str, Any]]:
    """Lê um arquivo JSON array e yields dicts."""
    with open(file_path, encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, list):
        raise ValueError("JSON deve ser um array de objetos")
    for item in data:
        if not isinstance(item, dict):
            raise ValueError("Cada item do array deve ser um objeto")
        yield item


def detect_format(file_path: str) -> str:
    """Detecta o formato do arquivo pela extensão."""
    ext = os.path.splitext(file_path)[1].lower()
    if ext == ".csv":
        return "csv"
    if ext == ".jsonl":
        return "jsonl"
    if ext == ".json":
        return "json"
    raise ValueError(f"Formato não suportado: {ext}")


def iter_records(file_path: str) -> Iterable[dict[str, Any]]:
    """Yields registros normalizados a partir de um arquivo."""
    fmt = detect_format(file_path)
    if fmt == "csv":
        return iter_csv_rows(file_path)
    if fmt == "jsonl":
        return iter_jsonl_rows(file_path)
    return iter_json_array_rows(file_path)


def load_source_records(
    conn: psycopg.Connection,
    *,
    import_job_id: str,
    claim_token: str,
    file_path: str,
) -> dict[str, Any]:
    """Carrega registros fonte de um arquivo para reconciliation_source_records.

    Retorna estatísticas: { total, inserted, skipped_duplicates, errors, row_errors }.
    row_errors é uma lista de { line, source_record_id, error } para cada linha falhada.
    Cada INSERT é idempotente graças ao índice único
    (import_job_id, source_record_id, row_hash).
    """
    stats: dict[str, Any] = {
        "total": 0,
        "inserted": 0,
        "skipped_duplicates": 0,
        "errors": 0,
        "row_errors": [],
    }

    line_no = 0
    for record in iter_records(file_path):
        line_no += 1
        stats["total"] += 1
        source_record_id = str(record.pop("id", record.get("source_record_id") or ""))
        if not source_record_id:
            source_record_id = row_hash(record)[:32]

        rh = row_hash(record)

        try:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT public.reconciliation_import_insert_record(%s, %s, %s, %s::jsonb, %s::jsonb, %s)",
                    (import_job_id, claim_token, source_record_id,
                     json.dumps(record, ensure_ascii=False), json.dumps(record, ensure_ascii=False), rh),
                )
                inserted = cur.fetchone()[0]
            conn.commit()
            if inserted:
                stats["inserted"] += 1
            else:
                stats["skipped_duplicates"] += 1
        except Exception as exc:  # noqa: BLE001
            conn.rollback()
            stats["errors"] += 1
            stats["row_errors"].append({
                "line": line_no,
                "source_record_id": source_record_id,
                "error": str(exc)[:500],
            })

    return stats
