# =============================================================================
# services/reconciliation/matching/splink_worker.py
# =============================================================================
# Motor de matching probabilístico usando Splink (dependência externa, nunca
# copiada para este repositório).
#
# Fluxo:
#   1. Consulta runs com status 'queued' (escopo por company_id).
#   2. Carrega source_records da empresa para um DataFrame.
#   3. Executa Splink: schema inference -> blocking -> comparison -> matching ->
#      clustering (connected components).
#   4. Writes match_candidates, entities and identifiers back to Postgres.
#   5. Atualiza o run (status, pares comparados, matches encontrados).
#   6. Audit log para cada evento do ciclo de vida do run.
#
# Todo acesso é escopo por company_id — isolamento de tenant.
# =============================================================================

from __future__ import annotations

import json
import os
import re
import sys
import threading
import time
from datetime import datetime, timezone

import psycopg

# Garante que o pacote services.reconciliation seja importável
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))

POLL_INTERVAL_SECONDS = int(os.environ.get("RECONCILIATION_POLL_INTERVAL", "5"))
STALE_JOB_THRESHOLD_MINUTES = int(os.environ.get("RECONCILIATION_STALE_JOB_THRESHOLD_MINUTES", "30"))

MATCHING_WORKER_DB_URL = os.environ.get("SUPABASE_MATCHING_WORKER_DB_URL")
_SAFE_FIELD = re.compile(r"^[A-Za-z_][A-Za-z0-9_]{0,62}$")

if not MATCHING_WORKER_DB_URL:
    raise RuntimeError("Set SUPABASE_MATCHING_WORKER_DB_URL.")


def get_conn() -> psycopg.Connection:
    """Connect using the restricted matching-worker database login."""
    return psycopg.connect(MATCHING_WORKER_DB_URL)


def fetch_queued_runs(conn: psycopg.Connection) -> list[dict]:
    with conn.cursor() as cur:
        cur.execute("SELECT * FROM public.reconciliation_claim_matching_runs(1)")
        columns = [desc[0] for desc in cur.description]
        runs = [dict(zip(columns, row)) for row in cur.fetchall()]
    conn.commit()
    return runs


def recover_stale_runs(conn: psycopg.Connection) -> int:
    # Expired leases are recovered atomically as part of claim_matching_runs().
    return 0


