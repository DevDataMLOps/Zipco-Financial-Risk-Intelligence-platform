# ZIPCO Portfolio Demo

## Seven-minute walkthrough

This sequence is designed for an interview, technical review, or stakeholder demonstration. It distinguishes measured AWS outcomes from architectural intent.

### 0:00–0:45 — Frame the problem

Open the [root README](../README.md).

Explain that the source arrived as a one-million-row flat file whose data dictionary described a relational model the file did not actually implement. The project repairs that gap, builds a governed AWS analytical platform, and retains evidence for every implemented phase.

### 0:45–1:40 — Establish data trust

Open [Phase 1](../phases/01-foundation/README.md) and its [architecture and lineage](../phases/01-foundation/architecture-and-lineage.md).

Show these results:

- 1,000,000 source rows and 14 columns were profiled.
- Relational Dataset v2 publishes six entities only after 31/31 rules pass.
- The S3 foundation is private, encrypted, versioned, TLS-only, and lifecycle-managed.

The important decision is that the original source remains immutable while the corrected relational model is published as a new governed version.

### 1:40–2:35 — Show the working data pipeline

Open [Phase 2](../phases/02-glue-etl/README.md) and the [transformation and quality rule catalog](../phases/02-glue-etl/transformation-and-dq-rule-catalog.md).

Point to the AWS result: Glue finished `DEPLOYED_RUN_AND_VERIFIED`, quality status was `PASS`, no records were rejected, and six Snappy Parquet tables were registered. Invalid publication paths are explicit and quarantined rather than silently dropped.

### 2:35–3:25 — Prove optimization with a fair benchmark

Open the [Phase 3 benchmark interpretation](../phases/03-optimization/benchmark-results-and-interpretation.md).

Explain the correctness gate, three uncached iterations per strategy, and identical workload predicates. Then present the measured outcomes:

- CSV to full Parquet reduced scanned bytes by **88.21%**.
- Full Parquet to partition-pruned 2023 Parquet reduced scanned bytes by **95.55%** for that workload.

Frame these as measured workload results, not universal performance guarantees.

### 3:25–4:20 — Turn data into decisions responsibly

Open the [Phase 4 executive dashboard](../phases/04-business-intelligence/dashboard/executive-dashboard.md) and [risk-model explanation](../phases/04-business-intelligence/risk-model-and-explainability.md).

Show that the engine provides transaction, account, and customer scores with component-level reason codes, six decision products, and reconciliation tests. State the responsible-use boundary clearly: this is analyst prioritization on synthetic data, not an automated adverse decision.

### 4:20–5:15 — Demonstrate security and governance

Open [Phase 5](../phases/05-security-governance/README.md) and the [Lake Formation access matrix](../phases/05-security-governance/lake-formation-demo/access-control-matrix.md).

Present the verified controls:

- 24/24 core security controls
- four IAM personas
- 15/15 AWS Config rules deployed
- 18/18 isolated Lake Formation controls
- observed authorized Athena success and expected denied-query failure

Explain that the hybrid-mode proof is isolated so the demonstration does not disrupt existing workloads.

### 5:15–6:20 — Show operations and recovery

Open the [operational dashboard](../phases/06-streaming-resilience/dashboard/README.md).

Walk through the AWS-verified Free-plan result: **20/20** controls, 25/25 valid events curated, 3/3 expected-invalid events quarantined, encrypted raw backup, replay dry run passed, and four metric alarms plus one composite alarm. Make the implementation boundary explicit: native streaming is `NOT CLAIMED` because the account plan rejected Kinesis and Firehose.

### 6:20–7:00 — Close with engineering discipline

Open the [project handoff](PROJECT_HANDOFF.md) and the repository's [validation workflow](../.github/workflows/validate.yml).

Close on four points:

1. Every claimed AWS outcome has a run-specific evidence boundary.
2. Contracts, validation, manifests, and GitHub Actions guard the repository.
3. Known limitations and chargeable services are disclosed.
4. The platform is reproducible without committing credentials or large datasets.

## Reviewer questions and concise answers

**Why create Relational Dataset v2 instead of overwriting the source?**

To preserve lineage. The source is immutable evidence; v2 is an explicit, quality-gated remediation.

**How do you know Parquet and partitions helped?**

The benchmark used correctness reconciliation and three uncached iterations. It measured both format and workload-pruning reductions separately.

**Is the risk engine a machine-learning fraud model?**

No. It is a deterministic, explainable prioritization demonstration on synthetic data, with explicit prohibited-use language.

**Why is Firehose code present if streaming is not claimed?**

It preserves the managed-streaming target design. The verified fallback is separately labelled, deployed, and evidenced so architecture is not confused with runtime proof.

**What would you add next?**

A permitted native stream, approved alarm notification destinations, concurrency/load testing, automated teardown-cost reporting, and a production model-validation process before any real decision use.
