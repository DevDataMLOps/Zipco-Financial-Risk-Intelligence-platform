CREATE OR REPLACE VIEW zipco_financial_analytics.v_customer_portfolio AS
WITH account_rollup AS (
    SELECT
        CustomerID,
        count(*) AS account_count,
        sum(Balance) AS total_balance
    FROM zipco_financial_risk.zipco_v2_accounts
    GROUP BY CustomerID
),
transaction_rollup AS (
    SELECT
        CustomerID,
        count(*) AS transaction_count,
        sum(Amount) AS transaction_value,
        count_if(Amount >= DECIMAL '9000.00') AS high_value_transaction_count,
        min(TransactionDate) AS first_transaction_date,
        max(TransactionDate) AS last_transaction_date
    FROM zipco_financial_analytics.v_transaction_enriched
    GROUP BY CustomerID
)
SELECT
    c.CustomerID,
    c.CustomerName,
    c.EmailAddress,
    ar.account_count,
    ar.total_balance,
    tr.transaction_count,
    tr.transaction_value,
    tr.high_value_transaction_count,
    tr.first_transaction_date,
    tr.last_transaction_date
FROM zipco_financial_risk.zipco_v2_customers AS c
JOIN account_rollup AS ar
  ON c.CustomerID = ar.CustomerID
JOIN transaction_rollup AS tr
  ON c.CustomerID = tr.CustomerID
