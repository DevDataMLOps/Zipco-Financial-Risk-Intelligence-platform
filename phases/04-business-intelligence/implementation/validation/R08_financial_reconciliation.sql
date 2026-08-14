WITH source_metrics AS (
    SELECT
        (SELECT count(*) FROM zipco_financial_risk.zipco_v2_customers) AS customer_count,
        (SELECT count(*) FROM zipco_financial_risk.zipco_v2_accounts) AS account_count,
        (SELECT sum(Balance) FROM zipco_financial_risk.zipco_v2_accounts) AS total_balance,
        count(*) AS transaction_count,
        sum(Amount) AS transaction_value,
        sum(CASE WHEN TransactionType = 'Deposit' THEN Amount ELSE DECIMAL '0.00' END) AS deposit_value,
        sum(CASE WHEN TransactionType = 'Withdrawal' THEN Amount ELSE DECIMAL '0.00' END) AS withdrawal_value,
        sum(CASE WHEN TransactionType = 'Transfer' THEN Amount ELSE DECIMAL '0.00' END) AS transfer_value
    FROM zipco_financial_risk.zipco_v2_transactions
),
violations AS (
    SELECT
        CASE
            WHEN k.customer_count = s.customer_count
             AND k.account_count = s.account_count
             AND k.transaction_count = s.transaction_count
             AND k.total_balance = s.total_balance
             AND k.transaction_value = s.transaction_value
             AND k.deposit_value = s.deposit_value
             AND k.withdrawal_value = s.withdrawal_value
             AND k.transfer_value = s.transfer_value
                THEN 0
            ELSE 1
        END AS violation_count
    FROM zipco_financial_risk_engine.v_financial_kpis AS k
    CROSS JOIN source_metrics AS s
)
SELECT
    'RE-008' AS rule_id,
    CASE WHEN violation_count = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
    CAST(violation_count AS varchar) AS actual,
    '0' AS expected,
    'Customers, accounts, balances, transaction counts, and transaction-type values must reconcile to source.' AS details
FROM violations
