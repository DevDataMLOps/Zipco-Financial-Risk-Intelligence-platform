# Architecture and Data Lineage

## AWS foundation architecture

```mermaid
flowchart TB
    USER["Engineering workstation / AWS CloudShell"]

    subgraph INPUTS["Inputs"]
        CSV["zipco_bank_data.csv<br/>1,000,000 rows"]
        PDF["DATA DICTIONARY.pdf<br/>entity and field definitions"]
    end

    subgraph ENGINEERING["Dataset engineering"]
        PROFILE["Profiling<br/>shape | schema | nulls | duplicates<br/>distributions | keys | date ranges"]
        RECON["Contract reconciliation<br/>missing fields | broken dependencies<br/>relationship risks"]
        GENERATE["Deterministic relational remediation<br/>ZIPCO Relational Dataset v2"]
        DQ["Data-quality gate<br/>31/31 PASS"]
    end

    subgraph BUCKET["S3: zipco-financial-platform-825999268272-us-east-2"]
        RAW["raw/<br/>immutable flat source"]
        VALID["validated/relational_v2/<br/>6 approved CSV tables"]
        CURATED["curated/<br/>downstream Parquet handoff"]
        ANALYTICS["analytics/<br/>derived products"]
        QUAR["quarantine/<br/>schema | duplicate | rule failures"]
        META["metadata/<br/>contracts | dictionary | verification"]
        RESULTS["athena-results/<br/>query-result staging"]
    end

    subgraph CONTROLS["Bucket controls"]
        PRIVATE["Block all public access"]
        OWNER["Bucket owner enforced"]
        ENCRYPT["SSE-S3 default encryption"]
        TLS["Deny non-TLS requests"]
        VERSION["Versioning enabled"]
        LIFE["Lifecycle and retention rules"]
        HASH["Remote size + SHA-256 verification"]
    end

    USER --> CSV
    USER --> PDF
    CSV --> PROFILE
    PDF --> RECON
    PROFILE --> RECON --> GENERATE --> DQ
    CSV --> RAW
    DQ -->|approved| VALID
    DQ -->|rejected| QUAR
    PROFILE --> META
    RECON --> META
    VALID --> CURATED --> ANALYTICS
    ANALYTICS --> RESULTS
    CONTROLS --- BUCKET
```

## Data lineage and publication gates

```mermaid
flowchart LR
    A["Original flat CSV<br/>SHA-256 recorded"] --> B["Raw S3 object<br/>versioned + encrypted"]
    A --> C["Dataset profile<br/>1M x 14"]
    D["Supplied dictionary<br/>17 defined fields"] --> E["Dictionary reconciliation"]
    C --> E
    E --> F["Findings<br/>5 weak IDs | FD failures<br/>3 missing dictionary fields"]
    F --> G["Contract v1<br/>source truth and constraints"]
    G --> H["Deterministic relational-v2 generation"]
    H --> I["6 normalized tables"]
    I --> J{"31-rule quality gate"}
    J -->|PASS| K["validated/relational_v2/"]
    J -->|FAIL| L["quarantine/"]
    K --> M["Glue/Parquet handoff"]
    G --> N["metadata/contracts/"]
    F --> N
    J --> N
```

## Relational lineage

```mermaid
flowchart LR
    C["customers<br/>100,000"] -->|CustomerID| A["accounts<br/>150,000"]
    A -->|AccountID| T["transactions<br/>1,000,000"]
    T -->|TransactionID| CT["categorized_transactions<br/>1,000,000"]
    TC["transaction_categories<br/>10"] -->|CategoryID| CT
    M["market_data<br/>87,140"]
```

Market data is intentionally isolated. No transaction-to-market edge is shown because none exists in the supplied data dictionary.

## Security and retention map

| Control | Applied behavior | Risk addressed |
|---|---|---|
| Block Public Access | All four settings enabled | Accidental public exposure |
| Ownership | `BucketOwnerEnforced` | ACL ambiguity and cross-owner objects |
| Encryption | `AES256` by default | Unencrypted objects at rest |
| Transport | Explicit deny when `aws:SecureTransport=false` | Plaintext network access |
| Versioning | Enabled | Accidental overwrite and lineage loss |
| Raw lifecycle | Standard-IA at 30 days; Glacier IR at 90 days | Long-term storage cost |
| Quarantine lifecycle | Expire at 365 days | Unbounded rejected-data retention |
| Athena-result lifecycle | Expire at 30 days | Unbounded query-result storage |
| Multipart cleanup | Abort after 7 days | Orphaned upload costs |
| Integrity verification | Remote size and SHA-256 metadata | Truncated or incorrect uploads |
