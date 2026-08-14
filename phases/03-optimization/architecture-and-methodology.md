# Architecture and Benchmark Methodology

## Optimization architecture

```mermaid
flowchart TB
    subgraph STORAGE["S3 storage variants"]
        CSV["Validated transactions CSV<br/>row-oriented | text fields"]
        PARQUET["Curated transactions Parquet<br/>columnar | Snappy | typed fields"]
        PARTS["TransactionYear partitions<br/>24 verified values"]
        MARKET["MarketYear partitions<br/>24 verified values"]
    end

    subgraph CATALOG["Glue Data Catalog"]
        CSVDB["zipco_performance_benchmark<br/>isolated CSV benchmark table"]
        PRODDB["zipco_financial_risk<br/>production Parquet catalog"]
    end

    subgraph QUERY["Athena workgroup: zipco-risk-analytics"]
        B01["B01 CSV full"]
        B02["B02 Parquet full"]
        B03["B03 CSV 2023"]
        B04["B04 partitioned Parquet 2023"]
    end

    subgraph MEASURE["Automated measurement"]
        NOREUSE["Result reuse disabled"]
        STATS["bytes scanned | engine ms | total ms"]
        SIGN["ordered-result SHA-256 signature"]
        GATES["repeatability | reconciliation | reduction gates"]
    end

    subgraph OUTPUT["Operational evidence"]
        REPORT["Benchmark JSON + CSV"]
        CW["ZIPCO/Performance metrics"]
        DASH["CloudWatch dashboard"]
        S3E["Versioned S3 evidence"]
    end

    CSV --> CSVDB --> B01
    CSVDB --> B03
    PARQUET --> PRODDB --> B02
    PARTS --> PRODDB --> B04
    MARKET --> PRODDB
    B01 --> NOREUSE
    B02 --> NOREUSE
    B03 --> NOREUSE
    B04 --> NOREUSE
    NOREUSE --> STATS
    NOREUSE --> SIGN
    STATS --> GATES
    SIGN --> GATES
    GATES --> REPORT
    REPORT --> CW --> DASH
    REPORT --> S3E
```

## Execution sequence

```mermaid
sequenceDiagram
    participant R as Deployment runner
    participant G as Glue Data Catalog
    participant A as Athena
    participant S as Amazon S3
    participant C as CloudWatch

    R->>G: Create isolated CSV benchmark database/table
    R->>G: Verify TransactionYear partition key
    R->>G: Count transaction and market partitions
    loop Four strategies x three iterations
        R->>A: Start query with result reuse disabled
        A->>S: Scan CSV or Parquet objects
        A-->>R: Query ID, result rows, scan and timing statistics
        R->>R: Hash ordered result rows
    end
    R->>R: Check repeatability and reconcile paired signatures
    R->>R: Calculate scan reductions
    R->>C: Publish custom performance metrics
    R->>C: Verify dashboard, alarms, logs, and event rules
    R->>S: Upload benchmark JSON, CSV, and deployment evidence
```

## Comparison design

```mermaid
flowchart LR
    FCSV["B01 CSV full"] -->|"same scope and aggregation"| FPQ["B02 Parquet full"]
    FCSV -. "signatures must match" .-> FPQ
    YCSV["B03 CSV 2023"] -->|"same date range and aggregation"| YPQ["B04 Parquet 2023 + partition predicate"]
    YCSV -. "signatures must match" .-> YPQ
    FPQ -->|"measured workload reduction"| YPQ
```

The solid horizontal pairs are correctness comparisons. The full-history pair also provides a direct storage-format comparison. The arrow from full Parquet to partitioned 2023 is the reported workload-level pruning comparison.

## Evidence lineage

```mermaid
flowchart LR
    SQL["Versioned SQL files<br/>with SHA-256"] --> RUNS["12 Athena query executions"]
    RUNS --> RAW["per-run query IDs, rows, signatures,<br/>scan bytes and timing"]
    RAW --> SUMMARY["per-strategy averages, minima and maxima"]
    SUMMARY --> COMP["88.21% and 95.55% comparisons"]
    COMP --> JSON["zipco_athena_performance_benchmark.json"]
    SUMMARY --> CSV["zipco_athena_performance_benchmark.csv"]
    JSON --> VERIFY["zipco_observability_deployment_verification.json"]
    CSV --> VERIFY
    VERIFY --> RUNPREFIX["S3 performance/evidence/run_id=..."]
    VERIFY --> META["S3 metadata/contracts/relational_v2/"]
```

## Controlled scope

The benchmark-only CSV table is isolated in `zipco_performance_benchmark`; it does not change the six-table production Glue contract. All Athena executions use the governed `zipco-risk-analytics` workgroup, and the benchmark SQL is stored under a versioned S3 prefix.

