WITH distribution AS (
    SELECT
        'TRANSACTION' AS entity_level,
        risk_band,
        count(*) AS entity_count,
        sum(Amount) AS exposure_value,
        avg(CAST(risk_score AS double)) AS average_risk_score
    FROM zipco_financial_risk_engine.v_risk_transaction_scores
    GROUP BY risk_band
    UNION ALL
    SELECT
        'ACCOUNT',
        risk_band,
        count(*),
        sum(Balance),
        avg(CAST(risk_score AS double))
    FROM zipco_financial_risk_engine.v_risk_account_scores
    GROUP BY risk_band
    UNION ALL
    SELECT
        'CUSTOMER',
        risk_band,
        count(*),
        sum(total_balance),
        avg(CAST(risk_score AS double))
    FROM zipco_financial_risk_engine.v_risk_customer_scores
    GROUP BY risk_band
)
SELECT
    entity_level,
    risk_band,
    entity_count,
    exposure_value,
    average_risk_score
FROM distribution
ORDER BY
    CASE entity_level WHEN 'TRANSACTION' THEN 1 WHEN 'ACCOUNT' THEN 2 ELSE 3 END,
    CASE risk_band WHEN 'CRITICAL' THEN 1 WHEN 'HIGH' THEN 2 WHEN 'MEDIUM' THEN 3 ELSE 4 END
