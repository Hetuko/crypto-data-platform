"""Load recent, closed Binance spot candles into raw.candles."""

from datetime import datetime, timedelta, timezone
from decimal import Decimal
import logging
import os
from pathlib import Path
import time

from dotenv import load_dotenv
from psycopg2 import connect
from psycopg2.extras import execute_values
import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry


SYMBOLS = ("BTCUSDT", "ETHUSDT", "SOLUSDT")
CANDLE_INTERVAL = "1h"
CANDLE_LIMIT = 500
BINANCE_KLINES_URL = "https://data-api.binance.vision/api/v3/klines"
PROJECT_ROOT = Path(__file__).resolve().parents[1]

logger = logging.getLogger(__name__)


UPSERT_SQL = """
    INSERT INTO raw.candles (
        symbol,
        candle_interval,
        open_time,
        open,
        high,
        low,
        close,
        volume,
        close_time,
        trades
    )
    VALUES %s
    ON CONFLICT (symbol, candle_interval, open_time)
    DO UPDATE SET
        open = EXCLUDED.open,
        high = EXCLUDED.high,
        low = EXCLUDED.low,
        close = EXCLUDED.close,
        volume = EXCLUDED.volume,
        close_time = EXCLUDED.close_time,
        trades = EXCLUDED.trades,
        loaded_at = now()
"""


def timestamp_from_milliseconds(value: int) -> datetime:
    """Convert Binance's Unix timestamp in milliseconds to a UTC datetime."""
    return datetime(1970, 1, 1, tzinfo=timezone.utc) + timedelta(
        milliseconds=int(value)
    )


def build_http_session() -> requests.Session:
    """Create a session that retries temporary Binance/API failures."""
    retry = Retry(
        total=3,
        connect=3,
        read=3,
        status=3,
        backoff_factor=1,
        status_forcelist=(429, 500, 502, 503, 504),
        allowed_methods=frozenset({"GET"}),
        respect_retry_after_header=True,
    )
    adapter = HTTPAdapter(max_retries=retry)
    session = requests.Session()
    session.mount("https://", adapter)
    session.mount("http://", adapter)
    return session


def fetch_rows(session: requests.Session, symbol: str) -> list[tuple]:
    """Fetch the latest completed candles and map them to raw.candles rows."""
    response = session.get(
        BINANCE_KLINES_URL,
        params={
            "symbol": symbol,
            "interval": CANDLE_INTERVAL,
            "limit": CANDLE_LIMIT,
        },
        timeout=30,
    )
    response.raise_for_status()
    candles = response.json()

    if not isinstance(candles, list):
        raise RuntimeError(f"Unexpected Binance response for {symbol}: {candles}")

    now_ms = int(time.time() * 1000)
    completed_candles = [candle for candle in candles if int(candle[6]) < now_ms]

    # Binance kline positions: open time, OHLC, volume, close time,
    # quote volume, trade count, taker volumes, ignore.
    # Map only the columns present in raw.candles; preserve numeric precision.
    return [
        (
            symbol,
            CANDLE_INTERVAL,
            timestamp_from_milliseconds(candle[0]),
            Decimal(candle[1]),
            Decimal(candle[2]),
            Decimal(candle[3]),
            Decimal(candle[4]),
            Decimal(candle[5]),
            timestamp_from_milliseconds(candle[6]),
            int(candle[8]),
        )
        for candle in completed_candles
    ]


def load_symbol(conn, session: requests.Session, symbol: str) -> None:
    """Fetch and upsert one symbol as a single database transaction."""
    try:
        rows = fetch_rows(session, symbol)
        if not rows:
            logger.info("%s: no completed candles returned; nothing loaded.", symbol)
            return

        with conn.cursor() as cursor:
            execute_values(cursor, UPSERT_SQL, rows, page_size=CANDLE_LIMIT)

        conn.commit()
        logger.info("%s: loaded %s hourly candles.", symbol, len(rows))
    except Exception:
        conn.rollback()
        raise


def required_env(name: str) -> str:
    value = os.getenv(name)
    if not value:
        raise RuntimeError(f"Missing {name} in the project .env file.")
    return value


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    load_dotenv(PROJECT_ROOT / ".env")

    db_config = {
        "host": os.getenv("POSTGRES_HOST", "localhost"),
        "port": int(os.getenv("POSTGRES_PORT", "5433")),
        "dbname": required_env("POSTGRES_DB"),
        "user": required_env("POSTGRES_USER"),
        "password": required_env("POSTGRES_PASSWORD"),
    }

    conn = connect(**db_config)
    failed_symbols = []
    try:
        with build_http_session() as session:
            for symbol in SYMBOLS:
                try:
                    load_symbol(conn, session, symbol)
                except Exception:
                    logger.exception("Failed to load %s", symbol)
                    failed_symbols.append(symbol)
    finally:
        conn.close()

    if failed_symbols:
        logger.error("Failed symbols: %s", ", ".join(failed_symbols))
        raise SystemExit(1)


if __name__ == "__main__":
    main()
