SELECT
    TransactionType,
    CategoryName,
    count(*) AS transaction_count,
    round(sum(Amount), 2) AS transaction_value,
    round(avg(Amount), 2) AS average_amount,
    count_if(Amount >= DECIMAL '9000.00') AS high_value_count
FROM zipco_financial_analytics.v_transaction_enriched
GROUP BY TransactionType, CategoryName
ORDER BY transaction_value DESC
