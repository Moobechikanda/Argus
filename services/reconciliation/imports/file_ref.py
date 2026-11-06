"""Validation for tenant-scoped private Storage object references.

This module deliberately does not resolve references against the local
filesystem. A secure private Storage signer/download flow is still required
before accepted object keys can be consumed by the worker.
"""

from __future__ import annotations

import re
import uuid


_OBJECT_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$")
_SUPPORTED_SUFFIXES = {".csv", ".json", ".jsonl"}


def validate_storage_object_ref(file_ref: str, company_id: str, data_source_id: str) -> str:
    """Return a safe object key or raise ValueError.

    Keys must be exactly ``company UUID/data-source UUID/filename``. URLs,
    local paths, traversal, encoded separators, and keys for other tenants or
    data sources are rejected.
    """
    if not isinstance(file_ref, str) or not file_ref or len(file_ref) > 256:
        raise ValueError("invalid Storage object reference")
    if any(char in file_ref for char in ("\\", "%", ":", "?", "#", "\x00")):
        raise ValueError("invalid Storage object reference")

    parts = file_ref.split("/")
    if len(parts) != 3 or any(part in ("", ".", "..") for part in parts):
        raise ValueError("invalid Storage object reference")

    try:
        expected_company = str(uuid.UUID(str(company_id)))
        expected_source = str(uuid.UUID(str(data_source_id)))
    except (ValueError, TypeError, AttributeError) as exc:
        raise ValueError("invalid tenant or data source identifier") from exc

    if parts[0] != expected_company or parts[1] != expected_source:
        raise ValueError("Storage object does not belong to the claimed tenant and data source")

    name = parts[2]
    if not _OBJECT_NAME.fullmatch(name) or name in (".", ".."):
        raise ValueError("invalid Storage object name")
    if not any(name.lower().endswith(suffix) for suffix in _SUPPORTED_SUFFIXES):
        raise ValueError("unsupported import file type")

    return file_ref