def load_source_records_df(conn: psycopg.Connection, run_id: str, claim_token: str):
    """Carrega source_records da empresa para um DataFrame pandas.

    Achata o JSONB raw_data em colunas de nível superior para que o Splink
    possa comparar campos como nome, cpf, cidade, etc.
    """
    import pandas as pd
    from pandas import json_normalize

    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT * FROM public.reconciliation_matching_source_records(%s, %s)
            """,
            (run_id, claim_token),
        )
        columns = [desc[0] for desc in cur.description]
        rows = [dict(zip(columns, row)) for row in cur.fetchall()]
    conn.commit()
    df = pd.DataFrame(rows)
    if df.empty:
        return df
    # Achata raw_data (JSONB -> dict) em colunas top-level
    raw_df = json_normalize(df["raw_data"].apply(lambda x: x if isinstance(x, dict) else {}))
    # Source headers are tenant input. Omit names that cannot be represented as
    # simple SQL identifiers before they reach Splink's SQL parser.
    raw_df = raw_df[[column for column in raw_df.columns if _safe_source_field(column)]]
    raw_df.columns = [f"raw_{c}" for c in raw_df.columns]
    # Mantém o id original para referencia
    df = pd.concat([df[["id", "source_record_id"]].reset_index(drop=True), raw_df], axis=1)
    return df


def run_splink_matching(
    df,
    blocking_rules: list[dict],
    comparison_config: dict,
) -> dict:
    """Executes probabilistic matching using Splink 3.7.0 and returns {matches, pairs_compared}.

    Loads source records into a pandas DataFrame, builds Splink settings from
    blocking_rules and comparison_config, runs the Fellegi-Sunter model via
    DuckDBLinker, and returns match candidates above the threshold.
    """
    from splink.duckdb_linker import DuckDBLinker

    # 1. Carrega source_records da empresa para um DataFrame
    if df.empty:
        return {"matches": [], "pairs_compared": 0}

    # Achata raw_data (JSONB) em colunas top-level para o Splink comparar

    # 2. Build SQL only from validated source field identifiers.
    available_columns = set(df.columns)
    splink_blocking_rules = [
        _blocking_rule_to_splink(rule, available_columns)
        for rule in (blocking_rules or [])
    ]

    if not splink_blocking_rules:
        splink_blocking_rules = ["1 = 1"]

    # 3. Constrroi comparacoes do Splink a partir do comparison_config
    splink_comparisons = []
    for col_name in (comparison_config or {}).keys():
        field = _validated_field(col_name, available_columns)
        column = f"raw_{field}"
        splink_comparisons.append({
            "output_column_name": column,
            "comparison_levels": [
                {
                    "sql_condition": f'l."{column}" = r."{column}"',
                    "label_for_charts": f"Exact match on {field}",
                },
                {
                    "sql_condition": "ELSE",
                    "label_for_charts": f"All other {col_name}",
                },
            ],
        })

    if not splink_comparisons:
        # Comparacao default em todas as colunas raw_ disponíveis
        raw_cols = [c for c in df.columns if c.startswith("raw_")]
        for col_name in raw_cols:
            field = _validated_field(col_name[4:], available_columns)
            splink_comparisons.append({
                "output_column_name": f"raw_{field}",
                "comparison_levels": [
                    {
                        "sql_condition": f'l."raw_{field}" = r."raw_{field}"',
                        "label_for_charts": f"Exact match on {field}",
                    },
                    {
                        "sql_condition": "ELSE",
                        "label_for_charts": f"All other {col_name}",
                    },
                ],
            })

    # 4. Configuracao do Splink
    settings = {
        "link_type": "dedupe_only",
        "blocking_rules_to_generate_predictions": splink_blocking_rules,
        "comparisons": splink_comparisons,
        "retain_intermediate_calculation_columns": True,
        "retain_matching_columns": True,
    }

    # 5. Executa Splink via DuckDBLinker
    linker = DuckDBLinker(df, settings)

    # Estima parametros usando EM (se houver regras de bloqueio uteis)
    try:
        for br in splink_blocking_rules:
            if br != "1 = 1":
                linker.estimate_parameters_using_expectation_maximisation(br)
                break
    except Exception:
        pass  # Se falhar, usa parametros padrao

    # 6. Gera predicoes
    df_predict = linker.predict(threshold_match_probability=0.85)

    # 7. Extrai matches acima do threshold
    matches = []
    pairs_compared = len(df_predict)
    for _, row in df_predict.iterrows():
        match_prob = row.get("match_probability", 0.0)
        if match_prob is None or match_prob < 0.85:
            continue
        id_l = row.get("id_l")
        id_r = row.get("id_r")
        if id_l is None or id_r is None:
            continue
        matches.append({
            "record_a_id": str(id_l),
            "record_b_id": str(id_r),
            "match_score": float(match_prob),
            "comparison_details": {},
        })

    return {"matches": matches, "pairs_compared": pairs_compared}


def _safe_source_field(field: object) -> bool:
    return isinstance(field, str) and _SAFE_FIELD.fullmatch(field) is not None


def _validated_field(field: object, available_columns: set[str] | None = None) -> str:
    if not _safe_source_field(field):
        raise ValueError("matching field must be a simple identifier")
    if available_columns is not None and f"raw_{field}" not in available_columns:
        raise ValueError("matching field is not present in the source records")
    return field


def _blocking_rule_to_splink(rule: dict, available_columns: set[str] | None = None) -> str:
    """Converte uma regra de bloqueio JSON para string SQL do Splink.

    Produz nomes de coluna qualificados com alias de tabela (l."campo" = r."campo"),
    equivalente ao output de splink.block_on() em Splink 3.7.0.
    """
    if not isinstance(rule, dict):
        raise ValueError("blocking rule must be an object")
    field = _validated_field(rule.get("field", ""), available_columns)
    op = rule.get("op", "exact")
    if op != "exact":
        raise ValueError("unsupported blocking operation")
    return f'l."raw_{field}" = r."raw_{field}"'


def write_results(conn: psycopg.Connection, *, run_id: str, claim_token: str, matches: list[dict], source_record_ids: list[str]) -> tuple[int, int]:
    """Persist pending candidates through the run-scoped database API."""
    payload = [
        {"a": m["record_a_id"], "b": m["record_b_id"], "score": m["match_score"], "details": m["comparison_details"]}
        for m in matches
    ]
    with conn.cursor() as cur:
        cur.execute("SELECT public.reconciliation_matching_write_candidates(%s, %s, %s::jsonb)",
                    (run_id, claim_token, json.dumps(payload, ensure_ascii=False)))
        count = cur.fetchone()[0]
    conn.commit()
    return count, 0

class LeaseLost(RuntimeError):
    """The database no longer recognizes this worker as the run owner."""


def _process_run(conn: psycopg.Connection, run: dict, lease_lost: threading.Event) -> None:
    run_id = run["id"]
    claim_token = run["claim_token"]
    blocking_rules = run.get("blocking_rules") or []
    comparison_config = run.get("comparison_config") or {}
    try:
        df = load_source_records_df(conn, run_id, claim_token)
        if lease_lost.is_set():
            raise LeaseLost
        if df.empty:
            result = {"matches": [], "pairs_compared": 0}
        else:
            result = run_splink_matching(df, blocking_rules, comparison_config)
        # Splink cannot be interrupted safely mid-call; never persist its result
        # after the heartbeat has reported that this claim is no longer owned.
        if lease_lost.is_set():
            raise LeaseLost
        candidates_written, _ = write_results(conn, run_id=run_id, claim_token=claim_token,
                                              matches=result["matches"],
                                              source_record_ids=[str(x) for x in df.get("id", [])])
        if lease_lost.is_set():
            raise LeaseLost
        with conn.cursor() as cur:
            cur.execute("SELECT public.reconciliation_finish_matching_run(%s, %s, 'completed', %s, %s, NULL)",
                        (run_id, claim_token, result["pairs_compared"], len(result["matches"])))
            finished = cur.fetchone()[0]
        conn.commit()
        if not finished:
            raise LeaseLost
        print(f"[match] run={run_id} pairs={result['pairs_compared']} matches={len(result['matches'])} candidates={candidates_written}")
    except LeaseLost:
        conn.rollback()
        return
    except Exception as exc:  # noqa: BLE001
        conn.rollback()
        try:
            with conn.cursor() as cur:
                cur.execute("SELECT public.reconciliation_finish_matching_run(%s, %s, 'failed', 0, 0, %s)",
                            (run_id, claim_token, f"matching processing failed ({type(exc).__name__})"))
            conn.commit()
        except Exception:
            conn.rollback()
        print(f"[match] run={run_id} failed ({type(exc).__name__})", file=sys.stderr)

def _heartbeat_matching(run_id: str, claim_token: str, stop: threading.Event) -> None:
    while not stop.wait(60):
        try:
            with psycopg.connect(MATCHING_WORKER_DB_URL) as heartbeat_conn:
                with heartbeat_conn.cursor() as cur:
                    cur.execute("SELECT public.reconciliation_heartbeat_matching_run(%s, %s)",
                                (run_id, claim_token))
                    if not cur.fetchone()[0]:
                        stop.set()
                        return
        except Exception as exc:  # noqa: BLE001
            # Fail closed: do not continue matching on an unconfirmed lease.
            stop.set()
            print(f"[match worker] lease renewal failed ({type(exc).__name__})", file=sys.stderr)


def process_run(conn: psycopg.Connection, run: dict) -> None:
    stop = threading.Event()
    heartbeat = threading.Thread(target=_heartbeat_matching,
                                 args=(run["id"], run["claim_token"], stop), daemon=True)
    heartbeat.start()
    try:
        _process_run(conn, run, stop)
    finally:
        stop.set()
        heartbeat.join(timeout=2)


def run_once(conn: psycopg.Connection) -> int:
    """Processes one iteration: recovers stale runs, fetches and processes queued runs."""
    recover_stale_runs(conn)
    runs = fetch_queued_runs(conn)
    for run in runs:
        process_run(conn, run)
    return len(runs)


def main() -> None:
    print(f"[match worker] started. poll_interval={POLL_INTERVAL_SECONDS}s")
    conn = get_conn()
    try:
        iterations = 0
        max_iterations = int(os.environ.get("RECONCILIATION_MAX_ITERATIONS", "0"))
        while True:
            processed = run_once(conn)
            iterations += 1
            if max_iterations > 0 and iterations >= max_iterations:
                print(f"[match worker] reached limit of {max_iterations} iterations")
                break
            if processed == 0:
                time.sleep(POLL_INTERVAL_SECONDS)
    except KeyboardInterrupt:
        print("[match worker] stopped by user")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
