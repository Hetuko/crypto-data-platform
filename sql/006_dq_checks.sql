SELECT
    (SELECT COUNT(*) FROM raw.candles
      WHERE open_time > now() - interval '48 hours'
        AND (high < low OR open <= 0 OR close <= 0 OR volume < 0)) = 0 AS no_bad_rows,
    (SELECT MAX(open_time) FROM dwh.fact_candle) > now() - interval '3 hours' AS is_fresh;
