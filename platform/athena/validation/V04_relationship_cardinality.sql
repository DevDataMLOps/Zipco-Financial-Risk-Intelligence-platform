WITH transaction_category_cardinality AS (
    SELECT t.TransactionID, count(ct.CategoryID) AS category_count
    FROM zipco_financial_risk.zipco_v2_transactions t
    LEFT JOIN zipco_financial_risk.zipco_v2_categorized_transactions ct
      ON t.TransactionID = ct.TransactionID
    GROUP BY t.TransactionID
),
issues AS (
    SELECT 'transactions_not_exactly_one_category' AS relationship,
           count_if(category_count <> 1) AS issue_count
    FROM transaction_category_cardinality
    UNION ALL
    SELECT 'accounts_without_transaction', count(*)
    FROM zipco_financial_risk.zipco_v2_accounts a
    LEFT JOIN (
        SELECT DISTINCT AccountID
        FROM zipco_financial_risk.zipco_v2_transactions
    ) t ON a.AccountID = t.AccountID
    WHERE t.AccountID IS NULL
)
SELECT
    'QV-ATH-004' AS rule_id,
    IF(sum(issue_count) = 0, 'PASS', 'FAIL') AS status,
    CAST(sum(issue_count) AS varchar) AS actual,
    '0' AS expected,
    array_join(array_agg(concat(relationship, '=', CAST(issue_count AS varchar))), '; ') AS details
FROM issues
