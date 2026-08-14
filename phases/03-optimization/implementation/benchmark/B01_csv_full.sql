SELECT
    TransactionType,
    count(*) AS transaction_count,
    round(sum(try_cast(Amount AS decimal(18,2))), 2) AS transaction_value
FROM zipco_performance_benchmark.transactions_csv
GROUP BY TransactionType
ORDER BY TransactionType
