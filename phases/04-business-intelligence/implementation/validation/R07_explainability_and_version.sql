WITH violations AS (
    SELECT
        (SELECT count_if(risk_score > 0 AND coalesce(reason_codes, '') = '') FROM zipco_financial_risk_engine.v_risk_transaction_scores)
      + (SELECT count_if(risk_score > 0 AND coalesce(reason_codes, '') = '') FROM zipco_financial_risk_engine.v_risk_account_scores)
      + (SELECT count_if(risk_score > 0 AND coalesce(reason_codes, '') = '') FROM zipco_financial_risk_engine.v_risk_customer_scores)
      + (SELECT count_if(model_version <> '1.0.0') FROM zipco_financial_risk_engine.v_risk_transaction_scores)
      + (SELECT count_if(model_version <> '1.0.0') FROM zipco_financial_risk_engine.v_risk_account_scores)
      + (SELECT count_if(model_version <> '1.0.0') FROM zipco_financial_risk_engine.v_risk_customer_scores) AS violation_count
)
SELECT
    'RE-007' AS rule_id,
    CASE WHEN violation_count = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
    CAST(violation_count AS varchar) AS actual,
    '0' AS expected,
    'Every non-zero score must include reason codes and every entity must use model version 1.0.0.' AS details
FROM violations
