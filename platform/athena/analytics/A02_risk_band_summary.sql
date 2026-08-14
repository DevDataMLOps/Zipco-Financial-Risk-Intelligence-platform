SELECT
    activity_risk_band,
    count(*) AS account_count,
    sum(transaction_count) AS transaction_count,
    round(sum(transaction_value), 2) AS transaction_value,
    sum(high_value_transaction_count) AS high_value_transaction_count,
    round(avg(maximum_transaction_amount), 2) AS average_account_maximum
FROM zipco_financial_analytics.v_account_risk_signals
GROUP BY activity_risk_band
ORDER BY CASE activity_risk_band WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END
