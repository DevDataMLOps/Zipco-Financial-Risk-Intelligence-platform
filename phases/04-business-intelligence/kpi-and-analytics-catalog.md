# KPI and Analytics Catalog

## Executive KPI view

`v_financial_kpis` returns one reconciled portfolio row.

| KPI family | Measures | Business meaning |
|---|---|---|
| Population | Customer, account, and transaction counts | Portfolio scale and coverage |
| Balance and activity | Total balance, total transaction value, average amount | Financial activity baseline |
| Flow mix | Deposit, withdrawal, transfer, and net-flow values | Transaction-type composition |
| Activity signals | High-value and external-transfer counts | Volume of interpretable risk signals |
| Transaction risk | Elevated count/rate, critical count, average score | Transaction review posture |
| Customer risk | Counts by all four bands, elevated-risk balance, average score | Customer portfolio exposure |
| Coverage | First and last transaction dates | Analytical time range |
| Governance | Model version | Reproducibility and model lineage |

`net_cash_flow` is a synthetic analytical indicator defined as deposits minus withdrawals minus transfers. It is not accounting income, profit, or a general-ledger balance.

## Financial snapshot

| Metric | Reconciled value |
|---|---:|
| Customers | 100,000 |
| Accounts | 150,000 |
| Transactions | 1,000,000 |
| Total balance | 758,585,675.53 units |
| Transaction value | 5,004,344,506.67 units |
| Average amount | 5,004.34 units |
| Deposit value | 1,669,546,315.82 units |
| Withdrawal value | 1,664,683,573.22 units |
| Transfer value | 1,670,114,617.63 units |
| Synthetic net-flow indicator | -1,665,251,875.03 units |
| High-value transactions | 100,188 |
| External transfers | 140,492 |

## Transaction-type activity

| Type | Transactions | Value |
|---|---:|---:|
| Deposit | 333,442 | 1,669,546,315.82 units |
| Transfer | 333,881 | 1,670,114,617.63 units |
| Withdrawal | 332,677 | 1,664,683,573.22 units |

The synthetic portfolio is deliberately balanced across transaction types. That makes it suitable for demonstrating the analytical pipeline, but the mix must not be treated as a real-world banking benchmark.

## Six analytics products

### F01 — Executive financial KPI overview

- **Question:** What is the size, activity, flow mix, and overall risk posture of the portfolio?
- **Grain:** One portfolio row.
- **Consumer:** Portfolio leadership, risk management, data governance.
- **Decision:** Establish scale, reconcile totals, and locate material elevated exposure.

### F02 — Risk distribution

- **Question:** How many transactions, accounts, and customers occupy each band, and what exposure sits there?
- **Grain:** Entity level × risk band.
- **Measures:** Count, exposure value, average score.
- **Decision:** Allocate review capacity and monitor concentration.

### F03 — Customer review queue

- **Question:** Which HIGH or CRITICAL customer portfolios should be reviewed first, and why?
- **Grain:** Customer; top 100.
- **Ordering:** Score, risky transaction count, outgoing/balance ratio, customer ID.
- **Context:** Reasons, accounts, elevated accounts, activity counts, balance, outgoing exposure, and model version.

### F04 — Transaction alert queue

- **Question:** Which HIGH or CRITICAL transactions need immediate contextual review?
- **Grain:** Transaction; top 100.
- **Ordering:** Score, amount, recency, transaction ID.
- **Context:** Account/customer, type, category, amount, balance, ratios, z-score, reasons, and model version.

### F05 — Monthly risk trends

- **Question:** How do activity, average score, band counts, elevated rate, and active populations change over time?
- **Grain:** Month; latest 60 rows.
- **Decision:** Detect changes that merit analytical investigation.

### F06 — Category risk profile

- **Question:** Which transaction-type/category cohorts concentrate elevated activity?
- **Grain:** Transaction type × category.
- **Measures:** Counts, values, average amount, average score, critical/high counts, and elevated rate.
- **Decision:** Focus review and model analysis on concentrated categories.

## Deployed review-queue scale

| Entity level | Critical count | Share of population |
|---|---:|---:|
| Transactions | 13,978 | 1.3978% |
| Accounts | 9,384 | 6.2560% |
| Customers | 6,354 | 6.3540% |

These are prioritization populations, not confirmed suspicious entities.

