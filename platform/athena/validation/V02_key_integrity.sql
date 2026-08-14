WITH issues AS (
    SELECT 'customers.CustomerID' AS relationship,
           count(*) - count(DISTINCT CustomerID) AS issue_count
    FROM zipco_financial_risk.zipco_v2_customers
    UNION ALL
    SELECT 'customers.EmailAddress', count(*) - count(DISTINCT EmailAddress)
    FROM zipco_financial_risk.zipco_v2_customers
    UNION ALL
    SELECT 'customers.PhoneNumber', count(*) - count(DISTINCT PhoneNumber)
    FROM zipco_financial_risk.zipco_v2_customers
    UNION ALL
    SELECT 'accounts.AccountID', count(*) - count(DISTINCT AccountID)
    FROM zipco_financial_risk.zipco_v2_accounts
    UNION ALL
    SELECT 'transactions.TransactionID', count(*) - count(DISTINCT TransactionID)
    FROM zipco_financial_risk.zipco_v2_transactions
    UNION ALL
    SELECT 'transaction_categories.CategoryID', count(*) - count(DISTINCT CategoryID)
    FROM zipco_financial_risk.zipco_v2_transaction_categories
    UNION ALL
    SELECT 'transaction_categories.CategoryName', count(*) - count(DISTINCT CategoryName)
    FROM zipco_financial_risk.zipco_v2_transaction_categories
    UNION ALL
    SELECT 'categorized_transactions.TransactionID', count(*) - count(DISTINCT TransactionID)
    FROM zipco_financial_risk.zipco_v2_categorized_transactions
    UNION ALL
    SELECT 'market_data.MarketDataID', count(*) - count(DISTINCT MarketDataID)
    FROM zipco_financial_risk.zipco_v2_market_data
    UNION ALL
    SELECT 'market_data.SymbolTimestamp', count(*) - count(DISTINCT concat(StockSymbol, '|', CAST(Timestamp AS varchar)))
    FROM zipco_financial_risk.zipco_v2_market_data
)
SELECT
    'QV-ATH-002' AS rule_id,
    IF(sum(issue_count) = 0, 'PASS', 'FAIL') AS status,
    CAST(sum(issue_count) AS varchar) AS actual,
    '0' AS expected,
    array_join(array_agg(concat(relationship, '=', CAST(issue_count AS varchar))), '; ') AS details
FROM issues
