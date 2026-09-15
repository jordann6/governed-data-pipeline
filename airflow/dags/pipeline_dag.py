"""Airflow DAG: orchestrate the governed pipeline.

Airflow is the conductor. It does NOT do the compute. It triggers the Glue job and
waits for it, which is exactly the MWAA pattern. Runs identically in local Airflow
(docker-compose) and in MWAA; the only differences are managed metadata DB, environment
sizing, and the plugins/requirements S3 bucket in MWAA.
"""
from datetime import datetime, timedelta
from airflow import DAG
from airflow.providers.amazon.aws.operators.glue import GlueJobOperator

default_args = {
    "owner": "platform",
    "retries": 2,
    "retry_delay": timedelta(minutes=2),
}

with DAG(
    dag_id="veeva_reference_pipeline",
    description="Paved-road pipeline: land, transform in Glue, expose via Athena/Redshift",
    schedule="@daily",
    start_date=datetime(2026, 1, 1),
    catchup=False,          # no accidental backfill storm on first deploy
    default_args=default_args,
    tags=["reference", "finops", "paved-road"],
) as dag:

    transform = GlueJobOperator(
        task_id="run_glue_transform",
        job_name="vpl-demo-transform",   # matches the Terraform-created job
        aws_conn_id="aws_default",
        wait_for_completion=True,        # fail loud, don't fire-and-forget
    )
