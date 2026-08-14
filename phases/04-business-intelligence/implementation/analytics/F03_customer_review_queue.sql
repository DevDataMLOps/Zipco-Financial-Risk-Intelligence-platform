SELECT
    CustomerID,
    risk_score,
    risk_band,
    reason_codes,
    account_count,
    high_or_critical_account_count,
    transaction_count,
    risky_transaction_count,
    high_value_transaction_count,
    external_transfer_count,
    total_balance,
    outgoing_value,
    outgoing_to_balance_ratio,
    model_version
FROM zipco_financial_risk_engine.v_risk_customer_scores
WHERE risk_band IN ('CRITICAL', 'HIGH')
ORDER BY risk_score DESC, risky_transaction_count DESC, outgoing_to_balance_ratio DESC, CustomerID
LIMIT 100
