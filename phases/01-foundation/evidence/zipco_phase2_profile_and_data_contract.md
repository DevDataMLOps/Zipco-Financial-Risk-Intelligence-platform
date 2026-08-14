# ZIPCO Financial Risk Intelligence Platform

## Phase 2 - Dataset Profile, Dictionary Reconciliation, and Data Contract

**Assessment status:** `BLOCKED_FOR_NORMALIZED_CURATED_PUBLICATION`  
**Raw landing status:** `ACCEPTABLE_WITH_LINEAGE`  
**Validated flat status:** `QUARANTINE / DIAGNOSTIC USE ONLY`  
**Profile date:** 2026-08-12

## 1. Executive decision

The CSV is structurally clean but relationally invalid against the supplied data dictionary.

- The full file contains **1,000,000 rows and 14 columns**.
- There are **no nulls, no blank strings, no invalid transaction dates, and no exact duplicate rows**.
- All emails pass a basic format check, all phone values are 14 digits beginning with `234`, all monetary values have at most two decimal places, and all transaction types match the dictionary domain.
- However, the dictionary defines normalized Customers, Accounts, Transactions, TransactionCategories, CategorizedTransactions, and MarketData entities. The CSV is a single flattened extract, omits three dictionary fields, and does not preserve the declared keys.
- Every one of the 10 `CustomerID`, 10 `AccountID`, 10 `TransactionID`, and 10 `MarketDataID` values is associated with contradictory entity attributes. Therefore, **100% of rows are affected by relational-integrity failures**.

The source should be retained unchanged in the raw zone for audit and demonstration. It must not be published as normalized customer, account, transaction, or market-data tables without a corrected upstream extract or explicit re-generation/re-keying strategy.

## 2. Sources and profiling scope

| Source | Observed details |
|---|---|
| `zipco_bank_data.csv` | 154,501,154 bytes; SHA-256 `fe58c2828d44c37a63fed441fedbfcb0c9a8563319f2ab445ad84c7649a51202` |
| `DATA DICTIONARY.pdf` | 2-page A4 PDF; six intended tables; 17 unique documented fields |

The profile scanned all 1,000,000 records. Checks covered shape, inferred types, nulls, blanks, exact row duplicates, field cardinality, key/foreign-key semantics, functional dependencies, date validity and coverage, categorical domains, numeric ranges and quantiles, formatting, and suspicious distribution patterns.

## 3. Dataset shape and completeness

| Metric | Result |
|---|---:|
| Rows | 1,000,000 |
| Columns | 14 |
| Exact duplicate rows | 0 |
| Columns with nulls | 0 |
| Total null values | 0 |
| Blank strings | 0 |
| In-memory profile footprint | 408,557,313 bytes |

### Actual CSV columns

`CustomerID`, `CustomerName`, `EmailAddress`, `PhoneNumber`, `AccountID`, `Balance`, `TransactionID`, `TransactionDate`, `TransactionType`, `Amount`, `CategoryID`, `TransactionDescription`, `MarketDataID`, `Price`

## 4. Dictionary reconciliation

