WITH violations AS (
    SELECT count(*) AS violation_count
    FROM zipco_financial_risk_engine.v_risk_account_scores
    WHERE risk_score < 0
       OR risk_score > 100
       OR risk_score <> LEAST(
            100,
            max_transaction_risk_points
              + risky_transaction_rate_points
              + outgoing_exposure_points
              + repeat_high_value_points
              + repeat_external_transfer_points
          )
       OR risk_band <> CASE
            WHEN risk_score >= 70 THEN 'CRITICAL'
            WHEN risk_score >= 50 THEN 'HIGH'
            WHEN risk_score >= 30 THEN 'MEDIUM'
            ELSE 'LOW'
          END
)
SELECT
    'RE-005' AS rule_id,
    CASE WHEN violation_count = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
    CAST(violation_count AS varchar) AS actual,
    '0' AS expected,
    'Every account score and band must reconcile to its five contracted components.' AS details
FROM violations
