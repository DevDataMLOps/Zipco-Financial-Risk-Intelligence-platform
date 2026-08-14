CREATE OR REPLACE VIEW zipco_financial_analytics.v_monthly_risk_metrics AS
SELECT
    year(TransactionDate) AS transaction_year,
    month(TransactionDate) AS transaction_month,
    TransactionType,
    CategoryName,
    count(*) AS transaction_count,
    sum(Amount) AS transaction_value,
    avg(Amount) AS average_amount,
    count(DISTINCT CustomerID) AS active_customers,
    count(DISTINCT AccountID) AS active_accounts,
    count_if(Amount >= DECIMAL '9000.00') AS high_value_count
FROM zipco_financial_analytics.v_transaction_enriched
GROUP BY year(TransactionDate), month(TransactionDate), TransactionType, CategoryName
