"""Hourly pipeline: Binance -> raw -> dwh -> checks -> marts."""

import pendulum
from airflow.providers.common.sql.operators.sql import (
    SQLCheckOperator,
    SQLExecuteQueryOperator,
)
from airflow.providers.standard.operators.bash import BashOperator
from airflow.sdk import DAG

CONN_ID = "crypto_pg"

with DAG(
    dag_id="crypto_candles_hourly",
    schedule="5 * * * *",
    start_date=pendulum.datetime(2026, 10, 1, tz="UTC"),
    catchup=False,
    max_active_runs=1,
    default_args={"retries": 3, "retry_delay": pendulum.duration(minutes=2)},
    template_searchpath=["/opt/airflow/sql"],
    tags=["crypto"],
) as dag:
    load_raw = BashOperator(
        task_id="load_raw_candles",
        bash_command="python /opt/airflow/src/load_candles.py",
    )
    load_dwh = SQLExecuteQueryOperator(
        task_id="load_dwh", conn_id=CONN_ID, sql="003_load_dwh.sql"
    )
    dq_checks = SQLCheckOperator(
        task_id="dq_checks", conn_id=CONN_ID, sql="006_dq_checks.sql"
    )
    refresh_marts = SQLExecuteQueryOperator(
        task_id="refresh_marts", conn_id=CONN_ID, sql="005_refresh_marts.sql"
    )

    load_raw >> load_dwh >> dq_checks >> refresh_marts
