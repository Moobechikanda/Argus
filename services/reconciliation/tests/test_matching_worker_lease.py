"""Fail-closed and error-redaction checks for matching worker leases."""

from __future__ import annotations

import importlib
import os
import threading
import unittest
from unittest.mock import MagicMock, patch


with patch.dict(os.environ, {"SUPABASE_MATCHING_WORKER_DB_URL": "postgresql://test@localhost/db"}):
    worker = importlib.import_module("services.reconciliation.matching.splink_worker")


class MatchingWorkerLeaseTests(unittest.TestCase):
    def test_lost_lease_during_matching_prevents_candidate_write(self) -> None:
        conn = MagicMock()
        df = MagicMock(empty=False)
        df.get.return_value = []
        stop = threading.Event()
        result = {"matches": [{"record_a_id": "a", "record_b_id": "b", "match_score": 0.9,
                               "comparison_details": {}}], "pairs_compared": 1}

        def lose_lease(*_args, **_kwargs):
            stop.set()
            return result

        with patch.object(worker, "load_source_records_df", return_value=df), \
             patch.object(worker, "run_splink_matching", side_effect=lose_lease), \
             patch.object(worker, "write_results") as write:
            worker._process_run(conn, {"id": "run-id", "claim_token": "claim"}, stop)

        write.assert_not_called()
        conn.rollback.assert_called_once()
        conn.cursor.assert_not_called()

    def test_heartbeat_database_failure_marks_lease_lost(self) -> None:
        class StopAfterSet:
            was_set = False

            def wait(self, _seconds: int) -> bool:
                return self.was_set

            def set(self) -> None:
                self.was_set = True

        stop = StopAfterSet()
        with patch.object(worker.psycopg, "connect", side_effect=OSError("private DSN detail")):
            worker._heartbeat_matching("run-id", "claim", stop)  # type: ignore[arg-type]
        self.assertTrue(stop.was_set)

    def test_processing_exception_is_not_copied_to_database_error(self) -> None:
        conn = MagicMock()
        cursor = conn.cursor.return_value.__enter__.return_value
        cursor.fetchone.return_value = [True]
        stop = threading.Event()

        with patch.object(worker, "load_source_records_df", side_effect=ValueError("sensitive-source-value")):
            worker._process_run(conn, {"id": "run-id", "claim_token": "claim"}, stop)

        args = cursor.execute.call_args.args
        self.assertNotIn("sensitive-source-value", args[1][-1])
        self.assertIn("ValueError", args[1][-1])


if __name__ == "__main__":
    unittest.main()
