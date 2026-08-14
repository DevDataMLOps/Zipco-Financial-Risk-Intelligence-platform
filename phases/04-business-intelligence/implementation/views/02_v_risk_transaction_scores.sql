CREATE OR REPLACE VIEW zipco_financial_risk_engine.v_risk_transaction_scores AS
WITH components AS (
    SELECT
        f.*,
        20 * is_balance_exposure AS balance_exposure_points,
        15 * is_high_value AS high_value_points,
        15 * is_cohort_p95 AS cohort_p95_points,
        25 * is_external_transfer AS external_transfer_points,
        15 * is_account_amount_outlier AS account_outlier_points,
        10 * is_transfer AS transfer_activity_points
    FROM zipco_financial_risk_engine.v_risk_transaction_features AS f
),
scored AS (
    SELECT
        c.*,
        LEAST(
            100,
            balance_exposure_points
              + high_value_points
              + cohort_p95_points
              + external_transfer_points
              + account_outlier_points
              + transfer_activity_points
        ) AS risk_score
    FROM components AS c
)
SELECT
    TransactionID,
    AccountID,
    CustomerID,
    TransactionDate,
    TransactionType,
    Amount,
    CategoryID,
    CategoryName,
    Balance,
    account_transaction_count,
    account_average_amount,
    account_amount_stddev,
    cohort_p95_amount,
    amount_to_balance_ratio,
    account_amount_zscore,
    is_high_value,
    is_cohort_p95,
    is_balance_exposure,
    is_external_transfer,
    is_account_amount_outlier,
    is_transfer,
    balance_exposure_points,
    high_value_points,
    cohort_p95_points,
    external_transfer_points,
    account_outlier_points,
    transfer_activity_points,
    risk_score,
    CASE
        WHEN risk_score >= 70 THEN 'CRITICAL'
        WHEN risk_score >= 50 THEN 'HIGH'
        WHEN risk_score >= 30 THEN 'MEDIUM'
        ELSE 'LOW'
    END AS risk_band,
    array_join(
        ARRAY[
            CASE WHEN is_balance_exposure = 1 THEN 'BALANCE_EXPOSURE' END,
            CASE WHEN is_high_value = 1 THEN 'HIGH_VALUE' END,
            CASE WHEN is_cohort_p95 = 1 THEN 'COHORT_P95' END,
            CASE WHEN is_external_transfer = 1 THEN 'EXTERNAL_TRANSFER' END,
            CASE WHEN is_account_amount_outlier = 1 THEN 'ACCOUNT_AMOUNT_OUTLIER' END,
            CASE WHEN is_transfer = 1 THEN 'TRANSFER_ACTIVITY' END
        ],
        '|'
    ) AS reason_codes,
    '1.0.0' AS model_version,
    TransactionYear
FROM scored
