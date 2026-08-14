WITH issues AS (
    SELECT 'transaction_date_range' AS check_name,
           IF(min(TransactionDate) = DATE '2000-01-01' AND max(TransactionDate) = DATE '2023-11-09', 0, 1) AS issue_count
    FROM zipco_financial_risk.zipco_v2_transactions
    UNION ALL
    SELECT 'transaction_year_partition', count_if(TransactionYear IS NULL OR try_cast(TransactionYear AS integer) <> year(TransactionDate))
    FROM zipco_financial_risk.zipco_v2_transactions
    UNION ALL
    SELECT 'market_date_range', IF(date(min(Timestamp)) = DATE '2000-01-01' AND date(max(Timestamp)) = DATE '2023-11-09', 0, 1)
    FROM zipco_financial_risk.zipco_v2_market_data
    UNION ALL
    SELECT 'market_year_partition', count_if(MarketYear IS NULL OR try_cast(MarketYear AS integer) <> year(Timestamp))
    FROM zipco_financial_risk.zipco_v2_market_data
)
SELECT
    'QV-ATH-007' AS rule_id,
    IF(sum(issue_count) = 0, 'PASS', 'FAIL') AS status,
    CAST(sum(issue_count) AS varchar) AS actual,
    '0' AS expected,
    array_join(array_agg(concat(check_name, '=', CAST(issue_count AS varchar))), '; ') AS details
FROM issues
