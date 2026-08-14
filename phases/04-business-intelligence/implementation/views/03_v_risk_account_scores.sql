CREATE OR REPLACE VIEW zipco_financial_risk_engine.v_risk_account_scores AS
WITH activity AS (
    SELECT
        AccountID,
        CustomerID,
        count(*) AS transaction_count,
        sum(Amount) AS transaction_value,
        sum(CASE WHEN TransactionType IN ('Withdrawal', 'Transfer') THEN Amount ELSE DECIMAL '0.00' END) AS outgoing_value,
        sum(CASE WHEN TransactionType = 'Deposit' THEN Amount ELSE DECIMAL '0.00' END) AS deposit_value,
        count_if(is_high_value = 1) AS high_value_transaction_count,
        count_if(is_external_transfer = 1) AS external_transfer_count,
        count_if(risk_band IN ('HIGH', 'CRITICAL')) AS risky_transaction_count,
        max(risk_score) AS maximum_transaction_risk_score,
        avg(CAST(risk_score AS double)) AS average_transaction_risk_score,
        min(TransactionDate) AS first_transaction_date,
        max(TransactionDate) AS last_transaction_date
    FROM zipco_financial_risk_engine.v_risk_transaction_scores
    GROUP BY AccountID, CustomerID
),
metrics AS (
    SELECT
        x.*,
        a.Balance,
        CAST(risky_transaction_count AS double) / NULLIF(CAST(transaction_count AS double), 0.0) AS risky_transaction_rate,
        CAST(outgoing_value AS double) / NULLIF(CAST(a.Balance AS double), 0.0) AS outgoing_to_balance_ratio
    FROM activity AS x
    JOIN zipco_financial_risk.zipco_v2_accounts AS a
      ON x.AccountID = a.AccountID
),
components AS (
    SELECT
        m.*,
        CAST(round(0.50 * maximum_transaction_risk_score) AS integer) AS max_transaction_risk_points,
        CASE
            WHEN risky_transaction_rate >= 0.25 THEN 15
            WHEN risky_transaction_rate >= 0.10 THEN 8
            ELSE 0
        END AS risky_transaction_rate_points,
        CASE
            WHEN outgoing_to_balance_ratio >= 10.0 THEN 15
            WHEN outgoing_to_balance_ratio >= 5.0 THEN 10
            WHEN outgoing_to_balance_ratio >= 2.0 THEN 5
            ELSE 0
        END AS outgoing_exposure_points,
        CASE
            WHEN high_value_transaction_count >= 3 THEN 10
            WHEN high_value_transaction_count >= 1 THEN 5
            ELSE 0
        END AS repeat_high_value_points,
        CASE
            WHEN external_transfer_count >= 3 THEN 10
            WHEN external_transfer_count >= 1 THEN 5
            ELSE 0
        END AS repeat_external_transfer_points
    FROM metrics AS m
),
scored AS (
    SELECT
        c.*,
        LEAST(
            100,
            max_transaction_risk_points
              + risky_transaction_rate_points
              + outgoing_exposure_points
              + repeat_high_value_points
              + repeat_external_transfer_points
        ) AS risk_score
    FROM components AS c
)
SELECT
    AccountID,
    CustomerID,
    Balance,
    transaction_count,
    transaction_value,
    outgoing_value,
    deposit_value,
    high_value_transaction_count,
    external_transfer_count,
    risky_transaction_count,
    maximum_transaction_risk_score,
    average_transaction_risk_score,
    risky_transaction_rate,
    outgoing_to_balance_ratio,
    first_transaction_date,
    last_transaction_date,
    max_transaction_risk_points,
    risky_transaction_rate_points,
    outgoing_exposure_points,
    repeat_high_value_points,
    repeat_external_transfer_points,
    risk_score,
    CASE
        WHEN risk_score >= 70 THEN 'CRITICAL'
        WHEN risk_score >= 50 THEN 'HIGH'
        WHEN risk_score >= 30 THEN 'MEDIUM'
        ELSE 'LOW'
    END AS risk_band,
    array_join(
        ARRAY[
            CASE WHEN max_transaction_risk_points > 0 THEN 'MAX_TRANSACTION_RISK' END,
            CASE WHEN risky_transaction_rate_points > 0 THEN 'RISKY_TRANSACTION_RATE' END,
            CASE WHEN outgoing_exposure_points > 0 THEN 'OUTGOING_BALANCE_EXPOSURE' END,
            CASE WHEN repeat_high_value_points > 0 THEN 'REPEAT_HIGH_VALUE' END,
            CASE WHEN repeat_external_transfer_points > 0 THEN 'REPEAT_EXTERNAL_TRANSFER' END
        ],
        '|'
    ) AS reason_codes,
    '1.0.0' AS model_version
FROM scored
