from __future__ import annotations

import json
import sys
import uuid
from datetime import datetime, timezone

import boto3
from awsglue.context import GlueContext
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from pyspark.storagelevel import StorageLevel
from pyspark.sql import DataFrame, Window
from pyspark.sql import functions as F
from pyspark.sql import types as T


ARGUMENTS = getResolvedOptions(
    sys.argv,
    [
        "JOB_NAME",
        "BUCKET",
        "SOURCE_PREFIX",
        "CURATED_PREFIX",
        "QUARANTINE_PREFIX",
        "QUALITY_PREFIX",
        "PIPELINE_RUN_ID",
        "MAX_REJECT_RATE",
    ],
)

BUCKET = ARGUMENTS["BUCKET"]
SOURCE_PREFIX = ARGUMENTS["SOURCE_PREFIX"].strip("/")
CURATED_PREFIX = ARGUMENTS["CURATED_PREFIX"].strip("/")
QUARANTINE_PREFIX = ARGUMENTS["QUARANTINE_PREFIX"].strip("/")
QUALITY_PREFIX = ARGUMENTS["QUALITY_PREFIX"].strip("/")
MAX_REJECT_RATE = float(ARGUMENTS["MAX_REJECT_RATE"])
RUN_ID = (
    ARGUMENTS["PIPELINE_RUN_ID"]
    if ARGUMENTS["PIPELINE_RUN_ID"] != "AUTO"
    else datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:8]
)
PROCESSED_AT = datetime.now(timezone.utc).isoformat()

sc = SparkContext.getOrCreate()
glue_context = GlueContext(sc)
spark = glue_context.spark_session
spark.conf.set("spark.sql.sources.partitionOverwriteMode", "dynamic")
spark.conf.set("spark.sql.shuffle.partitions", "48")
job = Job(glue_context)
job.init(ARGUMENTS["JOB_NAME"], ARGUMENTS)
s3 = boto3.client("s3")


TABLE_COLUMNS = {
    "customers": ["CustomerID", "CustomerName", "EmailAddress", "PhoneNumber"],
    "accounts": ["AccountID", "CustomerID", "Balance"],
    "transactions": ["TransactionID", "AccountID", "TransactionDate", "TransactionType", "Amount"],
    "transaction_categories": ["CategoryID", "CategoryName"],
    "categorized_transactions": ["TransactionID", "CategoryID", "TransactionDescription"],
    "market_data": ["MarketDataID", "StockSymbol", "Price", "Timestamp"],
}

EXPECTED_RECORD_COUNTS = {
    "customers": 100_000,
    "accounts": 150_000,
    "transactions": 1_000_000,
    "transaction_categories": 10,
    "categorized_transactions": 1_000_000,
    "market_data": 87_140,
}

ALLOWED_TYPES = ["Deposit", "Withdrawal", "Transfer"]
TYPE_CATEGORY_PAIRS = [
    ("Deposit", 401),
    ("Deposit", 402),
    ("Deposit", 403),
    ("Withdrawal", 404),
    ("Withdrawal", 405),
    ("Withdrawal", 406),
    ("Withdrawal", 407),
    ("Withdrawal", 408),
    ("Transfer", 409),
    ("Transfer", 410),
]


def s3_uri(*parts: str) -> str:
    clean = [part.strip("/") for part in parts if part]
    return f"s3://{BUCKET}/" + "/".join(clean) + "/"


def read_raw_strings(table: str) -> DataFrame:
    path = s3_uri(SOURCE_PREFIX, table)
    header = spark.read.option("header", "true").option("inferSchema", "false").csv(path).columns
    expected = TABLE_COLUMNS[table]
    if header != expected:
        raise ValueError(f"SCHEMA_MISMATCH {table}: expected {expected}, received {header}")
    schema = T.StructType([T.StructField(name, T.StringType(), True) for name in expected])
    frame = (
        spark.read.option("header", "true")
        .option("mode", "PERMISSIVE")
        .schema(schema)
        .csv(path)
        .withColumn("_source_file", F.input_file_name())
    )
    return frame.withColumn("_raw_record", F.to_json(F.struct(*[F.col(column) for column in expected])))


def append_error(df: DataFrame, condition, code: str) -> DataFrame:
    return df.withColumn(
        "_dq_errors",
        F.when(
            condition,
            F.when(F.length(F.col("_dq_errors")) > 0, F.concat(F.col("_dq_errors"), F.lit("|"), F.lit(code))).otherwise(F.lit(code)),
        ).otherwise(F.col("_dq_errors")),
    )


