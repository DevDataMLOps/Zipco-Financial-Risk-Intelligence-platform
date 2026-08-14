SELECT
    TransactionID,
    AccountID,
    CustomerID,
    TransactionDate,
    TransactionType,
    CategoryName,
    Amount,
    Balance,
    amount_to_balance_ratio,
    account_amount_zscore,
    risk_score,
    risk_band,
    reason_codes,
    model_version
FROM zipco_financial_risk_engine.v_risk_transaction_scores
WHERE risk_band IN ('CRITICAL', 'HIGH')
ORDER BY risk_score DESC, Amount DESC, TransactionDate DESC, TransactionID
LIMIT 100
