CREATE OR REPLACE VIEW zipco_financial_risk_engine.v_monthly_risk_trends AS
SELECT
    date_trunc('month', CAST(TransactionDate AS timestamp)) AS risk_month,
    count(*) AS transaction_count,
    sum(Amount) AS transaction_value,
    avg(CAST(Amount AS double)) AS average_transaction_amount,
    avg(CAST(risk_score AS double)) AS average_risk_score,
    count_if(risk_band = 'LOW') AS low_risk_count,
    count_if(risk_band = 'MEDIUM') AS medium_risk_count,
    count_if(risk_band = 'HIGH') AS high_risk_count,
    count_if(risk_band = 'CRITICAL') AS critical_risk_count,
    count_if(risk_band IN ('HIGH', 'CRITICAL')) AS high_or_critical_count,
    CAST(count_if(risk_band IN ('HIGH', 'CRITICAL')) AS double) / NULLIF(CAST(count(*) AS double), 0.0) AS elevated_transaction_rate,
    count(DISTINCT CustomerID) AS active_customers,
    count(DISTINCT AccountID) AS active_accounts,
    '1.0.0' AS model_version
FROM zipco_financial_risk_engine.v_risk_transaction_scores
GROUP BY date_trunc('month', CAST(TransactionDate AS timestamp))