def initialize_errors(df: DataFrame) -> DataFrame:
    return df.withColumn("_dq_errors", F.lit(""))


def add_duplicate_key_error(df: DataFrame, keys: list[str], code: str = "DUPLICATE_PRIMARY_KEY") -> DataFrame:
    counts = df.groupBy(*keys).count().withColumnRenamed("count", "_key_count")
    joined = df.join(counts, keys, "left")
    joined = append_error(joined, F.col("_key_count") > 1, code)
    return joined.drop("_key_count")


def split_valid_invalid(df: DataFrame) -> tuple[DataFrame, DataFrame]:
    return df.filter(F.col("_dq_errors") == ""), df.filter(F.col("_dq_errors") != "")


def add_fk_error(child: DataFrame, parent: DataFrame, keys: list[str], code: str) -> DataFrame:
    parent_keys = parent.select(*keys).dropDuplicates()
    missing = child.join(parent_keys, keys, "left_anti")
    valid = child.join(parent_keys, keys, "left_semi")
    missing = append_error(missing, F.lit(True), code)
    return valid.unionByName(missing)


def quarantine_projection(table: str, df: DataFrame, source_columns: list[str]) -> DataFrame:
    return df.select(
        F.lit(table).alias("dataset"),
        F.col("_raw_record").alias("original_record"),
        F.col("_dq_errors").alias("error_codes"),
        F.col("_source_file").alias("source_file"),
        F.lit(RUN_ID).alias("pipeline_run_id"),
        F.lit(PROCESSED_AT).cast("timestamp").alias("processed_at"),
    )


def write_parquet(df: DataFrame, table: str, partition_keys: list[str] | None = None) -> None:
    writer = df.write.mode("overwrite").option("compression", "snappy").option("maxRecordsPerFile", 250_000)
    if partition_keys:
        writer = writer.partitionBy(*partition_keys)
    else:
        df = df.coalesce(1)
        writer = df.write.mode("overwrite").option("compression", "snappy").option("maxRecordsPerFile", 250_000)
    writer.parquet(s3_uri(CURATED_PREFIX, table))


def put_json(key: str, payload: dict) -> None:
    s3.put_object(
        Bucket=BUCKET,
        Key=key,
        Body=json.dumps(payload, indent=2, default=str).encode("utf-8"),
        ContentType="application/json",
        ServerSideEncryption="AES256",
        Metadata={"pipeline-run-id": RUN_ID, "dataset-version": "2.0.0"},
    )


raw = {table: read_raw_strings(table) for table in TABLE_COLUMNS}

customers = initialize_errors(raw["customers"])
customers = (
    customers.withColumn("CustomerID", F.col("CustomerID").cast("long"))
    .withColumn("CustomerName", F.trim("CustomerName"))
    .withColumn("EmailAddress", F.lower(F.trim("EmailAddress")))
    .withColumn("PhoneNumber", F.trim("PhoneNumber"))
)
customers = append_error(customers, F.col("CustomerID").isNull(), "INVALID_CUSTOMER_ID")
customers = append_error(customers, F.col("CustomerName").isNull() | (F.length("CustomerName") == 0), "MISSING_CUSTOMER_NAME")
customers = append_error(customers, F.col("EmailAddress").isNull() | ~F.col("EmailAddress").rlike(r"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$"), "INVALID_EMAIL")
customers = append_error(customers, F.col("PhoneNumber").isNull() | ~F.col("PhoneNumber").rlike(r"^234\d{11}$"), "INVALID_PHONE")
customers = add_duplicate_key_error(customers, ["CustomerID"])
customers = add_duplicate_key_error(customers, ["EmailAddress"], "DUPLICATE_EMAIL")
customers = add_duplicate_key_error(customers, ["PhoneNumber"], "DUPLICATE_PHONE")
customers_valid, customers_invalid = split_valid_invalid(customers)

