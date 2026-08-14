WITH checks AS (
    SELECT 'enriched_transaction_count' AS check_name,
           IF((SELECT count(*) FROM zipco_financial_analytics.v_transaction_enriched) = 1000000, 0, 1) AS issue_count
    UNION ALL
    SELECT 'customer_portfolio_count',
           IF((SELECT count(*) FROM zipco_financial_analytics.v_customer_portfolio) = 100000, 0, 1)
    UNION ALL
    SELECT 'account_risk_signal_count',
           IF((SELECT count(*) FROM zipco_financial_analytics.v_account_risk_signals) = 150000, 0, 1)
    UNION ALL
    SELECT 'monthly_metrics_reconcile',
           IF((SELECT sum(transaction_count) FROM zipco_financial_analytics.v_monthly_risk_metrics) = 1000000, 0, 1)
    UNION ALL
    SELECT 'enriched_amount_reconcile',
           IF(
               (SELECT sum(Amount) FROM zipco_financial_analytics.v_transaction_enriched)
               = (SELECT sum(Amount) FROM zipco_financial_risk.zipco_v2_transactions),
               0,
               1
           )
)
SELECT
    'QV-ATH-008' AS rule_id,
    IF(sum(issue_count) = 0, 'PASS', 'FAIL') AS status,
    CAST(sum(issue_count) AS varchar) AS actual,
    '0' AS expected,
    array_join(array_agg(concat(check_name, '=', CAST(issue_count AS varchar))), '; ') AS details
FROM checks
