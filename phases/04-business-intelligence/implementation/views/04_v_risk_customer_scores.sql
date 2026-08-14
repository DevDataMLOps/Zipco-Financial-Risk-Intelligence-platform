CREATE OR REPLACE VIEW zipco_financial_risk_engine.v_risk_customer_scores AS
WITH portfolio AS (
    SELECT
        CustomerID,
        count(*) AS account_count,
        sum(Balance) AS total_balance,
        sum(transaction_count) AS transaction_count,
        sum(transaction_value) AS transaction_value,
        sum(outgoing_value) AS outgoing_value,
        sum(deposit_value) AS deposit_value,
        sum(high_value_transaction_count) AS high_value_transaction_count,
        sum(external_transfer_count) AS external_transfer_count,
        sum(risky_transaction_count) AS risky_transaction_count,
        count_if(risk_band IN ('HIGH', 'CRITICAL')) AS high_or_critical_account_count,
        max(risk_score) AS maximum_account_risk_score,
        avg(CAST(risk_score AS double)) AS average_account_risk_score,
        min(first_transaction_date) AS first_transaction_date,
        max(last_transaction_date) AS last_transaction_date
    FROM zipco_financial_risk_engine.v_risk_account_scores
    GROUP BY CustomerID
),
metrics AS (
    SELECT
        p.*,
        CAST(outgoing_value AS double) / NULLIF(CAST(total_balance AS double), 0.0) AS outgoing_to_balance_ratio
    FROM portfolio AS p
),
components AS (
    SELECT
        m.*,
        CAST(round(0.60 * maximum_account_risk_score) AS integer) AS max_account_risk_points,
        CASE
            WHEN high_or_critical_account_count >= 2 THEN 15
            WHEN high_or_critical_account_count >= 1 THEN 8
            ELSE 0
        END AS elevated_accounts_points,
        CASE
            WHEN risky_transaction_count >= 5 THEN 15
            WHEN risky_transaction_count >= 1 THEN 8
            ELSE 0
        END AS repeated_risky_transactions_points,
        CASE
            WHEN outgoing_to_balance_ratio >= 10.0 THEN 10
            WHEN outgoing_to_balance_ratio >= 5.0 THEN 6
            WHEN outgoing_to_balance_ratio >= 2.0 THEN 3
            ELSE 0
        END AS portfolio_outgoing_exposure_points
    FROM metrics AS m
),
scored AS (
    SELECT
        c.*,
        LEAST(
            100,
            max_account_risk_points
              + elevated_accounts_points
              + repeated_risky_transactions_points
              + portfolio_outgoing_exposure_points
        ) AS risk_score
    FROM components AS c
)
SELECT
    CustomerID,
    account_count,
    total_balance,
    transaction_count,
    transaction_value,
    outgoing_value,
    deposit_value,
    high_value_transaction_count,
    external_transfer_count,
    risky_transaction_count,
    high_or_critical_account_count,
    maximum_account_risk_score,
    average_account_risk_score,
    outgoing_to_balance_ratio,
    first_transaction_date,
    last_transaction_date,
    max_account_risk_points,
    elevated_accounts_points,
    repeated_risky_transactions_points,
    portfolio_outgoing_exposure_points,
    risk_score,
    CASE
        WHEN risk_score >= 70 THEN 'CRITICAL'
        WHEN risk_score >= 50 THEN 'HIGH'
        WHEN risk_score >= 30 THEN 'MEDIUM'
        ELSE 'LOW'
    END AS risk_band,
    array_join(
        ARRAY[
            CASE WHEN max_account_risk_points > 0 THEN 'MAX_ACCOUNT_RISK' END,
            CASE WHEN elevated_accounts_points > 0 THEN 'MULTIPLE_ELEVATED_ACCOUNTS' END,
            CASE WHEN repeated_risky_transactions_points > 0 THEN 'REPEATED_RISKY_TRANSACTIONS' END,
            CASE WHEN portfolio_outgoing_exposure_points > 0 THEN 'PORTFOLIO_OUTGOING_EXPOSURE' END
        ],
        '|'
    ) AS reason_codes,
    '1.0.0' AS model_version
FROM scored
