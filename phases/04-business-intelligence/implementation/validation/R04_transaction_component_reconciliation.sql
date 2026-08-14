WITH violations AS (
    SELECT count(*) AS violation_count
    FROM zipco_financial_risk_engine.v_risk_transaction_scores
    WHERE risk_score <> LEAST(
        100,
        balance_exposure_points
          + high_value_points
          + cohort_p95_points
          + external_transfer_points
          + account_outlier_points
          + transfer_activity_points
    )
)
SELECT
    'RE-004' AS rule_id,
    CASE WHEN violation_count = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
    CAST(violation_count AS varchar) AS actual,
    '0' AS expected,
    'Every transaction score must equal the capped sum of its six explainable components.' AS details
FROM violations
