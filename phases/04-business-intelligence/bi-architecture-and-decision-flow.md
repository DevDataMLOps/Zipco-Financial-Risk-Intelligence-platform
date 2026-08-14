# BI Architecture and Decision Flow

## Semantic and business-intelligence architecture

```mermaid
flowchart TB
    subgraph DATA["Curated and enriched data"]
        CUSTOMERS["zipco_v2_customers"]
        ACCOUNTS["zipco_v2_accounts"]
        TRANSACTIONS["v_transaction_enriched"]
    end

    subgraph RISK["Athena risk semantic layer"]
        FEATURES["v_risk_transaction_features"]
        TXSCORE["v_risk_transaction_scores"]
        ACSCORE["v_risk_account_scores"]
        CUSCORE["v_risk_customer_scores"]
        KPIS["v_financial_kpis"]
        TRENDS["v_monthly_risk_trends"]
    end

    subgraph PRODUCTS["Decision-ready products"]
        F01["F01 Executive KPI overview"]
        F02["F02 Risk distribution"]
        F03["F03 Customer review queue"]
        F04["F04 Transaction alert queue"]
        F05["F05 Monthly risk trends"]
        F06["F06 Category risk profile"]
    end

    subgraph USERS["BI consumers"]
        EXEC["Portfolio leadership"]
        RISKOPS["Risk operations"]
        ANALYST["Review analysts"]
        GOV["Data and model governance"]
    end

    TRANSACTIONS --> FEATURES --> TXSCORE --> ACSCORE --> CUSCORE
    ACCOUNTS --> FEATURES
    CUSTOMERS --> CUSCORE
    TXSCORE --> KPIS
    CUSCORE --> KPIS
    TXSCORE --> TRENDS
    KPIS --> F01 --> EXEC
    TXSCORE --> F02
    ACSCORE --> F02
    CUSCORE --> F02 --> RISKOPS
    CUSCORE --> F03 --> ANALYST
    TXSCORE --> F04 --> ANALYST
    TRENDS --> F05 --> EXEC
    TXSCORE --> F06 --> RISKOPS
    RISK --> GOV
```

## Score lineage

```mermaid
flowchart LR
    RAW["Transaction amount, type, category,<br/>account balance and history"] --> FEATURES["Balance exposure<br/>high value<br/>cohort P95<br/>external transfer<br/>account outlier<br/>transfer activity"]
    FEATURES --> TS["Transaction score 0–100<br/>6 components + reasons"]
    TS --> AM["Account activity rollup"]
    AM --> AS["Account score 0–100<br/>5 components + reasons"]
    AS --> CM["Customer portfolio rollup"]
    CM --> CS["Customer score 0–100<br/>4 components + reasons"]
    TS --> QUEUE1["Transaction review queue"]
    AS --> DIST["Risk distribution"]
    CS --> QUEUE2["Customer review queue"]
    CS --> KPI["Executive KPIs"]
```

## Analyst decision workflow

```mermaid
flowchart TD
    START["Open saved Customer Review or Transaction Alert query"] --> PRIORITY["Review HIGH and CRITICAL records ordered by score and exposure"]
    PRIORITY --> WHY["Inspect component points and reason codes"]
    WHY --> CONTEXT["Review amount, category, balance ratio, account z-score, repeated activity, and portfolio exposure"]
    CONTEXT --> DECIDE{"Does activity warrant investigation?"}
    DECIDE -->|"No"| CLOSE["Document review outcome"]
    DECIDE -->|"Yes"| ESCALATE["Escalate to an authorized investigation process"]
    ESCALATE --> HUMAN["Human decision under approved policy"]
```

The engine prioritizes review. It does not make the final determination shown in the last step.

## Publication and governance flow

```mermaid
flowchart LR
    VIEWS["6 risk and KPI views"] --> VALIDATE["10 automated validations"]
    VALIDATE -->|"any failure"| BLOCK["Stop deployment; do not publish saved queries"]
    VALIDATE -->|"10/10 PASS"| ANALYTICS["Execute 6 BI analytics products"]
    ANALYTICS -->|"any empty or failed result"| BLOCK
    ANALYTICS -->|"6/6 PASS"| SAVED["Create and verify 6 saved queries"]
    SAVED --> EVIDENCE["S3 deployment evidence<br/>model contract + run metadata"]
```

## Business-intelligence surfaces

| Surface | Grain | Primary decision |
|---|---|---|
| Financial KPIs | Whole portfolio | Understand scale, flows, and overall risk posture |
| Risk distribution | Entity level and band | Understand concentration of entities and exposure |
| Customer review queue | Customer | Prioritize customer portfolios for analyst review |
| Transaction alert queue | Transaction | Prioritize individual activity with context |
| Monthly trends | Month | Monitor activity and elevated-risk rates over time |
| Category risk profile | Type and category | Identify categories concentrating elevated activity |
