WITH violations AS (
    SELECT count(*) AS violation_count
    FROM zipco_financial_risk_engine.v_risk_customer_scores
    WHERE risk_score < 0
       OR risk_score > 100
       OR risk_score <> LEAST(
            100,
            max_account_risk_points
              + elevated_accounts_points
              + repeated_risky_transactions_points
              + portfolio_outgoing_exposure_points
          )
       OR risk_band <> CASE
            WHEN risk_score >= 70 THEN 'CRITICAL'
            WHEN risk_score >= 50 THEN 'HIGH'
            WHEN risk_score >= 30 THEN 'MEDIUM'
            ELSE 'LOW'
          END
)
SELECT
    'RE-006' AS rule_id,
    CASE WHEN violation_count = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
    CAST(violation_count AS varchar) AS actual,
    '0' AS expected,
    'Every customer score and band must reconcile to its four contracted components.' AS details
FROM violations
