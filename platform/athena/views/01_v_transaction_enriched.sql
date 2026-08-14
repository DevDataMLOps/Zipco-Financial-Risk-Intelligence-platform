CREATE OR REPLACE VIEW zipco_financial_analytics.v_transaction_enriched AS
SELECT
    t.TransactionID,
    t.AccountID,
    a.CustomerID,
    c.CustomerName,
    c.EmailAddress,
    t.TransactionDate,
    t.TransactionYear,
    t.TransactionType,
    t.Amount,
    ct.CategoryID,
    tc.CategoryName,
    ct.TransactionDescription
FROM zipco_financial_risk.zipco_v2_transactions AS t
JOIN zipco_financial_risk.zipco_v2_accounts AS a
  ON t.AccountID = a.AccountID
JOIN zipco_financial_risk.zipco_v2_customers AS c
  ON a.CustomerID = c.CustomerID
JOIN zipco_financial_risk.zipco_v2_categorized_transactions AS ct
  ON t.TransactionID = ct.TransactionID
JOIN zipco_financial_risk.zipco_v2_transaction_categories AS tc
  ON ct.CategoryID = tc.CategoryID
