# Pipeline Architecture and Data Lineage

## AWS Glue working pipeline

```mermaid
flowchart TB
    ENGINEER["Engineer using AWS CloudShell"]
    CFN["CloudFormation stack<br/>zipco-glue-relational-v2"]

    subgraph S3SOURCE["S3 validated zone"]
        FILES["customers | accounts | transactions<br/>transaction_categories<br/>categorized_transactions | market_data"]
        GM["generation_manifest.json"]
    end

    subgraph INFRA["Managed Glue resources"]
        ROLE["Least-privilege IAM role"]
        SECURITY["Glue security configuration<br/>S3 encryption enabled"]
        JOB["Glue 5.1 Spark job<br/>2 x G.1X | autoscaling"]
        LOGS["Continuous CloudWatch logs<br/>metrics + observability"]
        CRAWLER["Curated crawler"]
        DB["Data Catalog database<br/>zipco_financial_risk"]
    end

    subgraph S3OUTPUT["S3 controlled outputs"]
        CURATED["curated/relational_v2/<br/>six Parquet datasets"]
        QUAR["quarantine/relational_v2/run_id=..."]
        QUALITY["quality/relational_v2/run_id=.../summary.json"]
        LATEST["quality/relational_v2/latest.json"]
        EVIDENCE["metadata/contracts/relational_v2/<br/>deployment verification"]
    end

    ENGINEER --> CFN
    CFN --> ROLE
    CFN --> SECURITY
    CFN --> JOB
    CFN --> CRAWLER
    CFN --> DB
    FILES --> JOB
    GM --> JOB
    ROLE --> JOB
    SECURITY --> JOB
    JOB --> LOGS
    JOB --> CURATED
    JOB --> QUAR
    JOB --> QUALITY
    JOB --> LATEST
    CURATED --> CRAWLER --> DB
    ENGINEER --> EVIDENCE
```

## Validation and publication decision flow

```mermaid
flowchart TD
    START["Read one contracted CSV table as strings"] --> HEADER{"Exact header and order?"}
    HEADER -->|"No"| STOP1["Fail job: SCHEMA_MISMATCH"]
    HEADER -->|"Yes"| CAST["Trim, normalize, and cast typed fields"]
    CAST --> ROWDQ["Apply row rules<br/>required | regex | ranges | domains | keys"]
    ROWDQ --> RELDQ["Apply relational rules<br/>foreign keys | compatibility | cardinality"]
    RELDQ --> SPLIT{"Errors attached?"}
    SPLIT -->|"Yes"| REJECT["Structured quarantine projection"]
    SPLIT -->|"No"| VALID["Valid record set"]
    REJECT --> METRICS["Aggregate table and run metrics"]
    VALID --> METRICS
    METRICS --> GATE{"Reject rate <= 1% AND<br/>row counts match AND<br/>critical relationships pass?"}
    GATE -->|"No"| STOP2["Write quality evidence<br/>then block curated publication"]
    GATE -->|"Yes"| PARQUET["Write approved Snappy Parquet"]
    PARQUET --> CRAWL["Run crawler and verify exact catalog set"]
    CRAWL --> READY["Athena-ready curated layer"]
```

## Source-to-curated lineage

```mermaid
flowchart LR
    CCSV["customers.csv<br/>100,000"] --> CTRANS["cast IDs | trim names<br/>lowercase emails | validate phone"] --> CPQ["customers Parquet"]
    ACSV["accounts.csv<br/>150,000"] --> ATRANS["cast IDs and balance<br/>validate CustomerID FK"] --> APQ["accounts Parquet"]
    TCSV["transactions.csv<br/>1,000,000"] --> TTRANS["parse date | cast amount<br/>validate AccountID FK<br/>derive TransactionYear"] --> TPQ["transactions Parquet<br/>partitioned by year"]
    KCSV["transaction_categories.csv<br/>10"] --> KTRANS["cast ID | trim name<br/>validate uniqueness"] --> KPQ["transaction_categories Parquet"]
    BCSV["categorized_transactions.csv<br/>1,000,000"] --> BTRANS["validate both FKs<br/>one category per transaction<br/>type/category compatibility"] --> BPQ["categorized_transactions Parquet"]
    MCSV["market_data.csv<br/>87,140"] --> MTRANS["parse timestamp | cast price<br/>uppercase symbol<br/>derive MarketYear"] --> MPQ["market_data Parquet<br/>partitioned by year"]
```

## Relational enforcement map

```mermaid
erDiagram
    CUSTOMERS ||--|{ ACCOUNTS : "CustomerID validated"
    ACCOUNTS ||--|{ TRANSACTIONS : "AccountID validated"
    TRANSACTIONS ||--|| CATEGORIZED_TRANSACTIONS : "TransactionID validated"
    TRANSACTION_CATEGORIES ||--o{ CATEGORIZED_TRANSACTIONS : "CategoryID validated"

    CUSTOMERS {
        bigint CustomerID PK
        string EmailAddress UK
        string PhoneNumber UK
    }
    ACCOUNTS {
        bigint AccountID PK
        bigint CustomerID FK
        decimal Balance
    }
    TRANSACTIONS {
        bigint TransactionID PK
        bigint AccountID FK
        date TransactionDate
        int TransactionYear PARTITION
    }
    TRANSACTION_CATEGORIES {
        bigint CategoryID PK
        string CategoryName UK
    }
    CATEGORIZED_TRANSACTIONS {
        bigint TransactionID PK,FK
        bigint CategoryID PK,FK
    }
    MARKET_DATA {
        bigint MarketDataID PK
        string StockSymbol UK
        timestamp Timestamp UK
        int MarketYear PARTITION
    }
```

`MARKET_DATA` remains intentionally standalone because the supplied data dictionary defines no valid key relating market observations to banking transactions.

## Operational evidence flow

```mermaid
flowchart LR
    RUN["Glue job run ID"] --> SUMMARY["Quality summary by run_id"]
    RUN --> QUAR["Quarantine records or NO_REJECTS marker"]
    RUN --> LOGS["CloudWatch continuous logs and metrics"]
    SUMMARY --> LATEST["latest.json pointer"]
    SUMMARY --> VERIFY["Deployment verification JSON"]
    CRAWLER["Crawler status and catalog table list"] --> VERIFY
    PARQUET["Per-table Parquet-object existence checks"] --> VERIFY
    VERIFY --> S3["Versioned evidence in S3 metadata prefix"]
```

