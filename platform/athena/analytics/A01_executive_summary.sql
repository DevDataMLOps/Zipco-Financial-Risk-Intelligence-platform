SELECT
    count(*) AS transaction_count,
    round(sum(Amount), 2) AS transaction_value,
    round(avg(Amount), 2) AS average_transaction,
    count(DISTINCT AccountID) AS active_accounts,
    count(DISTINCT CustomerID) AS active_customers,
    min(TransactionDate) AS first_transaction_date,
    max(TransactionDate) AS last_transaction_date
FROM zipco_financial_analytics.v_transaction_enriched
