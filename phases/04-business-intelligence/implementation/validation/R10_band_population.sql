WITH band_counts AS (
    SELECT 'TRANSACTION' AS entity_level, count(DISTINCT risk_band) AS populated_bands
    FROM zipco_financial_risk_engine.v_risk_transaction_scores
    UNION ALL
    SELECT 'ACCOUNT', count(DISTINCT risk_band)
    FROM zipco_financial_risk_engine.v_risk_account_scores
    UNION ALL
    SELECT 'CUSTOMER', count(DISTINCT risk_band)
    FROM zipco_financial_risk_engine.v_risk_customer_scores
),
violations AS (
    SELECT count_if(populated_bands <> 4) AS violation_count
    FROM band_counts
)
SELECT
    'RE-010' AS rule_id,
    CASE WHEN violation_count = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
    CAST(violation_count AS varchar) AS actual,
    '0' AS expected,
    'LOW, MEDIUM, HIGH, and CRITICAL must all be populated for transactions, accounts, and customers.' AS details
FROM violations
