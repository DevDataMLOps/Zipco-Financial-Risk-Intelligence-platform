WITH incompatible AS (
    SELECT count(*) AS issue_count
    FROM zipco_financial_risk.zipco_v2_transactions t
    JOIN zipco_financial_risk.zipco_v2_categorized_transactions ct
      ON t.TransactionID = ct.TransactionID
    WHERE NOT (
        (t.TransactionType = 'Deposit' AND ct.CategoryID IN (401, 402, 403))
        OR (t.TransactionType = 'Withdrawal' AND ct.CategoryID IN (404, 405, 406, 407, 408))
        OR (t.TransactionType = 'Transfer' AND ct.CategoryID IN (409, 410))
    )
)
SELECT
    'QV-ATH-006' AS rule_id,
    IF(issue_count = 0, 'PASS', 'FAIL') AS status,
    CAST(issue_count AS varchar) AS actual,
    '0' AS expected,
    concat('incompatible_transaction_category_pairs=', CAST(issue_count AS varchar)) AS details
FROM incompatible