| Dictionary table | Field | Dictionary type | CSV status | Contract decision |
|---|---|---|---|---|
| Customers | `CustomerID` | int | Present, inferred `int64` | `BIGINT`; declared key currently invalid |
| Customers | `CustomerName` | str | Present, string | `STRING`; restricted PII |
| Customers | `EmailAddress` | str | Present, string | `STRING`; restricted PII; format validation |
| Customers | `PhoneNumber` | str | Present, inferred `int64` | **Type mismatch**; ingest as `STRING`, canonicalize to E.164-like form |
| Accounts | `AccountID` | int | Present, inferred `int64` | `BIGINT`; declared key currently invalid |
| Accounts | `CustomerID` | int FK | Present | Account-to-customer dependency fails |
| Accounts | `Balance` | float | Present, inferred `float64` | `DECIMAL(18,2)`; do not use binary float in curated data |
| Transactions | `TransactionID` | int | Present, inferred `int64` | `BIGINT`; declared key currently invalid |
| Transactions | `AccountID` | int FK | Present | Transaction-to-account dependency fails |
| Transactions | `TransactionDate` | datetime | Present as string, date-only | Parse to `DATE`; source has no time-of-day |
| Transactions | `TransactionType` | str | Present | `STRING`; enum is Deposit/Withdrawal/Transfer |
| Transactions | `Amount` | float | Present, inferred `float64` | `DECIMAL(18,2)`; strictly positive in this extract |
| TransactionCategories | `CategoryID` | int | Present | `BIGINT`; dimension cannot be interpreted without name |
| TransactionCategories | `CategoryName` | str | **Missing** | Required upstream for category dimension publication |
| CategorizedTransactions | `TransactionID` | int FK | Present | Bridge cannot be trusted because transaction identity fails |
| CategorizedTransactions | `CategoryID` | int FK | Present | All 100 possible transaction-category pairs occur |
| CategorizedTransactions | `TransactionDescription` | str | Present | `STRING`; transaction-level semantics need clarification |
| MarketData | `MarketDataID` | int | Present | `BIGINT`; declared key currently invalid |
| MarketData | `StockSymbol` | str | **Missing** | Required upstream |
| MarketData | `Price` | float | Present, inferred `float64` | `DECIMAL(18,2)`; unusable without symbol/time identity |
| MarketData | `Timestamp` | datetime | **Missing** | Required upstream |

All 14 CSV fields appear in the dictionary. The missing fields are **`CategoryName`, `StockSymbol`, and `Timestamp`**. The dictionary also does not define how MarketData is related to Transactions, yet market fields are repeated on every flat CSV row. That join semantics must be clarified rather than inferred.

## 5. Cardinality and value distributions

### Identifier and text cardinality

| Field | Distinct values | Distinct rate | Observation |
|---|---:|---:|---|
| `CustomerID` | 10 | 0.001% | Values 101-110; each appears about 100,000 times |
| `CustomerName` | 330,125 | 33.0125% | Far more names than declared customer IDs |
| `EmailAddress` | 513,743 | 51.3743% | 486,257 repeated occurrences |
| `PhoneNumber` | 999,868 | 99.9868% | 132 repeated occurrences |
| `AccountID` | 10 | 0.001% | Values 201-210 |
| `TransactionID` | 10 | 0.001% | Values 301-310; not a usable transaction key |
| `TransactionDate` | 8,714 | 0.8714% | Every calendar day from 2000-01-01 through 2023-11-09 |
| `TransactionType` | 3 | 0.0003% | Near-even split across the allowed domain |
| `CategoryID` | 10 | 0.001% | Values 401-410 |
| `TransactionDescription` | 999,996 | 99.9996% | Only four repeated occurrences beyond first |
| `MarketDataID` | 10 | 0.001% | Values 501-510 |

### Categorical distributions

| Transaction type | Rows | Share |
|---|---:|---:|
| Transfer | 333,881 | 33.3881% |
| Deposit | 333,442 | 33.3442% |
| Withdrawal | 332,677 | 33.2677% |

Email domains are also almost evenly distributed: Gmail 333,956; Hotmail 333,162; Yahoo 332,882. Every email local part exactly matches the corresponding customer name after replacing spaces with underscores.

### Numeric distributions

| Field | Min | P1 | P25 | Median | P75 | P99 | Max | Mean | Invalid/negative/zero |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `Balance` | 100.03 | 200.93 | 2,572.55 | 5,050.62 | 7,521.83 | 9,898.76 | 10,000.00 | 5,049.21 | 0 |
| `Amount` | 1.00 | 101.04 | 2,497.01 | 4,993.49 | 7,498.54 | 9,899.13 | 10,000.00 | 4,997.18 | 0 |
| `Price` | 1.00 | 21.43 | 500.28 | 999.73 | 1,500.59 | 1,980.01 | 2,000.00 | 1,000.21 | 0 |

All three numeric fields have at most two decimal places. There are no standard 1.5-IQR outliers because the values occupy sharply bounded, almost uniform ranges.

### Date distribution