accounts = initialize_errors(raw["accounts"])
accounts = (
    accounts.withColumn("AccountID", F.col("AccountID").cast("long"))
    .withColumn("CustomerID", F.col("CustomerID").cast("long"))
    .withColumn("Balance", F.col("Balance").cast(T.DecimalType(18, 2)))
)
accounts = append_error(accounts, F.col("AccountID").isNull(), "INVALID_ACCOUNT_ID")
accounts = append_error(accounts, F.col("CustomerID").isNull(), "INVALID_CUSTOMER_ID")
accounts = append_error(accounts, F.col("Balance").isNull() | (F.col("Balance") < 0), "INVALID_BALANCE")
accounts = add_duplicate_key_error(accounts, ["AccountID"])
accounts_base_valid, accounts_invalid = split_valid_invalid(accounts)
accounts_checked = add_fk_error(accounts_base_valid, customers_valid, ["CustomerID"], "ORPHAN_CUSTOMER_ID")
accounts_valid, accounts_fk_invalid = split_valid_invalid(accounts_checked)
accounts_invalid = accounts_invalid.unionByName(accounts_fk_invalid)

transactions = initialize_errors(raw["transactions"])
transactions = (
    transactions.withColumn("TransactionID", F.col("TransactionID").cast("long"))
    .withColumn("AccountID", F.col("AccountID").cast("long"))
    .withColumn("TransactionDate", F.to_date("TransactionDate", "yyyy-MM-dd"))
    .withColumn("TransactionType", F.trim("TransactionType"))
    .withColumn("Amount", F.col("Amount").cast(T.DecimalType(18, 2)))
)
transactions = append_error(transactions, F.col("TransactionID").isNull(), "INVALID_TRANSACTION_ID")
transactions = append_error(transactions, F.col("AccountID").isNull(), "INVALID_ACCOUNT_ID")
transactions = append_error(transactions, F.col("TransactionDate").isNull(), "INVALID_TRANSACTION_DATE")
transactions = append_error(transactions, F.col("TransactionType").isNull() | ~F.col("TransactionType").isin(ALLOWED_TYPES), "INVALID_TRANSACTION_TYPE")
transactions = append_error(transactions, F.col("Amount").isNull() | (F.col("Amount") <= 0), "INVALID_AMOUNT")
transactions = add_duplicate_key_error(transactions, ["TransactionID"])
transactions_base_valid, transactions_invalid = split_valid_invalid(transactions)
transactions_checked = add_fk_error(transactions_base_valid, accounts_valid, ["AccountID"], "ORPHAN_ACCOUNT_ID")
transactions_valid, transactions_fk_invalid = split_valid_invalid(transactions_checked)
transactions_invalid = transactions_invalid.unionByName(transactions_fk_invalid)

categories = initialize_errors(raw["transaction_categories"])
categories = (
    categories.withColumn("CategoryID", F.col("CategoryID").cast("long"))
    .withColumn("CategoryName", F.trim("CategoryName"))
)
categories = append_error(categories, F.col("CategoryID").isNull(), "INVALID_CATEGORY_ID")
categories = append_error(categories, F.col("CategoryName").isNull() | (F.length("CategoryName") == 0), "MISSING_CATEGORY_NAME")
categories = add_duplicate_key_error(categories, ["CategoryID"])
categories = add_duplicate_key_error(categories, ["CategoryName"], "DUPLICATE_CATEGORY_NAME")
categories_valid, categories_invalid = split_valid_invalid(categories)

bridge = initialize_errors(raw["categorized_transactions"])
bridge = (
    bridge.withColumn("TransactionID", F.col("TransactionID").cast("long"))
    .withColumn("CategoryID", F.col("CategoryID").cast("long"))
    .withColumn("TransactionDescription", F.trim("TransactionDescription"))
)
bridge = append_error(bridge, F.col("TransactionID").isNull(), "INVALID_TRANSACTION_ID")
bridge = append_error(bridge, F.col("CategoryID").isNull(), "INVALID_CATEGORY_ID")
bridge = append_error(bridge, F.col("TransactionDescription").isNull() | (F.length("TransactionDescription") == 0), "MISSING_TRANSACTION_DESCRIPTION")
bridge = add_duplicate_key_error(bridge, ["TransactionID", "CategoryID"])
bridge = add_duplicate_key_error(bridge, ["TransactionID"], "MULTIPLE_CATEGORIES_FOR_TRANSACTION")
bridge_base_valid, bridge_invalid = split_valid_invalid(bridge)
bridge_checked = add_fk_error(bridge_base_valid, transactions_valid, ["TransactionID"], "ORPHAN_TRANSACTION_ID")
bridge_checked = add_fk_error(bridge_checked, categories_valid, ["CategoryID"], "ORPHAN_CATEGORY_ID")
bridge_fk_valid, bridge_fk_invalid = split_valid_invalid(bridge_checked)

