WITH rollups AS (
    SELECT
        (SELECT sum(transaction_count) FROM zipco_financial_risk_engine.v_risk_account_scores) AS account_transaction_rollup,
        (SELECT sum(transaction_count) FROM zipco_financial_risk_engine.v_risk_customer_scores) AS customer_transaction_rollup,
        (SELECT sum(account_count) FROM zipco_financial_risk_engine.v_risk_customer_scores) AS customer_account_rollup,
        (SELECT count(*) FROM zipco_financial_risk_engine.v_risk_transaction_scores) AS transaction_count,
        (SELECT count(*) FROM zipco_financial_risk_engine.v_risk_account_scores) AS account_count
),
violations AS (
    SELECT
        CASE
            WHEN account_transaction_rollup = transaction_count
             AND customer_transaction_rollup = transaction_count
             AND customer_account_rollup = account_count
                THEN 0
            ELSE 1
        END AS violation_count
    FROM rollups
)
SELECT
    'RE-009' AS rule_id,
    CASE WHEN violation_count = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
    CAST(violation_count AS varchar) AS actual,
    '0' AS expected,
    'Transaction and account totals must reconcile through account and customer rollups.' AS details
FROM violations