- Valid dates: 1,000,000; invalid or null: 0.
- Minimum: 2000-01-01.
- Maximum: 2023-11-09, which matches the PDF's creation date.
- Distinct dates: 8,714, exactly the number of calendar days in that inclusive range.
- Full years contain roughly 41,450-42,167 rows each; 2023 contains 35,887 because the range stops on November 9.
- Day-of-week counts are almost perfectly even (142,325-143,217 per weekday).

This is appropriate for synthetic load/performance testing, but it is not credible evidence of natural customer or transaction behavior.

## 6. Key and relationship integrity

The dictionary's relational model requires stable functional dependencies. Every declared entity fails them.

| Required dependency | Keys tested | Violating keys | Observed contradiction |
|---|---:|---:|---|
| `CustomerID -> CustomerName` | 10 | 10 | Each ID maps to 70,876-71,523 names |
| `CustomerID -> EmailAddress` | 10 | 10 | Each ID maps to 84,540-85,353 emails |
| `CustomerID -> PhoneNumber` | 10 | 10 | Each ID maps to 99,360-100,294 phones |
| `AccountID -> CustomerID` | 10 | 10 | Every account maps to all 10 customers |
| `AccountID -> Balance` | 10 | 10 | Each account maps to 94,520-95,597 balances |
| `TransactionID -> AccountID` | 10 | 10 | Every transaction ID maps to all 10 accounts |
| `TransactionID -> TransactionDate` | 10 | 10 | Every transaction ID maps to all 8,714 dates |
| `TransactionID -> TransactionType` | 10 | 10 | Every transaction ID maps to all 3 types |
| `TransactionID -> Amount` | 10 | 10 | Each ID maps to 94,659-95,603 amounts |
| `MarketDataID -> Price` | 10 | 10 | Each ID maps to 78,390-79,042 prices |

Additional integrity findings:

- `CustomerID + AccountID` has all 100 possible combinations; 999,900 rows repeat those combinations.
- `TransactionID + CategoryID` has all 100 possible combinations; 999,900 rows repeat those combinations.
- 164,769 of 513,743 distinct emails (32.07%) map to more than one `CustomerID`; some map to all 10 IDs.
- 120 of 999,868 distinct phone numbers map to two `CustomerID` values.
- Because every entity key group is contradictory, selecting the first row, last row, minimum, maximum, or most common attribute would fabricate an entity record.

## 7. Suspicious-value and generation-pattern findings

The following combination strongly suggests independent synthetic random generation. This is an inference, not a provenance claim:

1. Each identifier column contains exactly 10 consecutive values and is nearly uniformly distributed.
2. All 100 possible customer-account and transaction-category combinations occur.
3. Transaction types and email domains are almost exactly one-third each.
4. The date range covers every day from 2000-01-01 through the PDF creation date with near-uniform annual and weekday counts.
5. Balance, amount, and price quantiles closely follow bounded uniform distributions.
6. Names, phones, descriptions, balances, amounts, and prices change independently while IDs repeat.

The dataset is therefore suitable for demonstrating ingestion volume, data-quality detection, quarantine, Parquet conversion, Athena optimization, and monitoring. It is **not suitable as-is for longitudinal customer analytics, account balances, transaction histories, category intelligence, market-price analysis, or risk scoring that assumes stable entity identity**.

## 8. Data-quality findings and disposition

