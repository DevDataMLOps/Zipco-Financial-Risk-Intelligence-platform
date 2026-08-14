WITH issues AS (
    SELECT 'accounts_to_customers' AS relationship, count(*) AS issue_count
    FROM zipco_financial_risk.zipco_v2_accounts a
    LEFT JOIN zipco_financial_risk.zipco_v2_customers c ON a.CustomerID = c.CustomerID
    WHERE c.CustomerID IS NULL
    UNION ALL
    SELECT 'transactions_to_accounts', count(*)
    FROM zipco_financial_risk.zipco_v2_transactions t
    LEFT JOIN zipco_financial_risk.zipco_v2_accounts a ON t.AccountID = a.AccountID
    WHERE a.AccountID IS NULL
    UNION ALL
    SELECT 'bridge_to_transactions', count(*)
    FROM zipco_financial_risk.zipco_v2_categorized_transactions ct
    LEFT JOIN zipco_financial_risk.zipco_v2_transactions t ON ct.TransactionID = t.TransactionID
    WHERE t.TransactionID IS NULL
    UNION ALL
    SELECT 'bridge_to_categories', count(*)
    FROM zipco_financial_risk.zipco_v2_categorized_transactions ct
    LEFT JOIN zipco_financial_risk.zipco_v2_transaction_categories tc ON ct.CategoryID = tc.CategoryID
    WHERE tc.CategoryID IS NULL
)
SELECT
    'QV-ATH-003' AS rule_id,
    IF(sum(issue_count) = 0, 'PASS', 'FAIL') AS status,
    CAST(sum(issue_count) AS varchar) AS actual,
    '0' AS expected,
    array_join(array_agg(concat(relationship, '=', CAST(issue_count AS varchar))), '; ') AS details
FROM issues
