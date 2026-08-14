WITH issues AS (
    SELECT 'customer_required_and_format' AS check_name,
           count_if(
               CustomerID IS NULL OR CustomerName IS NULL OR trim(CustomerName) = ''
               OR EmailAddress IS NULL OR NOT regexp_like(EmailAddress, '^[A-Za-z0-9.!#$%&''*+/=?^_`{|}~-]+@[A-Za-z0-9-]+(?:[.][A-Za-z0-9-]+)+$')
               OR PhoneNumber IS NULL OR NOT regexp_like(PhoneNumber, '^234[0-9]{11}$')
           ) AS issue_count
    FROM zipco_financial_risk.zipco_v2_customers
    UNION ALL
    SELECT 'account_required_and_range', count_if(AccountID IS NULL OR CustomerID IS NULL OR Balance IS NULL OR Balance < 0)
    FROM zipco_financial_risk.zipco_v2_accounts
    UNION ALL
    SELECT 'transaction_required_domain_range', count_if(
        TransactionID IS NULL OR AccountID IS NULL OR TransactionDate IS NULL
        OR TransactionType IS NULL OR TransactionType NOT IN ('Deposit', 'Withdrawal', 'Transfer')
        OR Amount IS NULL OR Amount <= 0
    )
    FROM zipco_financial_risk.zipco_v2_transactions
    UNION ALL
    SELECT 'category_required', count_if(CategoryID IS NULL OR CategoryName IS NULL OR trim(CategoryName) = '')
    FROM zipco_financial_risk.zipco_v2_transaction_categories
    UNION ALL
    SELECT 'bridge_required', count_if(TransactionID IS NULL OR CategoryID IS NULL OR TransactionDescription IS NULL OR trim(TransactionDescription) = '')
    FROM zipco_financial_risk.zipco_v2_categorized_transactions
    UNION ALL
    SELECT 'market_required_domain_range', count_if(
        MarketDataID IS NULL OR StockSymbol IS NULL OR NOT regexp_like(StockSymbol, '^[A-Z][A-Z0-9.-]{0,9}$')
        OR Price IS NULL OR Price <= 0 OR Timestamp IS NULL
    )
    FROM zipco_financial_risk.zipco_v2_market_data
)
SELECT
    'QV-ATH-005' AS rule_id,
    IF(sum(issue_count) = 0, 'PASS', 'FAIL') AS status,
    CAST(sum(issue_count) AS varchar) AS actual,
    '0' AS expected,
    array_join(array_agg(concat(check_name, '=', CAST(issue_count AS varchar))), '; ') AS details
FROM issues
