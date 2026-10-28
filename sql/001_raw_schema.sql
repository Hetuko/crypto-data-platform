-- Raw Binance landing table. Data-quality validation is performed downstream,
-- so the raw layer intentionally does not reject invalid OHLCV rows.
CREATE SCHEMA IF NOT EXISTS raw;

CREATE TABLE IF NOT EXISTS raw.candles (
    symbol          TEXT          NOT NULL,
    candle_interval TEXT          NOT NULL,
    open_time       TIMESTAMPTZ   NOT NULL,
    open            NUMERIC(18,8) NOT NULL,
    high            NUMERIC(18,8) NOT NULL,
    low             NUMERIC(18,8) NOT NULL,
    close           NUMERIC(18,8) NOT NULL,
    volume          NUMERIC(24,8) NOT NULL,
    close_time      TIMESTAMPTZ   NOT NULL,
    trades          INT,
    loaded_at       TIMESTAMPTZ   DEFAULT now(),
    PRIMARY KEY (symbol, candle_interval, open_time)
);
