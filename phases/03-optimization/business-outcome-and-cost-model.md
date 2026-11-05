# Query efficiency and modeled cloud cost savings

ZIPCO's business outcome is lower scan volume for equivalent financial aggregates, with a reproducible model of the resulting Athena query charges. Dollar savings below are scenarios, not a measured reduction in an AWS bill.

## Evidence chain

| Claim | Evidence | Boundary |
|---|---|---|
| 88.21% fewer full-history bytes scanned | [Recorded AWS verification](evidence/aws_optimization_benchmark_verification.json) and [benchmark report](benchmark-results-and-interpretation.md) | Percentage transcribed from supplied CloudShell output; exact bytes remain in S3 |
| Equivalent aggregate results | B01/B02 full-history and B03/B04 year-filtered signatures reconcile in the [runner](implementation/deploy_and_run_zipco_observability.sh) | Three ordered transaction-type aggregates, not proof of row-level equality across the entire database |
| Repeatable execution | Four strategies, three uncached runs each | A small benchmark, not a concurrency test |
| AWS execution records | Run-specific benchmark and deployment JSON in S3, referenced by the verification file | Original per-query records are not currently published in GitHub |
| Modeled query charges | [Offline calculator](../../scripts/athena_cost_model.py) | Assumed frequency and rate; excludes other platform charges |

The 95.55% comparison changes both scope and partition pruning. Do not multiply it into the 88.21% figure or use full-history versus 2023 as an equivalent-workload savings claim. For year-filtered economics, compare `csv_2023` with `parquet_partitioned_2023` using their actual bytes. The date range is January 1 through November 9, 2023 inclusive, as encoded in B03/B04.

## Reproduce a labeled scale scenario

From the repository root:

```bash
python scripts/athena_cost_model.py --illustrative-baseline-bytes 107374182400 --monthly-queries 1000 --price-per-tb 5
```

Assumptions: each baseline query scans **100 GiB**; the observed 88.21% reduction is assumed to hold at that larger scale; rate **USD 5 per TB**; 1 TB represented as 1024^4 bytes and 1 MB as 1024^2 bytes in the model; uncached, successful on-demand SQL SELECTs. Scaling behavior and production query frequency have not been measured. The configurable `--unit-base 1000` supports decimal-unit sensitivity analysis; the unit choice is explicit in every output.

| Assumed monthly executions | Example workload frequency | Baseline query charges | Optimized query charges | Modeled monthly reduction |
|---:|---|---:|---:|---:|
| 100 | 5 queries × 20 business days | $48.83 | $5.76 | $43.07 |
| 1,000 | 50 queries × 20 business days | $488.28 | $57.57 | $430.71 |
| 10,000 | 500 queries × 20 business days | $4,882.81 | $575.69 | $4,307.13 |

These frequencies are planning scenarios, not ZIPCO usage logs or customer demand. The 100 GiB baseline is illustrative, not ZIPCO's measured dataset scan size. Do not use the dollar values as realized portfolio savings.

For each execution, the model rounds scanned bytes up to the next MB and applies a 10 MB minimum, then averages charges across the measured runs. Monthly charges equal that average multiplied by assumed query frequency. Both queries below the minimum can have **zero modeled savings**, despite a large percentage scan reduction.

The $5/TB reference comes from [AWS's published Athena pricing example](https://aws.amazon.com/athena/pricing/), checked November 5, 2026. The minimum and rounding rule are also documented in [AWS's analytics whitepaper](https://docs.aws.amazon.com/pdfs/whitepapers/latest/big-data-analytics-options/big-data-analytics-options.pdf). This is a reference rate, not an account-specific Ohio quote; confirm the applicable regional price before budgeting. S3 storage/requests, Glue ETL/Catalog, CloudWatch, tax, credits, discounts, and capacity reservations are excluded. Net platform savings require those costs, including conversion and maintenance costs, to be included separately.

## Model from the original AWS records

Use an authenticated AWS CLI session with read access to the existing evidence objects. These commands download evidence; they do not submit Athena queries or deploy resources.

```bash
mkdir -p aws-output/zipco-optimization
aws s3 cp s3://zipco-financial-platform-825999268272-us-east-2/performance/evidence/run_id=20260813T224904Z-cloudshell/zipco_athena_performance_benchmark.json aws-output/zipco-optimization/benchmark.json --region us-east-2
aws s3 cp s3://zipco-financial-platform-825999268272-us-east-2/performance/evidence/run_id=20260813T224904Z-cloudshell/zipco_observability_deployment_verification.json aws-output/zipco-optimization/deployment.json --region us-east-2
python scripts/athena_cost_model.py --benchmark aws-output/zipco-optimization/benchmark.json --deployment aws-output/zipco-optimization/deployment.json --monthly-queries 1000 --price-per-tb 5
```

The calculator rechecks the full run matrix, unique execution IDs, successful matching execution logs, byte and timing consistency, three result rows, stable SQL hashes, and stable/equal result signatures for each equivalent workload pair. It recomputes costs from individual runs rather than trusting summary averages. It rejects the transcribed summary as an input because that file lacks per-query measurements.

This validates consistency of supplied records, not their authenticity or the SQL against live AWS. SHA-256 signatures here represent aggregate outputs, not a complete database integrity proof. The original runner executes the SQL correctness checks in Athena; local tests exercise the acceptance and rejection logic using explicitly synthetic fixtures.

For reviewable public evidence, retrieve the original two JSON objects, preserve their original run IDs, and prepare reviewed copies of the relevant query records. Remove credentials or sensitive metadata if present and record any redactions. Do not fabricate unavailable query IDs, byte measurements, timings, or result signatures. AWS query history availability may be limited; the retained S3 artifacts are the historical source.

## Validation and current completion boundary

```bash
python -m unittest discover -s tests -p 'test_athena_cost_model.py' -v
python scripts/validate_repository.py
```

The calculator and offline regression tests are implemented. Existing SQL correctness gates and S3 execution-record locations are linked above. No new Athena execution, download of private S3 evidence, or AWS invoice comparison was performed for this addition. Publishing exact before/after byte measurements remains dependent on retrieving those existing records.

## Portfolio wording

> Measured an 88.21% reduction in Athena full-history scan volume after CSV-to-Parquet optimization, with equivalent aggregate results reconciled across three uncached runs per strategy. Added reproducible query-cost modeling with explicit workload assumptions, billing minimums, and checks against retained AWS execution records.