| Rule ID | Severity | Rule | Result | Disposition |
|---|---|---|---|---|
| DQ-SCH-001 | Critical | All 17 dictionary fields are available | **Fail:** 3 missing | Block normalized publication |
| DQ-SCH-002 | High | Source types are contract-compatible | **Fail:** phone inferred numeric; date arrives as string | Cast and validate in the validation layer |
| DQ-CMP-001 | High | Required source fields are non-null/non-blank | Pass | Record metrics |
| DQ-DUP-001 | Medium | Exact source rows are unique | Pass: 0 duplicates | Generate deterministic row hash for idempotency |
| DQ-DOM-001 | High | Transaction type is Deposit/Withdrawal/Transfer | Pass | Reject unknown future values |
| DQ-VAL-001 | High | Balance >= 0; Amount > 0; Price > 0 | Pass | Use decimal types |
| DQ-DATE-001 | High | Transaction date parses and is not future-dated | Pass | Derive transaction year/month |
| DQ-FMT-001 | Medium | Email has valid basic syntax | Pass | Treat as restricted PII |
| DQ-FMT-002 | Medium | Phone is canonical string | **Warn:** numeric source representation | Convert to `+234...` string; never store as number |
| DQ-ENT-001 | Critical | Customer ID identifies one customer | **Fail:** 10/10 IDs inconsistent | Quarantine normalized customers |
| DQ-REL-001 | Critical | Account belongs to one customer | **Fail:** 10/10 accounts map to all customers | Quarantine normalized accounts |
| DQ-ENT-002 | Critical | Transaction ID identifies one transaction | **Fail:** 10/10 IDs inconsistent | Quarantine normalized transactions |
| DQ-REL-002 | Critical | Transaction references one account | **Fail:** every ID maps to all accounts | Quarantine normalized transactions |
| DQ-REF-001 | Critical | Category IDs resolve to category names | **Fail:** `CategoryName` missing | Request category dimension |
| DQ-ENT-003 | Critical | Market data ID identifies one symbol/price/time observation | **Fail** | Block market-data publication |
| DQ-REF-002 | Critical | Market symbol and timestamp are present | **Fail:** both missing | Request upstream fields |
| DQ-SEM-001 | High | Market-to-transaction relationship is defined | **Fail:** dictionary is silent | Require owner clarification |

## 9. Phase 2 data contract v1.0

The machine-readable contract is supplied separately in `zipco_data_contract_v1.yaml`. Its governing decisions are:

### 9.1 Raw landing contract

- Preserve the original file byte-for-byte under `raw/zipco_bank_flat/ingestion_date=YYYY-MM-DD/`.
- Record file hash, size, source name, ingestion timestamp, pipeline run ID, and row count.
- Do not rewrite identifiers, phone numbers, or monetary fields in raw storage.
- Raw acceptance does not imply business validity.

### 9.2 Validated flat contract

- Use a deterministic `source_record_id` hash as the only reliable row identifier.
- Cast IDs to `BIGINT`, phone to `STRING`, transaction date to `DATE`, and monetary values to `DECIMAL(18,2)`.
- Add lineage and DQ columns: `source_file`, `source_row_number`, `pipeline_run_id`, `ingested_at`, `dq_status`, and `dq_error_codes`.
- Preserve original IDs as source attributes. Do not promote them to primary keys while this defect remains.
- Mark all current rows `RELATIONAL_INTEGRITY_FAILED` for normalized-publication purposes.

### 9.3 Target normalized contract

The intended curated model remains:

- `customers(customer_id PK, customer_name, email_address, phone_number)`
- `accounts(account_id PK, customer_id FK, balance)`
- `transactions(transaction_id PK, account_id FK, transaction_date, transaction_type, amount)`
- `transaction_categories(category_id PK, category_name)`
- `categorized_transactions(transaction_id FK, category_id FK, transaction_description, PK(transaction_id, category_id))`
- `market_data(market_data_id PK, stock_symbol, price, market_timestamp)`

Publication requires stable entity dependencies, resolvable foreign keys, and the three missing fields. The market-data relationship to banking events must be explicitly defined before joining it to transactions.

### 9.4 Partitioning decision

For this one-million-row baseline, partition curated transactions by **transaction year only**. The file spans 8,714 individual days; day partitioning would create excessive small partitions for the current volume. Add month partitioning only after scale/query benchmarks demonstrate a benefit and compact Parquet files to a practical size.

## 10. Recommended next action

Preferred remediation is to obtain six normalized source exports that honor the dictionary. If that is unavailable, retain this file as the deliberately defective raw input for the platform's data-quality/quarantine demonstration, then generate a corrected relational synthetic dataset with stable keys for downstream risk analytics.

Do not silently deduplicate on the declared IDs. There is no defensible winner among their contradictory attributes.

