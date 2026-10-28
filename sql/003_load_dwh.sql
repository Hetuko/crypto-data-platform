-- Idempotently load symbols, UTC calendar dates, then valid 1h candles.
BEGIN;

-- Symbols are concatenated by Binance. Resolve the quote asset from the
-- longest known suffix so ETHBTC is parsed as base=ETH, quote=BTC.
CREATE TEMP TABLE supported_quote_assets (
    quote_asset TEXT PRIMARY KEY
) ON COMMIT DROP;

INSERT INTO supported_quote_assets (quote_asset) VALUES
    ('USDT'), ('USDC'), ('FDUSD'), ('BUSD'), ('TUSD'), ('USDP'),
    ('BTC'), ('ETH'), ('BNB'), ('EUR'), ('TRY'), ('BRL'), ('GBP'),
    ('AUD'), ('JPY')
ON CONFLICT DO NOTHING;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM (SELECT DISTINCT symbol FROM raw.candles) AS r
        WHERE NOT EXISTS (
            SELECT 1
            FROM supported_quote_assets AS q
            WHERE right(r.symbol, length(q.quote_asset)) = q.quote_asset
              AND length(r.symbol) > length(q.quote_asset)
        )
    ) THEN
        RAISE EXCEPTION
            'raw.candles contains a symbol with an unknown quote suffix; add it to supported_quote_assets in sql/003_load_dwh.sql';
    END IF;
END;
$$;

INSERT INTO dwh.dim_symbol (symbol, base_asset, quote_asset)
SELECT DISTINCT
       r.symbol,
       left(r.symbol, length(r.symbol) - length(q.quote_asset)),
       q.quote_asset
FROM raw.candles AS r
CROSS JOIN LATERAL (
    SELECT s.quote_asset
    FROM supported_quote_assets AS s
    WHERE right(r.symbol, length(s.quote_asset)) = s.quote_asset
      AND length(r.symbol) > length(s.quote_asset)
    ORDER BY length(s.quote_asset) DESC
    LIMIT 1
) AS q
ON CONFLICT (symbol) DO NOTHING;

INSERT INTO dwh.dim_date (
    date_id, full_date, year, quarter, month, day_of_week, is_weekend
)
SELECT to_char(g.d, 'YYYYMMDD')::INT,
       g.d::DATE,
       extract(year FROM g.d)::SMALLINT,
       extract(quarter FROM g.d)::SMALLINT,
       extract(month FROM g.d)::SMALLINT,
       extract(isodow FROM g.d)::SMALLINT,
       extract(isodow FROM g.d) IN (6, 7)
FROM generate_series(
    (SELECT date_trunc('day', min(open_time AT TIME ZONE 'UTC')) FROM raw.candles),
    (SELECT date_trunc('day', max(open_time AT TIME ZONE 'UTC')) FROM raw.candles),
    interval '1 day'
) AS g(d)
ON CONFLICT (date_id) DO NOTHING;

INSERT INTO dwh.fact_candle (
    symbol_id, date_id, open_time, open, high, low, close, volume, trades
)
SELECT s.symbol_id,
       to_char(r.open_time AT TIME ZONE 'UTC', 'YYYYMMDD')::INT,
       r.open_time,
       r.open,
       r.high,
       r.low,
       r.close,
       r.volume,
       r.trades
FROM raw.candles AS r
JOIN dwh.dim_symbol AS s ON s.symbol = r.symbol
WHERE r.candle_interval = '1h'
  AND r.high >= r.low
  AND r.open > 0
  AND r.close > 0
  AND r.volume >= 0
ON CONFLICT (symbol_id, open_time) DO UPDATE SET
    open = EXCLUDED.open,
    high = EXCLUDED.high,
    low = EXCLUDED.low,
    close = EXCLUDED.close,
    volume = EXCLUDED.volume,
    trades = EXCLUDED.trades;

COMMIT;
