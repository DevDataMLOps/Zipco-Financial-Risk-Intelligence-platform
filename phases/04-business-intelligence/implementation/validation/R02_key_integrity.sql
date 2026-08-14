WITH violations AS (
    SELECT
        (SELECT count(*) - count(DISTINCT TransactionID) FROM zipco_financial_risk_engine.v_risk_transaction_scores) AS duplicate_transactions,
        (SELECT count(*) - count(DISTINCT AccountID) FROM zipco_financial_risk_engine.v_risk_account_scores) AS duplicate_accounts,
        (SELECT count(*) - count(DISTINCT CustomerID) FROM zipco_financial_risk_engine.v_risk_customer_scores) AS duplicate_customers,
        (SELECT count_if(TransactionID IS NULL OR AccountID IS NULL OR CustomerID IS NULL) FROM zipco_financial_risk_engine.v_risk_transaction_scores) AS null_transaction_keys,
        (SELECT count_if(AccountID IS NULL OR CustomerID IS NULL) FROM zipco_financial_risk_engine.v_risk_account_scores) AS null_account_keys,
        (SELECT count_if(CustomerID IS NULL) FROM zipco_financial_risk_engine.v_risk_customer_scores) AS null_customer_keys
),
total AS (
    SELECT
        duplicate_transactions + duplicate_accounts + duplicate_customers
          + null_transaction_keys + null_account_keys + null_customer_keys AS violation_count
    FROM violations
)
SELECT
    'RE-002' AS rule_id,
    CASE WHEN violation_count = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
    CAST(violation_count AS varchar) AS actual,
    '0' AS expected,
    'Risk entities must preserve unique, non-null transaction, account, and customer keys.' AS details
FROM total
