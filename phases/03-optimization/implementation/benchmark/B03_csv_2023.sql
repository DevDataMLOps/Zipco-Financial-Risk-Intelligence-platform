SELECT
    TransactionType,
    count(*) AS transaction_count,
    round(sum(try_cast(Amount AS decimal(18,2))), 2) AS transaction_value
FROM zipco_performance_benchmark.transactions_csv
WHERE try_cast(TransactionDate AS date) BETWEEN DATE '2023-01-01' AND DATE '2023-11-09'
GROUP BY TransactionType
ORDER BY TransactionType