type_category_schema = T.StructType(
    [T.StructField("TransactionType", T.StringType(), False), T.StructField("CategoryID", T.LongType(), False)]
)
allowed_pairs = spark.createDataFrame(TYPE_CATEGORY_PAIRS, type_category_schema)
bridge_with_type = bridge_fk_valid.join(
    transactions_valid.select("TransactionID", "TransactionType"), "TransactionID", "left"
)
compatible_bridge = bridge_with_type.join(allowed_pairs, ["TransactionType", "CategoryID"], "left_semi")
incompatible_bridge = bridge_with_type.join(allowed_pairs, ["TransactionType", "CategoryID"], "left_anti")
incompatible_bridge = append_error(incompatible_bridge, F.lit(True), "INCOMPATIBLE_TRANSACTION_CATEGORY")
bridge_valid = compatible_bridge.drop("TransactionType")
bridge_invalid = bridge_invalid.unionByName(bridge_fk_invalid).unionByName(
    incompatible_bridge.drop("TransactionType")
)

market = initialize_errors(raw["market_data"])
market = (
    market.withColumn("MarketDataID", F.col("MarketDataID").cast("long"))
    .withColumn("StockSymbol", F.upper(F.trim("StockSymbol")))
    .withColumn("Price", F.col("Price").cast(T.DecimalType(18, 2)))
    .withColumn("Timestamp", F.to_timestamp("Timestamp", "yyyy-MM-dd'T'HH:mm:ssX"))
)
market = append_error(market, F.col("MarketDataID").isNull(), "INVALID_MARKET_DATA_ID")
market = append_error(market, F.col("StockSymbol").isNull() | ~F.col("StockSymbol").rlike(r"^[A-Z][A-Z0-9.-]{0,9}$"), "INVALID_STOCK_SYMBOL")
market = append_error(market, F.col("Price").isNull() | (F.col("Price") <= 0), "INVALID_PRICE")
market = append_error(market, F.col("Timestamp").isNull(), "INVALID_MARKET_TIMESTAMP")
market = add_duplicate_key_error(market, ["MarketDataID"])
market = add_duplicate_key_error(market, ["StockSymbol", "Timestamp"], "DUPLICATE_SYMBOL_TIMESTAMP")
market_valid, market_invalid = split_valid_invalid(market)

valid_frames = {
    "customers": customers_valid,
    "accounts": accounts_valid,
    "transactions": transactions_valid,
    "transaction_categories": categories_valid,
    "categorized_transactions": bridge_valid,
    "market_data": market_valid,
}
invalid_frames = {
    "customers": customers_invalid,
    "accounts": accounts_invalid,
    "transactions": transactions_invalid,
    "transaction_categories": categories_invalid,
    "categorized_transactions": bridge_invalid,
    "market_data": market_invalid,
}

valid_frames = {table: frame.persist(StorageLevel.MEMORY_AND_DISK) for table, frame in valid_frames.items()}
invalid_frames = {table: frame.persist(StorageLevel.MEMORY_AND_DISK) for table, frame in invalid_frames.items()}

missing_category_relationships = transactions_valid.select("TransactionID").join(
    bridge_valid.select("TransactionID"), "TransactionID", "left_anti"
).count()
accounts_without_transactions = accounts_valid.select("AccountID").join(
    transactions_valid.select("AccountID").dropDuplicates(), "AccountID", "left_anti"
).count()

metrics = {}
quarantine_frames = []
total_received = 0
total_rejected = 0
for table in TABLE_COLUMNS:
    received = raw[table].count()
    valid = valid_frames[table].count()
    rejected = invalid_frames[table].count()
    error_code_counts = {
        row["error_code"]: row["count"]
        for row in (
            invalid_frames[table]
            .select(F.explode(F.split("_dq_errors", r"\|")).alias("error_code"))
            .groupBy("error_code")
            .count()
            .collect()
        )
    }
    total_received += received
    total_rejected += rejected
    metrics[table] = {
        "records_received": received,
        "expected_records": EXPECTED_RECORD_COUNTS[table],
        "row_count_match": received == EXPECTED_RECORD_COUNTS[table],
        "records_valid": valid,
        "records_rejected": rejected,
        "reject_rate": (rejected / received) if received else 0.0,
        "error_code_counts": error_code_counts,
    }
    quarantine_frames.append(quarantine_projection(table, invalid_frames[table], TABLE_COLUMNS[table]))

