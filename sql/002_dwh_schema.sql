-- DWH star schema for hourly spot candles.
CREATE SCHEMA IF NOT EXISTS dwh;

CREATE TABLE IF NOT EXISTS dwh.dim_symbol (
    symbol_id   SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    symbol      TEXT NOT NULL UNIQUE,
    base_asset  TEXT NOT NULL,
    quote_asset TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS dwh.dim_date (
    date_id     INT PRIMARY KEY,            -- YYYYMMDD, for example 20261027
    full_date   DATE NOT NULL UNIQUE,
    year        SMALLINT NOT NULL,
    quarter     SMALLINT NOT NULL,
    month       SMALLINT NOT NULL,
    day_of_week SMALLINT NOT NULL,          -- 1 = Monday (ISO)
    is_weekend  BOOLEAN NOT NULL
);

CREATE TABLE IF NOT EXISTS dwh.fact_candle (
    symbol_id SMALLINT      NOT NULL REFERENCES dwh.dim_symbol (symbol_id),
    date_id   INT           NOT NULL REFERENCES dwh.dim_date (date_id),
    open_time TIMESTAMPTZ   NOT NULL,
    open      NUMERIC(18,8) NOT NULL,
    high      NUMERIC(18,8) NOT NULL,
    low       NUMERIC(18,8) NOT NULL,
    close     NUMERIC(18,8) NOT NULL,
    volume    NUMERIC(24,8) NOT NULL,
    trades    INT,
    PRIMARY KEY (symbol_id, open_time),
    CONSTRAINT chk_high_low CHECK (high >= low),
    CONSTRAINT chk_prices_positive CHECK (open > 0 AND close > 0),
    CONSTRAINT chk_volume CHECK (volume >= 0)
);

CREATE INDEX IF NOT EXISTS idx_fact_candle_date
    ON dwh.fact_candle (date_id);
