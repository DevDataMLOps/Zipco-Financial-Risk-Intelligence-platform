WITH violations AS (
    SELECT count(*) AS violation_count
    FROM zipco_financial_risk_engine.v_risk_transaction_scores
    WHERE risk_score < 0
       OR risk_score > 100
       OR risk_band NOT IN ('LOW', 'MEDIUM', 'HIGH', 'CRITICAL')
       OR risk_band <> CASE
            WHEN risk_score >= 70 THEN 'CRITICAL'
            WHEN risk_score >= 50 THEN 'HIGH'
            WHEN risk_score >= 30 THEN 'MEDIUM'
            ELSE 'LOW'
          END
)
SELECT
    'RE-003' AS rule_id,
    CASE WHEN violation_count = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
    CAST(violation_count AS varchar) AS actual,
    '0' AS expected,
    'Transaction scores must remain from 0 through 100 and map to the contracted band thresholds.' AS details
FROM violations
