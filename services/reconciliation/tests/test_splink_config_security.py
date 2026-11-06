"""SQL configuration boundaries for tenant-controlled Splink settings."""

from __future__ import annotations

import importlib
import os
import unittest
from unittest.mock import patch


with patch.dict(os.environ, {"SUPABASE_MATCHING_WORKER_DB_URL": "postgresql://test@localhost/db"}):
    worker = importlib.import_module("services.reconciliation.matching.splink_worker")


class SplinkConfigSecurityTests(unittest.TestCase):
    def test_accepts_and_quotes_a_present_simple_field(self) -> None:
        self.assertEqual(
            worker._blocking_rule_to_splink({"field": "national_id", "op": "exact"},
                                            {"id", "raw_national_id"}),
            'l."raw_national_id" = r."raw_national_id"',
        )

    def test_rejects_sql_injection_in_blocking_field(self) -> None:
        with self.assertRaises(ValueError):
            worker._blocking_rule_to_splink(
                {"field": 'name" = 1 OR 1=1 --', "op": "exact"},
                {"raw_name"},
            )

    def test_rejects_fields_absent_from_source_and_unknown_operations(self) -> None:
        with self.assertRaisesRegex(ValueError, "not present"):
            worker._blocking_rule_to_splink({"field": "name"}, {"raw_address"})
        with self.assertRaisesRegex(ValueError, "unsupported"):
            worker._blocking_rule_to_splink({"field": "name", "op": "custom"}, {"raw_name"})

    def test_source_headers_that_are_not_simple_identifiers_are_dropped(self) -> None:
        self.assertTrue(worker._safe_source_field("name_2"))
        for header in ('name"; SELECT 1 --', "name.last", "x` FROM read_csv('/etc/passwd')"):
            with self.subTest(header=header):
                self.assertFalse(worker._safe_source_field(header))


if __name__ == "__main__":
    unittest.main()