reject_rate = total_rejected / total_received if total_received else 1.0
row_count_mismatches = [table for table, result in metrics.items() if not result["row_count_match"]]
critical_relationship_failures = missing_category_relationships + accounts_without_transactions
publish_allowed = (
    reject_rate <= MAX_REJECT_RATE
    and critical_relationship_failures == 0
    and not row_count_mismatches
)
overall_status = "PASS" if total_rejected == 0 and publish_allowed else ("PASS_WITH_REJECTS" if publish_allowed else "FAIL")

quality_summary = {
    "dataset": "ZIPCO Relational Dataset v2",
    "dataset_version": "2.0.0",
    "pipeline_run_id": RUN_ID,
    "job_name": ARGUMENTS["JOB_NAME"],
    "processed_at_utc": PROCESSED_AT,
    "source_prefix": s3_uri(SOURCE_PREFIX),
    "curated_prefix": s3_uri(CURATED_PREFIX),
    "quarantine_prefix": s3_uri(QUARANTINE_PREFIX, f"run_id={RUN_ID}"),
    "overall_status": overall_status,
    "publication_allowed": publish_allowed,
    "maximum_reject_rate": MAX_REJECT_RATE,
    "total_records_received": total_received,
    "total_records_rejected": total_rejected,
    "overall_reject_rate": reject_rate,
    "critical_relationship_checks": {
        "transactions_without_category": missing_category_relationships,
        "accounts_without_transaction": accounts_without_transactions,
    },
    "row_count_mismatches": row_count_mismatches,
    "tables": metrics,
    "output_format": "Apache Parquet",
    "compression": "Snappy",
    "partitioning": {
        "transactions": ["TransactionYear"],
        "market_data": ["MarketYear"],
    },
}

quality_key = f"{QUALITY_PREFIX}/run_id={RUN_ID}/summary.json"
put_json(quality_key, quality_summary)

quarantine_all = quarantine_frames[0]
for frame in quarantine_frames[1:]:
    quarantine_all = quarantine_all.unionByName(frame)
if total_rejected > 0:
    quarantine_all.write.mode("overwrite").json(s3_uri(QUARANTINE_PREFIX, f"run_id={RUN_ID}"))
else:
    put_json(
        f"{QUARANTINE_PREFIX}/run_id={RUN_ID}/NO_REJECTS.json",
        {"pipeline_run_id": RUN_ID, "status": "NO_REJECTS", "processed_at_utc": PROCESSED_AT},
    )

if not publish_allowed:
    raise RuntimeError(
        f"Curated publication blocked: reject_rate={reject_rate:.6f}, "
        f"critical_relationship_failures={critical_relationship_failures}, "
        f"row_count_mismatches={row_count_mismatches}. "
        f"See s3://{BUCKET}/{quality_key}"
    )

customers_output = customers_valid.select("CustomerID", "CustomerName", "EmailAddress", "PhoneNumber")
accounts_output = accounts_valid.select("AccountID", "CustomerID", "Balance")
transactions_output = transactions_valid.select(
    "TransactionID", "AccountID", "TransactionDate", "TransactionType", "Amount"
).withColumn("TransactionYear", F.year("TransactionDate"))
categories_output = categories_valid.select("CategoryID", "CategoryName")
bridge_output = bridge_valid.select("TransactionID", "CategoryID", "TransactionDescription")
market_output = market_valid.select("MarketDataID", "StockSymbol", "Price", "Timestamp").withColumn(
    "MarketYear", F.year("Timestamp")
)

write_parquet(customers_output, "customers")
write_parquet(accounts_output, "accounts")
write_parquet(transactions_output, "transactions", ["TransactionYear"])
write_parquet(categories_output, "transaction_categories")
write_parquet(bridge_output, "categorized_transactions")
write_parquet(market_output, "market_data", ["MarketYear"])

put_json(
    f"{QUALITY_PREFIX}/latest.json",
    {
        "pipeline_run_id": RUN_ID,
        "overall_status": overall_status,
        "publication_allowed": publish_allowed,
        "summary_uri": f"s3://{BUCKET}/{quality_key}",
        "processed_at_utc": PROCESSED_AT,
    },
)

job.commit()
