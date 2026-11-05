"""Synthetic fixtures test validation failures; these are NOT AWS execution evidence."""
import sys
from pathlib import Path
import unittest
from decimal import Decimal

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from athena_cost_model import billed_bytes, estimate, validate_evidence, STRATEGIES


def fixture():
    runs, logs = [], []
    for name in STRATEGIES:
        for i in range(1, 4):
            row = dict(benchmark=name, iteration=i, query_execution_id=f'fixture-{name}-{i}',
                       result_signature=('a' if name.endswith('full') else 'b') * 64,
                       sql_sha256='c'*64, result_rows=3, data_scanned_bytes=20*1024**2,
                       engine_execution_ms=20, total_execution_ms=30)
            runs.append(row)
            logs.append(dict(row, state='SUCCEEDED', category='BENCHMARK'))
    return (dict(status='PASS', result_reuse_enabled=False, run_id='TEST-ONLY', iterations_per_strategy=3, runs=runs),
            dict(status='DEPLOYED_RUN_AND_VERIFIED', run_id='TEST-ONLY', query_executions=logs))


class EvidenceTests(unittest.TestCase):
    def test_valid(self):
        self.assertEqual(set(validate_evidence(*fixture())), set(STRATEGIES))

    def test_reject_invalid_evidence(self):
        changes = [
            lambda r,d: r.update(result_reuse_enabled=True),
            lambda r,d: r['runs'].pop(),
            lambda r,d: d.update(run_id='wrong'),
            lambda r,d: d['query_executions'][0].update(state='FAILED'),
            lambda r,d: r['runs'][0].update(result_rows=2),
            lambda r,d: r['runs'][0].update(result_signature='d'*64),
            lambda r,d: r['runs'][0].update(iteration=2),
            lambda r,d: r['runs'][0].update(data_scanned_bytes=-1),
            lambda r,d: d['query_executions'][0].update(data_scanned_bytes=42),
            lambda r,d: r['runs'][0].update(query_execution_id=r['runs'][1]['query_execution_id']),
        ]
        for change in changes:
            with self.subTest(change=change):
                r, d = fixture()
                change(r, d)
                with self.assertRaises(ValueError):
                    validate_evidence(r, d)

    def test_stable_but_wrong_sql_result(self):
        r, d = fixture()
        for row in r['runs']:
            if row['benchmark'] == 'parquet_full':
                row['result_signature'] = 'd'*64
        with self.assertRaisesRegex(ValueError, 'SQL result mismatch'):
            validate_evidence(r, d)

    def test_billing_floor_and_rounding(self):
        mb = 1024**2
        self.assertEqual(billed_bytes(0), 10*mb)
        self.assertEqual(billed_bytes(10*mb), 10*mb)
        self.assertEqual(billed_bytes(10*mb+1), 11*mb)
        self.assertEqual(billed_bytes(10_000_001, 1000), 11_000_000)

    def test_floor_can_eliminate_savings(self):
        result = estimate({'csv_full':[{'data_scanned_bytes':1000}], 'parquet_full':[{'data_scanned_bytes':118}]}, 1000, '5')
        self.assertEqual(Decimal(result['modeled_monthly_savings_usd']['csv_full_to_parquet_full']), 0)

    def test_round_each_execution_before_average(self):
        mb = 1024**2
        result = estimate({'csv_full':[{'data_scanned_bytes':10*mb}, {'data_scanned_bytes':10*mb+1}]}, 1, '5')
        self.assertEqual(Decimal(result['strategies']['csv_full']['monthly_query_charge_usd']), Decimal('10.5')*mb/1024**4*5)

    def test_invalid_inputs(self):
        for price in ('NaN', 'Infinity', '-5', '0'):
            with self.assertRaises(ValueError):
                estimate({}, 1, price)
        with self.assertRaises(ValueError):
            estimate({}, -1, '5')


if __name__ == '__main__':
    unittest.main()
