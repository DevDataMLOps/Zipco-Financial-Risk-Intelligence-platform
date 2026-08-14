from __future__ import annotations

import hashlib
import json
import re
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import pandas as pd


ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path(r"C:\Users\USER\Downloads\zipco_bank_data.csv")
OUT = ROOT / "outputs" / "zipco_relational_v2"
DATA = OUT / "data"
SEED = 20260812
RNG = np.random.default_rng(SEED)

N_CUSTOMERS = 100_000
N_ACCOUNTS = 150_000
N_TRANSACTIONS = 1_000_000
START_DATE = pd.Timestamp("2000-01-01")
END_DATE = pd.Timestamp("2023-11-09")
N_DAYS = (END_DATE - START_DATE).days + 1


def sha256(path: Path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def collect_unique_names(count: int):
    names: list[str] = []
    seen: set[str] = set()
    for chunk in pd.read_csv(SOURCE, usecols=["CustomerName"], chunksize=100_000):
        for raw in chunk["CustomerName"].astype(str):
            name = re.sub(r"\s+", " ", raw.strip())
            if name and name not in seen:
                seen.add(name)
                names.append(name)
                if len(names) == count:
                    return names
    raise RuntimeError(f"Source contains fewer than {count:,} unique customer names")


def email_local(name: str):
    local = re.sub(r"[^a-z0-9]+", ".", name.lower()).strip(".")
    return local or "customer"


def write_csv(frame: pd.DataFrame, name: str):
    path = DATA / name
    frame.to_csv(path, index=False, lineterminator="\n")
    return path


def build_customers():
    customer_ids = np.arange(1_000_001, 1_000_001 + N_CUSTOMERS, dtype=np.int64)
    names = collect_unique_names(N_CUSTOMERS)
    domains = np.array(["gmail.com", "hotmail.com", "yahoo.com"], dtype=object)
    emails = [f"{email_local(name)}.{cid}@{domains[i % 3]}" for i, (cid, name) in enumerate(zip(customer_ids, names))]
    phones = [str(23_480_000_000_000 + i) for i in range(N_CUSTOMERS)]
    return pd.DataFrame(
        {
            "CustomerID": customer_ids,
            "CustomerName": names,
            "EmailAddress": emails,
            "PhoneNumber": phones,
        }
    )


def build_accounts(customer_ids: np.ndarray):
    extra_owners = RNG.choice(customer_ids, size=N_ACCOUNTS - N_CUSTOMERS, replace=False)
    owners = np.concatenate([customer_ids, extra_owners])
    RNG.shuffle(owners)
    account_ids = np.arange(2_000_001, 2_000_001 + N_ACCOUNTS, dtype=np.int64)
    balances = np.round(RNG.uniform(100.0, 10_000.0, size=N_ACCOUNTS), 2)
    balances[0], balances[1] = 100.03, 10_000.00
    return pd.DataFrame({"AccountID": account_ids, "CustomerID": owners, "Balance": balances})


def build_transaction_arrays(account_ids: np.ndarray):
    tx_ids = np.arange(3_000_001, 3_000_001 + N_TRANSACTIONS, dtype=np.int64)

    assigned_accounts = np.concatenate(
        [account_ids, RNG.choice(account_ids, size=N_TRANSACTIONS - N_ACCOUNTS, replace=True)]
    )
    RNG.shuffle(assigned_accounts)

    day_offsets = np.concatenate(
        [np.arange(N_DAYS, dtype=np.int32), RNG.integers(0, N_DAYS, size=N_TRANSACTIONS - N_DAYS, dtype=np.int32)]
    )
    RNG.shuffle(day_offsets)
    dates = (START_DATE + pd.to_timedelta(day_offsets, unit="D")).strftime("%Y-%m-%d")

    types = np.concatenate(
        [
            np.repeat("Transfer", 333_881),
            np.repeat("Deposit", 333_442),
            np.repeat("Withdrawal", 332_677),
        ]
    )
    RNG.shuffle(types)

    amounts = np.round(RNG.uniform(1.0, 10_000.0, size=N_TRANSACTIONS), 2)
    amounts[0], amounts[1] = 1.00, 10_000.00

    categories = np.empty(N_TRANSACTIONS, dtype=np.int16)
    mappings = {
        "Deposit": (np.array([401, 402, 403]), np.array([0.70, 0.20, 0.10])),
        "Withdrawal": (np.array([404, 405, 406, 407, 408]), np.array([0.30, 0.20, 0.22, 0.16, 0.12])),
        "Transfer": (np.array([409, 410]), np.array([0.58, 0.42])),
    }
    for tx_type, (choices, probabilities) in mappings.items():
        mask = types == tx_type
        categories[mask] = RNG.choice(choices, size=int(mask.sum()), p=probabilities)

    transactions = pd.DataFrame(
        {
            "TransactionID": tx_ids,
            "AccountID": assigned_accounts,
            "TransactionDate": dates,
            "TransactionType": types,
            "Amount": amounts,
        }
    )
    return transactions, categories


def build_categorized_transactions(transaction_ids: np.ndarray, categories: np.ndarray):
    templates = {
        401: "Payroll deposit from employer batch",
        402: "Investment income distribution",
        403: "Merchant refund received",
        404: "Grocery and household purchase",
        405: "Utility service payment",
        406: "Housing rent or mortgage payment",
        407: "Transportation expense",
        408: "Entertainment purchase",
        409: "Transfer between ZIPCO accounts",
        410: "Transfer to external institution",
    }
    descriptions = [f"{templates[int(category)]} REF-{int(tx_id):09d}" for tx_id, category in zip(transaction_ids, categories)]
    return pd.DataFrame(
        {
            "TransactionID": transaction_ids,
            "CategoryID": categories.astype(np.int64),
            "TransactionDescription": descriptions,
        }
    )


def build_categories():
    return pd.DataFrame(
        {
            "CategoryID": np.arange(401, 411, dtype=np.int64),
            "CategoryName": [
                "Salary",
                "Investment Income",
                "Refund",
                "Groceries",
                "Utilities",
                "Housing",
                "Transportation",
                "Entertainment",
                "Internal Transfer",
                "External Transfer",
            ],
        }
    )


def build_market_data():
    symbols = ["AAPL", "AMZN", "GOOGL", "JPM", "META", "MSFT", "NFLX", "NVDA", "TSLA", "WMT"]
    start_prices = [28.4, 3.0, 2.5, 32.0, 38.0, 36.0, 10.0, 1.0, 1.5, 52.0]
    all_days = pd.date_range(START_DATE, END_DATE, freq="D")
    frames = []
    next_id = 5_000_001
    for symbol, start_price in zip(symbols, start_prices):
        daily_returns = RNG.normal(0.00025, 0.018, size=N_DAYS)
        prices = np.round(start_price * np.exp(np.cumsum(daily_returns)), 2)
        prices = np.maximum(prices, 0.01)
        ids = np.arange(next_id, next_id + N_DAYS, dtype=np.int64)
        next_id += N_DAYS
        frames.append(
            pd.DataFrame(
                {
                    "MarketDataID": ids,
                    "StockSymbol": symbol,
                    "Price": prices,
                    "Timestamp": all_days.strftime("%Y-%m-%dT16:00:00Z"),
                }
            )
        )
    return pd.concat(frames, ignore_index=True)


def full_validation(paths: dict[str, Path]):
    customers = pd.read_csv(paths["customers"], dtype={"PhoneNumber": "string"})
    accounts = pd.read_csv(paths["accounts"])
    transactions = pd.read_csv(paths["transactions"])
    categories = pd.read_csv(paths["transaction_categories"])
    bridge = pd.read_csv(paths["categorized_transactions"])
    market = pd.read_csv(paths["market_data"])

    allowed_types = {"Deposit", "Withdrawal", "Transfer"}
    allowed_by_type = {
        "Deposit": {401, 402, 403},
        "Withdrawal": {404, 405, 406, 407, 408},
        "Transfer": {409, 410},
    }
    tx_category = transactions[["TransactionID", "TransactionType"]].merge(
        bridge[["TransactionID", "CategoryID"]], on="TransactionID", how="left", validate="one_to_one"
    )
    compatible = tx_category.apply(lambda row: row["CategoryID"] in allowed_by_type[row["TransactionType"]], axis=1)
    parsed_dates = pd.to_datetime(transactions["TransactionDate"], errors="coerce")
    market_ts = pd.to_datetime(market["Timestamp"], errors="coerce", utc=True)

    checks = [
        ("DQ-V2-001", "customers row count", len(customers) == N_CUSTOMERS, len(customers), N_CUSTOMERS),
        ("DQ-V2-002", "accounts row count", len(accounts) == N_ACCOUNTS, len(accounts), N_ACCOUNTS),
        ("DQ-V2-003", "transactions row count", len(transactions) == N_TRANSACTIONS, len(transactions), N_TRANSACTIONS),
        ("DQ-V2-004", "category row count", len(categories) == 10, len(categories), 10),
        ("DQ-V2-005", "categorized transaction row count", len(bridge) == N_TRANSACTIONS, len(bridge), N_TRANSACTIONS),
        ("DQ-V2-006", "market data row count", len(market) == 10 * N_DAYS, len(market), 10 * N_DAYS),
        ("DQ-V2-010", "customer primary key", customers["CustomerID"].is_unique and customers["CustomerID"].notna().all(), int(customers["CustomerID"].nunique()), N_CUSTOMERS),
        ("DQ-V2-011", "account primary key", accounts["AccountID"].is_unique and accounts["AccountID"].notna().all(), int(accounts["AccountID"].nunique()), N_ACCOUNTS),
        ("DQ-V2-012", "transaction primary key", transactions["TransactionID"].is_unique and transactions["TransactionID"].notna().all(), int(transactions["TransactionID"].nunique()), N_TRANSACTIONS),
        ("DQ-V2-013", "category primary key", categories["CategoryID"].is_unique and categories["CategoryID"].notna().all(), int(categories["CategoryID"].nunique()), 10),
        ("DQ-V2-014", "categorized transaction composite key", not bridge.duplicated(["TransactionID", "CategoryID"]).any(), int(bridge.drop_duplicates(["TransactionID", "CategoryID"]).shape[0]), N_TRANSACTIONS),
        ("DQ-V2-015", "market data primary key", market["MarketDataID"].is_unique and market["MarketDataID"].notna().all(), int(market["MarketDataID"].nunique()), 10 * N_DAYS),
        ("DQ-V2-020", "account customer FK", accounts["CustomerID"].isin(customers["CustomerID"]).all(), int((~accounts["CustomerID"].isin(customers["CustomerID"])).sum()), 0),
        ("DQ-V2-021", "transaction account FK", transactions["AccountID"].isin(accounts["AccountID"]).all(), int((~transactions["AccountID"].isin(accounts["AccountID"])).sum()), 0),
        ("DQ-V2-022", "bridge transaction FK", bridge["TransactionID"].isin(transactions["TransactionID"]).all(), int((~bridge["TransactionID"].isin(transactions["TransactionID"])).sum()), 0),
        ("DQ-V2-023", "bridge category FK", bridge["CategoryID"].isin(categories["CategoryID"]).all(), int((~bridge["CategoryID"].isin(categories["CategoryID"])).sum()), 0),
        ("DQ-V2-030", "customer functional dependency", customers.groupby("CustomerID").agg({"CustomerName": "nunique", "EmailAddress": "nunique", "PhoneNumber": "nunique"}).max().max() == 1, 0, 0),
        ("DQ-V2-031", "account functional dependency", accounts.groupby("AccountID").agg({"CustomerID": "nunique", "Balance": "nunique"}).max().max() == 1, 0, 0),
        ("DQ-V2-032", "transaction functional dependency", transactions.groupby("TransactionID").agg({"AccountID": "nunique", "TransactionDate": "nunique", "TransactionType": "nunique", "Amount": "nunique"}).max().max() == 1, 0, 0),
        ("DQ-V2-033", "market data functional dependency", market.groupby("MarketDataID").agg({"StockSymbol": "nunique", "Price": "nunique", "Timestamp": "nunique"}).max().max() == 1, 0, 0),
        ("DQ-V2-040", "transaction type domain", set(transactions["TransactionType"].unique()) == allowed_types, sorted(transactions["TransactionType"].unique().tolist()), sorted(allowed_types)),
        ("DQ-V2-041", "transaction-category compatibility", bool(compatible.all()), int((~compatible).sum()), 0),
        ("DQ-V2-042", "numeric ranges", bool((accounts["Balance"] >= 0).all() and (transactions["Amount"] > 0).all() and (market["Price"] > 0).all()), 0, 0),
        ("DQ-V2-043", "transaction date validity", parsed_dates.notna().all() and parsed_dates.min() == START_DATE and parsed_dates.max() == END_DATE and parsed_dates.nunique() == N_DAYS, [str(parsed_dates.min().date()), str(parsed_dates.max().date()), int(parsed_dates.nunique())], [str(START_DATE.date()), str(END_DATE.date()), N_DAYS]),
        ("DQ-V2-044", "market timestamp validity", market_ts.notna().all() and market_ts.dt.date.min() == START_DATE.date() and market_ts.dt.date.max() == END_DATE.date(), [str(market_ts.min()), str(market_ts.max())], ["valid", "full range"]),
        ("DQ-V2-045", "required values complete", not any(frame.isna().any().any() for frame in [customers, accounts, transactions, categories, bridge, market]), 0, 0),
        ("DQ-V2-046", "customer emails unique", customers["EmailAddress"].is_unique, int(customers["EmailAddress"].duplicated().sum()), 0),
        ("DQ-V2-047", "customer phones unique and canonical", customers["PhoneNumber"].is_unique and customers["PhoneNumber"].str.fullmatch(r"234\d{11}").all(), int(customers["PhoneNumber"].duplicated().sum()), 0),
        ("DQ-V2-048", "every account has a transaction", accounts["AccountID"].isin(transactions["AccountID"]).all(), int((~accounts["AccountID"].isin(transactions["AccountID"])).sum()), 0),
        ("DQ-V2-049", "one category per transaction", bridge["TransactionID"].nunique() == N_TRANSACTIONS and len(bridge) == N_TRANSACTIONS, int(bridge["TransactionID"].nunique()), N_TRANSACTIONS),
        ("DQ-V2-050", "symbol timestamp uniqueness", not market.duplicated(["StockSymbol", "Timestamp"]).any(), int(market.drop_duplicates(["StockSymbol", "Timestamp"]).shape[0]), 10 * N_DAYS),
    ]

    results = [
        {"rule_id": rule_id, "rule": rule, "status": "PASS" if passed else "FAIL", "actual": actual, "expected": expected}
        for rule_id, rule, passed, actual, expected in checks
    ]
    failures = [result for result in results if result["status"] == "FAIL"]
    distributions = {
        "transaction_type": {str(k): int(v) for k, v in transactions["TransactionType"].value_counts().items()},
        "category": {str(k): int(v) for k, v in bridge["CategoryID"].value_counts().sort_index().items()},
        "accounts_per_customer": {str(int(k)): int(v) for k, v in accounts.groupby("CustomerID").size().value_counts().sort_index().items()},
        "transactions_per_account": {
            "min": int(transactions.groupby("AccountID").size().min()),
            "median": float(transactions.groupby("AccountID").size().median()),
            "max": int(transactions.groupby("AccountID").size().max()),
        },
        "transaction_amount": {
            "min": float(transactions["Amount"].min()),
            "median": float(transactions["Amount"].median()),
            "mean": float(transactions["Amount"].mean()),
            "max": float(transactions["Amount"].max()),
        },
        "account_balance": {
            "min": float(accounts["Balance"].min()),
            "median": float(accounts["Balance"].median()),
            "mean": float(accounts["Balance"].mean()),
            "max": float(accounts["Balance"].max()),
        },
    }
    return results, failures, distributions


def write_contract():
    contract = """contract_version: "2.0.0"
contract_status: "validated"
dataset: "zipco_relational_v2"
classification: "synthetic_financial_data"
generation:
  seed: 20260812
  derived_from: "zipco_bank_data.csv distribution profile and unique synthetic names"
  statement: "This is a deterministic relational remediation dataset, not a reconstruction of real customer history."
tables:
  customers:
    file: "data/customers.csv"
    primary_key: [CustomerID]
    fields:
      CustomerID: "BIGINT NOT NULL"
      CustomerName: "STRING NOT NULL"
      EmailAddress: "STRING NOT NULL UNIQUE"
      PhoneNumber: "STRING NOT NULL UNIQUE"
  accounts:
    file: "data/accounts.csv"
    primary_key: [AccountID]
    foreign_keys: ["CustomerID -> customers.CustomerID"]
    fields:
      AccountID: "BIGINT NOT NULL"
      CustomerID: "BIGINT NOT NULL"
      Balance: "DECIMAL(18,2) NOT NULL CHECK (Balance >= 0)"
  transactions:
    file: "data/transactions.csv"
    primary_key: [TransactionID]
    foreign_keys: ["AccountID -> accounts.AccountID"]
    partitioning: [TransactionYear]
    fields:
      TransactionID: "BIGINT NOT NULL"
      AccountID: "BIGINT NOT NULL"
      TransactionDate: "DATE NOT NULL"
      TransactionType: "STRING NOT NULL ENUM(Deposit,Withdrawal,Transfer)"
      Amount: "DECIMAL(18,2) NOT NULL CHECK (Amount > 0)"
  transaction_categories:
    file: "data/transaction_categories.csv"
    primary_key: [CategoryID]
    fields:
      CategoryID: "BIGINT NOT NULL"
      CategoryName: "STRING NOT NULL UNIQUE"
  categorized_transactions:
    file: "data/categorized_transactions.csv"
    primary_key: [TransactionID, CategoryID]
    foreign_keys:
      - "TransactionID -> transactions.TransactionID"
      - "CategoryID -> transaction_categories.CategoryID"
    cardinality: "Exactly one category per transaction in v2"
    fields:
      TransactionID: "BIGINT NOT NULL"
      CategoryID: "BIGINT NOT NULL"
      TransactionDescription: "STRING NOT NULL"
  market_data:
    file: "data/market_data.csv"
    primary_key: [MarketDataID]
    alternate_key: [StockSymbol, Timestamp]
    relationship_note: "Standalone market reference series; not joined to transactions because the supplied dictionary defines no relationship."
    fields:
      MarketDataID: "BIGINT NOT NULL"
      StockSymbol: "STRING NOT NULL"
      Price: "DECIMAL(18,2) NOT NULL CHECK (Price > 0)"
      Timestamp: "TIMESTAMP NOT NULL"
publication:
  raw_v1: "retain_unchanged"
  validated_v2: "approved_after_all_dq_rules_pass"
  curated_parquet: "pending_glue_phase"
"""
    path = OUT / "zipco_data_contract_v2.yaml"
    path.write_text(contract, encoding="utf-8")
    return path


def write_readme(manifest: dict, results: list[dict], distributions: dict):
    passed = sum(result["status"] == "PASS" for result in results)
    content = f"""# ZIPCO Relational Dataset v2

## Status

**VALIDATED - {passed}/{len(results)} data-quality rules passed**

This deterministic synthetic dataset repairs the relational defects found in the original one-million-row flat CSV. It is not a reconstruction of real customer history. The original source remains unchanged in the S3 raw zone for lineage and quarantine evidence.

## Contents

| Table | Rows | Primary key | Purpose |
|---|---:|---|---|
| Customers | {manifest['tables']['customers']['rows']:,} | CustomerID | Stable customer identity |
| Accounts | {manifest['tables']['accounts']['rows']:,} | AccountID | One owner per account |
| Transactions | {manifest['tables']['transactions']['rows']:,} | TransactionID | Unique financial events |
| TransactionCategories | {manifest['tables']['transaction_categories']['rows']:,} | CategoryID | Ten named categories |
| CategorizedTransactions | {manifest['tables']['categorized_transactions']['rows']:,} | TransactionID + CategoryID | One valid category per event |
| MarketData | {manifest['tables']['market_data']['rows']:,} | MarketDataID | Ten-symbol daily reference series |

## Preserved source characteristics

- One million transactions.
- Date coverage: 2000-01-01 through 2023-11-09, including every calendar date.
- Transaction-type totals: Transfer {distributions['transaction_type']['Transfer']:,}; Deposit {distributions['transaction_type']['Deposit']:,}; Withdrawal {distributions['transaction_type']['Withdrawal']:,}.
- Amount range: $1.00-$10,000.00.
- Balance range: $100.03-$10,000.00.

## Corrected characteristics

- Stable, unique primary keys.
- Zero orphan foreign keys.
- One customer per account.
- One account/date/type/amount definition per transaction.
- Category names supplied and category/type combinations enforced.
- Stock symbols and market timestamps supplied.
- Phone numbers retained as strings.
- Monetary fields constrained to two decimals.

## Publication path

Upload these CSVs to `validated/relational_v2/`. Conversion to partitioned Parquet belongs to the Glue phase; do not label the CSVs as curated Parquet.
"""
    path = OUT / "README.md"
    path.write_text(content, encoding="utf-8")
    return path


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    DATA.mkdir(parents=True, exist_ok=True)

    customers = build_customers()
    accounts = build_accounts(customers["CustomerID"].to_numpy())
    transactions, category_ids = build_transaction_arrays(accounts["AccountID"].to_numpy())
    categories = build_categories()
    bridge = build_categorized_transactions(transactions["TransactionID"].to_numpy(), category_ids)
    market = build_market_data()

    frames = {
        "customers": (customers, "customers.csv"),
        "accounts": (accounts, "accounts.csv"),
        "transactions": (transactions, "transactions.csv"),
        "transaction_categories": (categories, "transaction_categories.csv"),
        "categorized_transactions": (bridge, "categorized_transactions.csv"),
        "market_data": (market, "market_data.csv"),
    }
    paths = {name: write_csv(frame, filename) for name, (frame, filename) in frames.items()}

    del customers, accounts, transactions, categories, bridge, market, frames, category_ids

    results, failures, distributions = full_validation(paths)
    table_manifest = {}
    for name, path in paths.items():
        with path.open("r", encoding="utf-8") as stream:
            header = stream.readline().strip().split(",")
        row_count = sum(1 for _ in path.open("r", encoding="utf-8")) - 1
        table_manifest[name] = {
            "file": f"data/{path.name}",
            "rows": row_count,
            "columns": header,
            "bytes": path.stat().st_size,
            "sha256": sha256(path),
        }

    manifest = {
        "dataset": "ZIPCO Relational Dataset v2",
        "version": "2.0.0",
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "generation_seed": SEED,
        "classification": "synthetic_financial_data",
        "source_lineage": {
            "source_file": SOURCE.name,
            "source_sha256": sha256(SOURCE),
            "use": "distribution profile and unique synthetic names only",
            "original_ids_reused": False,
        },
        "tables": table_manifest,
        "quality": {
            "status": "PASS" if not failures else "FAIL",
            "rules_total": len(results),
            "rules_passed": sum(result["status"] == "PASS" for result in results),
            "rules_failed": len(failures),
        },
    }
    (OUT / "generation_manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    quality = {
        "dataset": manifest["dataset"],
        "version": manifest["version"],
        "validated_at_utc": datetime.now(timezone.utc).isoformat(),
        "overall_status": "PASS" if not failures else "FAIL",
        "rules": results,
        "distributions": distributions,
    }
    (OUT / "data_quality_results.json").write_text(json.dumps(quality, indent=2), encoding="utf-8")
    write_contract()
    write_readme(manifest, results, distributions)
    print(json.dumps({"output": str(OUT), "quality": manifest["quality"], "tables": table_manifest}, indent=2))
    if failures:
        raise SystemExit(2)


if __name__ == "__main__":
    main()
