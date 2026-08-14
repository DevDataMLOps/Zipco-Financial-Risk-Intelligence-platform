WITH populations AS (
    SELECT
        (SELECT count(*) FROM zipco_financial_risk_engine.v_risk_transaction_scores) AS transaction_count,
        (SELECT count(*) FROM zipco_financial_risk_engine.v_risk_account_scores) AS account_count,
        (SELECT count(*) FROM zipco_financial_risk_engine.v_risk_customer_scores) AS customer_count
)
SELECT
    'RE-001' AS rule_id,
    CASE
        WHEN transaction_count = 1000000 AND account_count = 150000 AND customer_count = 100000 THEN 'PASS'
        ELSE 'FAIL'
    END AS status,
    concat(CAST(transaction_count AS varchar), '/', CAST(account_count AS varchar), '/', CAST(customer_count AS varchar)) AS actual,
    '1000000/150000/100000' AS expected,
    'Scored transaction/account/customer populations must equal relational-v2 populations.' AS details
FROM populations
