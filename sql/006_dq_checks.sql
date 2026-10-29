WITH bounds AS (
    SELECT date_trunc('hour', now(), 'UTC') - interval '48 hours' AS window_start,
           date_trunc('hour', now(), 'UTC') AS window_end
),
known_candles AS (
    SELECT c.symbol, c.open_time
    FROM raw.candles AS c
    WHERE c.candle_interval = '1h'

    UNION ALL

    SELECT s.symbol, f.open_time
    FROM dwh.fact_candle AS f
    JOIN dwh.dim_symbol AS s ON s.symbol_id = f.symbol_id
),
symbol_history AS (
    SELECT s.symbol, min(k.open_time) AS first_open_time
    FROM dwh.dim_symbol AS s
    LEFT JOIN known_candles AS k ON k.symbol = s.symbol
    GROUP BY s.symbol
),
expected_hours AS (
    SELECT h.symbol, expected.open_time
    FROM symbol_history AS h
    CROSS JOIN bounds AS b
    CROSS JOIN LATERAL generate_series(
        GREATEST(
            b.window_start,
            date_trunc('hour', h.first_open_time, 'UTC')
        ),
        b.window_end - interval '1 hour',
        interval '1 hour'
    ) AS expected(open_time)
),
valid_raw AS (
    SELECT c.symbol, c.open_time, c.open, c.high, c.low, c.close, c.volume, c.trades
    FROM raw.candles AS c
    CROSS JOIN bounds AS b
    WHERE c.candle_interval = '1h'
      AND c.open_time >= b.window_start
      AND c.open_time < b.window_end
      AND c.high >= c.low
      AND c.open > 0
      AND c.close > 0
      AND c.volume >= 0
),
dwh_window AS (
    SELECT s.symbol, f.open_time, f.open, f.high, f.low, f.close, f.volume, f.trades
    FROM dwh.fact_candle AS f
    JOIN dwh.dim_symbol AS s ON s.symbol_id = f.symbol_id
    CROSS JOIN bounds AS b
    WHERE f.open_time >= b.window_start
      AND f.open_time < b.window_end
),
raw_only AS (
    SELECT * FROM valid_raw
    EXCEPT
    SELECT * FROM dwh_window
),
dwh_only AS (
    SELECT * FROM dwh_window
    EXCEPT
    SELECT * FROM valid_raw
)
SELECT
    (SELECT COUNT(*)
     FROM raw.candles AS c
     CROSS JOIN bounds AS b
     WHERE c.candle_interval = '1h'
       AND c.open_time >= b.window_start
       AND c.open_time < b.window_end
       AND (c.high < c.low OR c.open <= 0 OR c.close <= 0 OR c.volume < 0)
    ) = 0 AS no_bad_rows,

    (SELECT MAX(open_time) FROM dwh.fact_candle)
        > now() - interval '3 hours' AS is_fresh,

    NOT EXISTS (SELECT 1 FROM raw_only)
        AND NOT EXISTS (SELECT 1 FROM dwh_only) AS reconciled,

    NOT EXISTS (
        SELECT 1
        FROM expected_hours AS e
        WHERE NOT EXISTS (
            SELECT 1
            FROM raw.candles AS c
            WHERE c.symbol = e.symbol
              AND c.candle_interval = '1h'
              AND c.open_time = e.open_time
        )
    ) AS no_missing_hours;
