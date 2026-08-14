CREATE OR REPLACE VIEW zipco_financial_risk_engine.v_financial_kpis AS
WITH transaction_metrics AS (
    SELECT
        count(*) AS transaction_count,
        sum(Amount) AS transaction_value,
        avg(CAST(Amount AS double)) AS average_transaction_amount,
        sum(CASE WHEN TransactionType = 'Deposit' THEN Amount ELSE DECIMAL '0.00' END) AS deposit_value,
        sum(CASE WHEN TransactionType = 'Withdrawal' THEN Amount ELSE DECIMAL '0.00' END) AS withdrawal_value,
        sum(CASE WHEN TransactionType = 'Transfer' THEN Amount ELSE DECIMAL '0.00' END) AS transfer_value,
        count_if(is_high_value = 1) AS high_value_transaction_count,
        count_if(is_external_transfer = 1) AS external_transfer_count,
        count_if(risk_band IN ('HIGH', 'CRITICAL')) AS high_or_critical_transaction_count,
        count_if(risk_band = 'CRITICAL') AS critical_transaction_count,
        avg(CAST(risk_score AS double)) AS average_transaction_risk_score,
        min(TransactionDate) AS first_transaction_date,
        max(TransactionDate) AS last_transaction_date
    FROM zipco_financial_risk_engine.v_risk_transaction_scores
),
account_metrics AS (
    SELECT
        count(*) AS account_count,
        sum(Balance) AS total_balance
    FROM zipco_financial_risk.zipco_v2_accounts
),
customer_metrics AS (
    SELECT
        count(*) AS customer_count,
        count_if(risk_band = 'LOW') AS low_risk_customer_count,
        count_if(risk_band = 'MEDIUM') AS medium_risk_customer_count,
        count_if(risk_band = 'HIGH') AS high_risk_customer_count,
        count_if(risk_band = 'CRITICAL') AS critical_risk_customer_count,
        sum(CASE WHEN risk_band IN ('HIGH', 'CRITICAL') THEN total_balance ELSE DECIMAL '0.00' END) AS elevated_risk_balance,
        avg(CAST(risk_score AS double)) AS average_customer_risk_score
    FROM zipco_financial_risk_engine.v_risk_customer_scores
)
SELECT
    c.customer_count,
    a.account_count,
    t.transaction_count,
    a.total_balance,
    t.transaction_value,
    t.average_transaction_amount,
    t.deposit_value,
    t.withdrawal_value,
    t.transfer_value,
    t.deposit_value - t.withdrawal_value - t.transfer_value AS net_cash_flow,
    t.high_value_transaction_count,
    t.external_transfer_count,
    t.high_or_critical_transaction_count,
    t.critical_transaction_count,
    CAST(t.high_or_critical_transaction_count AS double) / NULLIF(CAST(t.transaction_count AS double), 0.0) AS elevated_transaction_rate,
    t.average_transaction_risk_score,
    c.low_risk_customer_count,
    c.medium_risk_customer_count,
    c.high_risk_customer_count,
    c.critical_risk_customer_count,
    c.elevated_risk_balance,
    c.average_customer_risk_score,
    t.first_transaction_date,
    t.last_transaction_date,
    '1.0.0' AS model_version
FROM transaction_metrics AS t
CROSS JOIN account_metrics AS a
CROSS JOIN customer_metrics AS c
