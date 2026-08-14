SELECT
    TransactionType,
    count(*) AS transaction_count,
    round(sum(Amount), 2) AS transaction_value
FROM zipco_financial_risk.zipco_v2_transactions
WHERE __PARTITION_PREDICATE__
  AND TransactionDate BETWEEN DATE '2023-01-01' AND DATE '2023-11-09'
GROUP BY TransactionType
ORDER BY TransactionType
