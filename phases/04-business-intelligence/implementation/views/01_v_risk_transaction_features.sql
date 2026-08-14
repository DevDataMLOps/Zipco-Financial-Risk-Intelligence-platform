CREATE OR REPLACE VIEW zipco_financial_risk_engine.v_risk_transaction_features AS
WITH account_history AS (
    SELECT
        AccountID,
        count(*) AS account_transaction_count,
        avg(CAST(Amount AS double)) AS account_average_amount,
        stddev_pop(CAST(Amount AS double)) AS account_amount_stddev
    FROM zipco_financial_analytics.v_transaction_enriched
    GROUP BY AccountID
),
cohort_thresholds AS (
    SELECT
        TransactionType,
        CategoryID,
        approx_percentile(CAST(Amount AS double), 0.95) AS cohort_p95_amount
    FROM zipco_financial_analytics.v_transaction_enriched
    GROUP BY TransactionType, CategoryID
),
feature_base AS (
    SELECT
        e.TransactionID,
        e.AccountID,
        e.CustomerID,
        e.TransactionDate,
        e.TransactionYear,
        e.TransactionType,
        e.Amount,
        e.CategoryID,
        e.CategoryName,
        a.Balance,
        h.account_transaction_count,
        h.account_average_amount,
        h.account_amount_stddev,
        p.cohort_p95_amount,
        CAST(e.Amount AS double) / NULLIF(CAST(a.Balance AS double), 0.0) AS amount_to_balance_ratio,
        CASE
            WHEN h.account_amount_stddev > 0.0
                THEN (CAST(e.Amount AS double) - h.account_average_amount) / h.account_amount_stddev
            ELSE 0.0
        END AS account_amount_zscore
    FROM zipco_financial_analytics.v_transaction_enriched AS e
    JOIN zipco_financial_risk.zipco_v2_accounts AS a
      ON e.AccountID = a.AccountID
    JOIN account_history AS h
      ON e.AccountID = h.AccountID
    JOIN cohort_thresholds AS p
      ON e.TransactionType = p.TransactionType
     AND e.CategoryID = p.CategoryID
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
    CASE WHEN Amount >= DECIMAL '9000.00' THEN 1 ELSE 0 END AS is_high_value,
    CASE WHEN CAST(Amount AS double) >= cohort_p95_amount THEN 1 ELSE 0 END AS is_cohort_p95,
    CASE
        WHEN TransactionType IN ('Withdrawal', 'Transfer') AND Amount >= Balance THEN 1
        ELSE 0
    END AS is_balance_exposure,
    CASE
        WHEN TransactionType = 'Transfer' AND CategoryID = 410 THEN 1
        ELSE 0
    END AS is_external_transfer,
    CASE WHEN account_amount_zscore >= 2.0 THEN 1 ELSE 0 END AS is_account_amount_outlier,
    CASE WHEN TransactionType = 'Transfer' THEN 1 ELSE 0 END AS is_transfer,
    TransactionYear
FROM feature_base
