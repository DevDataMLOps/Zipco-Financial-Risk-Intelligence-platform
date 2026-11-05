"""Offline estimates for successful, uncached ZIPCO Athena SELECT queries."""
from __future__ import annotations

import argparse
from decimal import Decimal
import json
from pathlib import Path
import re

STRATEGIES = ('csv_full', 'parquet_full', 'csv_2023', 'parquet_partitioned_2023')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def integer(value, name, minimum=0):
    require(type(value) is int and value >= minimum, f'{name} must be an integer >= {minimum}')
    return value


def billed_bytes(scanned, unit_base=1024):
    integer(scanned, 'scan bytes')
    require(unit_base in (1000, 1024), 'unit base must be 1000 or 1024')
    mb = unit_base ** 2
    return max(10 * mb, ((scanned + mb - 1) // mb) * mb)


def validate_evidence(report, deployment):
    """Recheck individual runs, SQL reconciliation and matching execution records."""
    require(report.get('status') == 'PASS', 'benchmark did not pass')
    require(report.get('result_reuse_enabled') is False, 'result reuse must be disabled')
    require(deployment.get('status') == 'DEPLOYED_RUN_AND_VERIFIED', 'deployment not verified')
    require(bool(report.get('run_id')) and report['run_id'] == deployment.get('run_id'), 'run IDs differ')
    n = integer(report.get('iterations_per_strategy'), 'iterations', 3)
    runs = report.get('runs', [])
    require(len(runs) == 4 * n, 'incomplete benchmark matrix')
    logs = deployment.get('query_executions', [])
    log_ids = [row.get('query_execution_id') for row in logs]
    require(len(log_ids) == len(set(log_ids)), 'duplicate execution logs')
    by_id = {row['query_execution_id']: row for row in logs}
    seen = set()
    groups = {name: [] for name in STRATEGIES}
    for row in runs:
        name = row.get('benchmark')
        require(name in groups, 'unknown strategy')
        qid = row.get('query_execution_id')
        require(isinstance(qid, str) and bool(qid) and qid not in seen, 'missing or duplicate execution ID')
        seen.add(qid)
        log = by_id.get(qid, {})
        require(log.get('state') == 'SUCCEEDED' and log.get('category') == 'BENCHMARK', 'missing successful execution log')
        for field in ('data_scanned_bytes', 'engine_execution_ms', 'total_execution_ms'):
            integer(row.get(field), field)
            require(row[field] == log.get(field), f'execution log mismatch: {field}')
        require(row.get('result_rows') == 3, 'expected three aggregate rows')
        integer(row.get('iteration'), 'iteration', 1)
        for field in ('result_signature', 'sql_sha256'):
            require(re.fullmatch(r'[0-9a-f]{64}', row.get(field, '')) is not None, f'invalid {field}')
        groups[name].append(row)
    for name, rows in groups.items():
        require(sorted(r['iteration'] for r in rows) == list(range(1, n + 1)), f'incomplete iterations: {name}')
        for field in ('result_signature', 'sql_sha256'):
            require(len({r[field] for r in rows}) == 1, f'unstable {field}: {name}')
    for before, after in (('csv_full', 'parquet_full'), ('csv_2023', 'parquet_partitioned_2023')):
        require(groups[before][0]['result_signature'] == groups[after][0]['result_signature'], f'SQL result mismatch: {before} / {after}')
    return groups


def estimate(groups, monthly_queries, price, unit_base=1024):
    integer(monthly_queries, 'monthly queries')
    price = Decimal(str(price))
    require(price.is_finite() and price > 0, 'price must be finite and positive')
    output = {}
    for name, rows in groups.items():
        scans = [integer(r['data_scanned_bytes'], 'scan bytes') for r in rows]
        require(bool(scans), 'empty strategy')
        # Round/minimum-charge each execution BEFORE averaging.
        cost = sum(Decimal(billed_bytes(b, unit_base)) for b in scans) / len(scans) / unit_base ** 4 * price
        output[name] = {
            'mean_scanned_bytes': str(Decimal(sum(scans)) / len(scans)),
            'monthly_query_charge_usd': str(cost * monthly_queries),
        }
    comparisons = {}
    for before, after in (('csv_full', 'parquet_full'), ('csv_2023', 'parquet_partitioned_2023')):
        if before in output and after in output:
            comparisons[f'{before}_to_{after}'] = str(Decimal(output[before]['monthly_query_charge_usd']) - Decimal(output[after]['monthly_query_charge_usd']))
    return {'strategies': output, 'modeled_monthly_savings_usd': comparisons}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--benchmark', type=Path)
    mode.add_argument('--illustrative-baseline-bytes', type=int)
    parser.add_argument('--deployment', type=Path)
    parser.add_argument('--monthly-queries', type=int, required=True)
    parser.add_argument('--price-per-tb', required=True, help='USD rate; confirm for the target region')
    parser.add_argument('--unit-base', type=int, choices=(1000, 1024), default=1024)
    args = parser.parse_args()
    try:
        if args.benchmark:
            require(args.deployment is not None, '--deployment is required with --benchmark')
            report = json.loads(args.benchmark.read_text())
            groups = validate_evidence(report, json.loads(args.deployment.read_text()))
            basis = {'label': 'MODELED_FROM_SUPPLIED_AWS_RECORDS', 'run_id': report['run_id']}
        else:
            require(args.deployment is None, '--deployment requires --benchmark')
            baseline = integer(args.illustrative_baseline_bytes, 'baseline bytes', 1)
            optimized = int(Decimal(baseline) * Decimal('0.1179'))
            groups = {'csv_full': [{'data_scanned_bytes': baseline}], 'parquet_full': [{'data_scanned_bytes': optimized}]}
            basis = {'label': 'ILLUSTRATIVE_SCALE_SCENARIO_NOT_MEASURED_BYTES', 'assumed_reduction_percent': '88.21'}
        result = estimate(groups, args.monthly_queries, args.price_per_tb, args.unit_base)
        print(json.dumps({'basis': basis, 'monthly_queries_assumed': args.monthly_queries,
            'usd_per_tb_assumed': args.price_per_tb, 'unit_base': args.unit_base,
            'billing': 'Per-query MB rounding and 10 MB minimum; successful uncached SELECTs only',
            'excludes': ['ETL', 'S3', 'Glue Catalog', 'CloudWatch', 'tax', 'credits', 'discounts', 'capacity reservations'],
            **result}, indent=2))
    except (ValueError, KeyError, TypeError, OSError) as exc:
        parser.exit(2, f'Evidence/model error: {exc}\n')


if __name__ == '__main__':
    main()
