SELECT
    TransactionType,
    count(*) AS transaction_count,
    round(sum(Amount), 2) AS transaction_value
FROM zipco_financial_risk.zipco_v2_transactions
GROUP BY TransactionType
ORDER BY TransactionType
