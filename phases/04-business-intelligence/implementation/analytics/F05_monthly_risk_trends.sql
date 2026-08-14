SELECT
    risk_month,
    transaction_count,
    transaction_value,
    average_transaction_amount,
    average_risk_score,
    low_risk_count,
    medium_risk_count,
    high_risk_count,
    critical_risk_count,
    high_or_critical_count,
    elevated_transaction_rate,
    active_customers,
    active_accounts,
    model_version
FROM zipco_financial_risk_engine.v_monthly_risk_trends
ORDER BY risk_month DESC
LIMIT 60
