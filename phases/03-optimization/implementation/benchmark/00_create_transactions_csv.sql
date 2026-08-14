CREATE EXTERNAL TABLE IF NOT EXISTS zipco_performance_benchmark.transactions_csv (
    TransactionID string,
    AccountID string,
    TransactionDate string,
    TransactionType string,
    Amount string
)
ROW FORMAT DELIMITED
FIELDS TERMINATED BY ','
STORED AS TEXTFILE
LOCATION 's3://__BUCKET__/validated/relational_v2/transactions/'
TBLPROPERTIES (
    'skip.header.line.count' = '1',
    'classification' = 'csv',
    'dataset_version' = '2.0.0',
    'benchmark_only' = 'true'
)
