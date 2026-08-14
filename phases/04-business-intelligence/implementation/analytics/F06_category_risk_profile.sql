SELECT
    TransactionType,
    CategoryID,
    CategoryName,
    count(*) AS transaction_count,
    sum(Amount) AS transaction_value,
    avg(CAST(Amount AS double)) AS average_amount,
    avg(CAST(risk_score AS double)) AS average_risk_score,
    count_if(risk_band = 'CRITICAL') AS critical_count,
    count_if(risk_band = 'HIGH') AS high_count,
    count_if(risk_band IN ('HIGH', 'CRITICAL')) AS elevated_count,
    CAST(count_if(risk_band IN ('HIGH', 'CRITICAL')) AS double) / NULLIF(CAST(count(*) AS double), 0.0) AS elevated_rate
FROM zipco_financial_risk_engine.v_risk_transaction_scores
GROUP BY TransactionType, CategoryID, CategoryName
ORDER BY elevated_rate DESC, transaction_value DESC
