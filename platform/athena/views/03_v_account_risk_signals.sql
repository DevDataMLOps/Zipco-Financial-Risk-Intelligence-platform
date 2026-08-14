CREATE OR REPLACE VIEW zipco_financial_analytics.v_account_risk_signals AS
SELECT
    AccountID,
    CustomerID,
    count(*) AS transaction_count,
    sum(Amount) AS transaction_value,
    sum(CASE WHEN TransactionType = 'Deposit' THEN Amount ELSE DECIMAL '0.00' END) AS deposit_value,
    sum(CASE WHEN TransactionType = 'Withdrawal' THEN Amount ELSE DECIMAL '0.00' END) AS withdrawal_value,
    sum(CASE WHEN TransactionType = 'Transfer' THEN Amount ELSE DECIMAL '0.00' END) AS transfer_value,
    count_if(Amount >= DECIMAL '9000.00') AS high_value_transaction_count,
    max(Amount) AS maximum_transaction_amount,
    min(TransactionDate) AS first_transaction_date,
    max(TransactionDate) AS last_transaction_date,
    CASE
        WHEN count_if(Amount >= DECIMAL '9000.00') >= 3
          OR sum(CASE WHEN TransactionType = 'Transfer' THEN Amount ELSE DECIMAL '0.00' END) >= DECIMAL '50000.00'
          THEN 'HIGH'
        WHEN count_if(Amount >= DECIMAL '9000.00') >= 1
          OR sum(CASE WHEN TransactionType = 'Transfer' THEN Amount ELSE DECIMAL '0.00' END) >= DECIMAL '20000.00'
          THEN 'MEDIUM'
        ELSE 'LOW'
    END AS activity_risk_band
FROM zipco_financial_analytics.v_transaction_enriched
GROUP BY AccountID, CustomerID
