# Transformation and Data-Quality Rule Catalog

## Pipeline-wide controls

| Stage | Control | Failure behavior |
|---|---|---|
| Preflight | Verify source SHA-256 metadata | Stop deployment before Glue starts |
| Preflight | Verify source object bytes | Stop deployment before Glue starts |
| Preflight | Verify declared row metadata | Stop deployment before Glue starts |
| Preflight | Verify dataset version is `2.0.0` | Stop deployment before Glue starts |
| Preflight | Verify source objects use SSE-S3 | Stop deployment before Glue starts |
| Ingestion | Require exact column names and order | Raise `SCHEMA_MISMATCH` and fail the job |
| Population | Match six locked table counts | Block curated publication |
| Reject threshold | Overall reject rate must be no more than 1% | Block curated publication |
| Relationship completeness | Every valid transaction has a category | Block curated publication |
| Relationship completeness | Every valid account has a transaction | Block curated publication |

## Standard transformations

| Table | Transformation |
|---|---|
| `customers` | Cast `CustomerID`; trim name and phone; lowercase and trim email |
| `accounts` | Cast identifiers; cast `Balance` to `DECIMAL(18,2)` |
| `transactions` | Cast identifiers; parse ISO date; trim type; cast `Amount` to `DECIMAL(18,2)`; derive `TransactionYear` |
| `transaction_categories` | Cast `CategoryID`; trim `CategoryName` |
| `categorized_transactions` | Cast both identifiers; trim description |
| `market_data` | Cast ID; uppercase and trim symbol; cast `Price` to `DECIMAL(18,2)`; parse ISO timestamp; derive `MarketYear` |

## Row-level error rules

The implementation contains 37 rule applications. `DUPLICATE_PRIMARY_KEY` is deliberately reused across the entity tables so downstream quality reporting has a consistent primary-key error code.

### Customers

| Error code | Condition |
|---|---|
| `INVALID_CUSTOMER_ID` | `CustomerID` cannot be cast to a non-null identifier |
| `MISSING_CUSTOMER_NAME` | Name is null or empty after trimming |
| `INVALID_EMAIL` | Email is null or fails the contracted email pattern |
| `INVALID_PHONE` | Phone is null or fails canonical `234` plus 11 digits |
| `DUPLICATE_PRIMARY_KEY` | `CustomerID` occurs more than once |
| `DUPLICATE_EMAIL` | Normalized email occurs more than once |
| `DUPLICATE_PHONE` | Canonical phone occurs more than once |

### Accounts

| Error code | Condition |
|---|---|
| `INVALID_ACCOUNT_ID` | `AccountID` cannot be cast to a non-null identifier |
| `INVALID_CUSTOMER_ID` | `CustomerID` cannot be cast to a non-null identifier |
| `INVALID_BALANCE` | Balance is null, uncastable, or negative |
| `DUPLICATE_PRIMARY_KEY` | `AccountID` occurs more than once |
| `ORPHAN_CUSTOMER_ID` | Customer reference is absent from valid customers |

### Transactions

| Error code | Condition |
|---|---|
| `INVALID_TRANSACTION_ID` | `TransactionID` cannot be cast to a non-null identifier |
| `INVALID_ACCOUNT_ID` | `AccountID` cannot be cast to a non-null identifier |
| `INVALID_TRANSACTION_DATE` | Date cannot be parsed as `yyyy-MM-dd` |
| `INVALID_TRANSACTION_TYPE` | Type is null or outside Deposit, Withdrawal, Transfer |
| `INVALID_AMOUNT` | Amount is null, uncastable, zero, or negative |
| `DUPLICATE_PRIMARY_KEY` | `TransactionID` occurs more than once |
| `ORPHAN_ACCOUNT_ID` | Account reference is absent from valid accounts |

### Transaction categories

| Error code | Condition |
|---|---|
| `INVALID_CATEGORY_ID` | `CategoryID` cannot be cast to a non-null identifier |
| `MISSING_CATEGORY_NAME` | Name is null or empty after trimming |
| `DUPLICATE_PRIMARY_KEY` | `CategoryID` occurs more than once |
| `DUPLICATE_CATEGORY_NAME` | Normalized category name occurs more than once |

### Categorized transactions

| Error code | Condition |
|---|---|
| `INVALID_TRANSACTION_ID` | `TransactionID` cannot be cast to a non-null identifier |
| `INVALID_CATEGORY_ID` | `CategoryID` cannot be cast to a non-null identifier |
| `MISSING_TRANSACTION_DESCRIPTION` | Description is null or empty after trimming |
| `DUPLICATE_PRIMARY_KEY` | Composite `TransactionID, CategoryID` occurs more than once |
| `MULTIPLE_CATEGORIES_FOR_TRANSACTION` | A transaction maps to more than one category |
| `ORPHAN_TRANSACTION_ID` | Transaction reference is absent from valid transactions |
| `ORPHAN_CATEGORY_ID` | Category reference is absent from valid categories |
| `INCOMPATIBLE_TRANSACTION_CATEGORY` | Category is not allowed for the transaction type |

Compatibility pairs enforced by the job:

| Transaction type | Allowed category IDs |
|---|---|
| Deposit | 401, 402, 403 |
| Withdrawal | 404, 405, 406, 407, 408 |
| Transfer | 409, 410 |

### Market data

| Error code | Condition |
|---|---|
| `INVALID_MARKET_DATA_ID` | `MarketDataID` cannot be cast to a non-null identifier |
| `INVALID_STOCK_SYMBOL` | Symbol is null or fails the uppercase symbol pattern |
| `INVALID_PRICE` | Price is null, uncastable, zero, or negative |
| `INVALID_MARKET_TIMESTAMP` | Timestamp cannot be parsed as contracted ISO time |
| `DUPLICATE_PRIMARY_KEY` | `MarketDataID` occurs more than once |
| `DUPLICATE_SYMBOL_TIMESTAMP` | The symbol/timestamp alternate key occurs more than once |

## Quality summary contract

Each run writes a JSON summary containing:

- Dataset and version
- Glue job and pipeline run identifiers
- UTC processing timestamp
- Source, curated, quarantine, and quality locations
- Overall status and publication decision
- Maximum and actual reject rates
- Total received and rejected records
- Critical cross-table relationship results
- Row-count mismatches
- Per-table received, expected, valid, rejected, reject-rate, and error-code counts
- Output format, compression, and partitioning

## Quarantine contract

Rejected records preserve:

| Field | Purpose |
|---|---|
| `dataset` | Identifies the failed table |
| `original_record` | Preserves the input fields as JSON |
| `error_codes` | Supports multiple pipe-delimited failures per record |
| `source_file` | Provides S3 lineage |
| `pipeline_run_id` | Connects the record to its execution |
| `processed_at` | Records the UTC processing time |

## Verified expected run

| Measure | Result |
|---|---:|
| Runtime quality status | PASS |
| Publication allowed | Yes |
| Total rejected | 0 |
| Crawler result | SUCCEEDED |
| Catalog tables | 6 |

