WITH counts AS (
    SELECT 'customers' AS dataset, count(*) AS actual, BIGINT '100000' AS expected
    FROM zipco_financial_risk.zipco_v2_customers
    UNION ALL
    SELECT 'accounts', count(*), BIGINT '150000'
    FROM zipco_financial_risk.zipco_v2_accounts
    UNION ALL
    SELECT 'transactions', count(*), BIGINT '1000000'
    FROM zipco_financial_risk.zipco_v2_transactions
    UNION ALL
    SELECT 'transaction_categories', count(*), BIGINT '10'
    FROM zipco_financial_risk.zipco_v2_transaction_categories
    UNION ALL
    SELECT 'categorized_transactions', count(*), BIGINT '1000000'
    FROM zipco_financial_risk.zipco_v2_categorized_transactions
    UNION ALL
    SELECT 'market_data', count(*), BIGINT '87140'
    FROM zipco_financial_risk.zipco_v2_market_data
)
SELECT
    'QV-ATH-001' AS rule_id,
    IF(sum(IF(actual = expected, 0, 1)) = 0, 'PASS', 'FAIL') AS status,
    CAST(sum(IF(actual = expected, 0, 1)) AS varchar) AS actual,
    '0' AS expected,
    array_join(array_agg(concat(dataset, '=', CAST(actual AS varchar), '/', CAST(expected AS varchar))), '; ') AS details
FROM counts
