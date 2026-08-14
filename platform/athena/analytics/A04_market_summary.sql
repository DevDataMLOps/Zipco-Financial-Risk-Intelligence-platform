SELECT
    StockSymbol,
    count(*) AS observations,
    min(date(Timestamp)) AS first_observation_date,
    max(date(Timestamp)) AS last_observation_date,
    min(Price) AS minimum_price,
    round(avg(Price), 2) AS average_price,
    max(Price) AS maximum_price,
    max_by(Price, Timestamp) AS latest_price
FROM zipco_financial_risk.zipco_v2_market_data
GROUP BY StockSymbol
ORDER BY StockSymbol
