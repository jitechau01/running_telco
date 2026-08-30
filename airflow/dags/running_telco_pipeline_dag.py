"""
running_telco_pipeline_dag.py

Airflow DAG wrapping the manual walkthrough from the Running Telco README
(Step 4 - "Generate & land data, run the pipeline") into one scheduled/
triggerable pipeline:

    generate_telecom_data.py  -> upload_to_s3.py
      -> snowflake_orchestrator.py --layer raw
      -> snowflake_orchestrator.py --layer staging
      -> snowflake_orchestrator.py --layer curated

Each step is a separate task (BashOperator) so failures are isolated and
retryable per-step in the Airflow UI, and each step's stdout/stderr lands in
that task's Airflow log - the same information the CLI would print, just
captured per-task instead of scrolling past in one terminal.

--------------------------------------------------------------------------
SETUP (one-time, before this DAG can run)
--------------------------------------------------------------------------
1. Copy this file into your Airflow DAGs folder:
     cp running_telco_pipeline_dag.py $AIRFLOW_HOME/dags/

2. Set two Airflow Variables (Admin -> Variables in the UI, or `airflow
   variables set`) so this DAG is portable across machines/environments
   instead of hardcoding a path:
     running_telco_repo_dir   e.g. /home/cloud/sandbox2/running-telco-snowflake-aws
     running_telco_python_bin e.g. /home/cloud/sandbox2/venv/bin/python
                               (defaults to "python3" on PATH if unset)

3. Make sure <repo_dir>/python/.env exists with real Snowflake/AWS
   credentials (copy from .env.example and fill in) - every task below
   sources it before running its script, exactly like running the CLI
   commands by hand would require. This DAG does NOT use Airflow
   Connections/Secrets Backend for credentials to keep it a direct,
   readable mapping of the manual commands; swapping to Airflow Connections
   (e.g. an AWS connection + a Snowflake connection, injected as env vars
   via each task's `env=` argument) is a natural follow-up hardening step
   once this runs correctly end-to-end.

--------------------------------------------------------------------------
SCHEDULE
--------------------------------------------------------------------------
schedule=None (manual trigger only) by default - this DAG generates and
lands a full synthetic dataset (5,000 customers, tens of thousands of CDR
rows) every run, which is a demo/training action, not something you want
firing on an unattended cron until you've deliberately decided on a cadence
and confirmed warehouse costs. Change `schedule=None` below to e.g.
`schedule="@daily"` once that's a deliberate choice.

NOTE ON PRODUCTION SHAPE: in a real deployment, RAW/STAGING for CDR would
run hourly while everything else runs daily (see the README's per-feed
cadence table), and CURATED would often be left entirely to the Snowflake
TASK DAG (sql/05_tasks) rather than driven from here. This single DAG
mirrors the manual walkthrough as one linear chain; splitting it into
separate DAGs per cadence is the natural next step once this baseline works.
"""

from datetime import datetime, timedelta

from airflow import DAG
from airflow.models import Variable
from airflow.operators.bash import BashOperator

REPO_DIR = Variable.get("running_telco_repo_dir", default_var="/opt/running-telco-snowflake-aws")
PYTHON_BIN = Variable.get("running_telco_python_bin", default_var="python3")
PYTHON_DIR = f"{REPO_DIR}/python"
ENV_FILE = f"{PYTHON_DIR}/.env"

# Source .env (if present) before every step, same as a human would need to
# `source .env` or use direnv before running these commands by hand.
# The `[ -f ... ]` guard means a missing .env doesn't hard-fail the task -
# it just runs with whatever the Airflow worker's own environment provides.
SOURCE_ENV = f'[ -f "{ENV_FILE}" ] && set -a && . "{ENV_FILE}" && set +a; '

default_args = {
    "owner": "data-engineering",
    "depends_on_past": False,
    "email_on_failure": False,
    "retries": 1,
    "retry_delay": timedelta(minutes=5),
}

with DAG(
    dag_id="running_telco_pipeline",
    description="Generate synthetic data, land it in S3, and run RAW -> STAGING -> CURATED",
    default_args=default_args,
    start_date=datetime(2026, 1, 1),
    schedule=None,          # manual trigger by default - see docstring above
    catchup=False,
    max_active_runs=1,      # don't let overlapping runs land conflicting files/loads
    tags=["running-telco", "snowflake", "demo"],
) as dag:

    generate_data = BashOperator(
        task_id="generate_telecom_data",
        bash_command=(
            SOURCE_ENV +
            f'cd "{PYTHON_DIR}" && '
            f'"{PYTHON_BIN}" ingestion/generate_telecom_data.py '
            f"--out ./data_out --customers 5000 --cdr-per-day 20000 --days 3"
        ),
        doc_md="Generates synthetic source CSVs into python/data_out/, matching the RAW table contract for all 8 feeds.",
    )

    upload_to_s3 = BashOperator(
        task_id="upload_to_s3",
        bash_command=(
            SOURCE_ENV +
            f'cd "{PYTHON_DIR}" && '
            f'"{PYTHON_BIN}" ingestion/upload_to_s3.py '
            f"--local-dir ./data_out --bucket running-telco-raw"
        ),
        doc_md="Uploads every generated file to s3://running-telco-raw/<feed>/, matching the Snowflake external stage prefixes.",
    )

    load_raw = BashOperator(
        task_id="load_raw_layer",
        bash_command=(
            SOURCE_ENV +
            f'cd "{PYTHON_DIR}" && '
            f'"{PYTHON_BIN}" orchestration/snowflake_orchestrator.py --layer raw --feeds all'
        ),
        doc_md="COPY INTO for every feed's external stage -> RAW.RAW_* table. Logged to AUDIT_CTL.ETL_RUN_LOG.",
    )

    load_staging = BashOperator(
        task_id="load_staging_layer",
        bash_command=(
            SOURCE_ENV +
            f'cd "{PYTHON_DIR}" && '
            f'"{PYTHON_BIN}" orchestration/snowflake_orchestrator.py --layer staging --feeds all'
        ),
        doc_md="CALL STAGING.SP_LOAD_STG_* for every feed. Logged to AUDIT_CTL.ETL_RUN_LOG.",
    )

    merge_curated = BashOperator(
        task_id="merge_curated_layer",
        bash_command=(
            SOURCE_ENV +
            f'cd "{PYTHON_DIR}" && '
            f'"{PYTHON_BIN}" orchestration/snowflake_orchestrator.py --layer curated'
        ),
        doc_md="CALL CURATED.SP_MERGE_* for all 8 dims/facts. Logged to AUDIT_CTL.ETL_RUN_LOG.",
    )

    generate_data >> upload_to_s3 >> load_raw >> load_staging >> merge_curated
