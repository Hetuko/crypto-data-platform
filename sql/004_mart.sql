CREATE SCHEMA IF NOT EXISTS mart;

-- Live metrics are cheap to compute for this project and need no refresh.
CREATE OR REPLACE VIEW mart.candle_metrics AS
WITH windowed AS (
    SELECT s.symbol,
           f.open_time,
           f.close,
           row_number() OVER (
               PARTITION BY f.symbol_id ORDER BY f.open_time
           ) AS candle_number,
           avg(f.close) OVER (
               PARTITION BY f.symbol_id
               ORDER BY f.open_time
               ROWS BETWEEN 23 PRECEDING AND CURRENT ROW
           ) AS sma_24_candidate,
           lag(f.close) OVER (
               PARTITION BY f.symbol_id ORDER BY f.open_time
           ) AS previous_close,
           lag(f.open_time) OVER (
               PARTITION BY f.symbol_id ORDER BY f.open_time
           ) AS previous_open_time
    FROM dwh.fact_candle AS f
    JOIN dwh.dim_symbol AS s ON s.symbol_id = f.symbol_id
)
SELECT symbol,
       open_time,
       close,
       CASE WHEN candle_number >= 24 THEN sma_24_candidate END AS sma_24,
       CASE
           WHEN previous_open_time = open_time - interval '1 hour'
                AND previous_close <> 0
           THEN (close / previous_close - 1) * 100
       END AS hourly_return_pct
FROM windowed;

-- A daily aggregate is a materialized view to demonstrate an explicit refresh
-- step after the DWH load. The unique index allows a later CONCURRENTLY refresh.
CREATE MATERIALIZED VIEW IF NOT EXISTS mart.daily_summary AS
SELECT s.symbol,
       d.full_date,
       max(f.high) AS high_max,
       min(f.low) AS low_min,
       sum(f.volume) AS volume_sum,
       count(*) AS candle_count
FROM dwh.fact_candle AS f
JOIN dwh.dim_symbol AS s ON s.symbol_id = f.symbol_id
JOIN dwh.dim_date AS d ON d.date_id = f.date_id
GROUP BY s.symbol, d.full_date
WITH NO DATA;

CREATE UNIQUE INDEX IF NOT EXISTS uq_daily_summary_symbol_date
    ON mart.daily_summary (symbol, full_date);

-- Initial population; the future Airflow refresh_marts task can run this again
-- (or use REFRESH MATERIALIZED VIEW CONCURRENTLY after this first population).
REFRESH MATERIALIZED VIEW mart.daily_summary;
