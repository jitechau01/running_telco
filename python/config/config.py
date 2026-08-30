"""
Central configuration for the Running Telco pipeline.
All secrets are read from environment variables - nothing sensitive is
hard-coded. Populate a .env file locally (see .env.example) or set these
as real environment variables / secrets in your orchestrator (Airflow,
ECS task definition, etc).
"""
import os
from dataclasses import dataclass, field


@dataclass
class SnowflakeConfig:
    account: str = os.getenv("SNOWFLAKE_ACCOUNT", "")
    user: str = os.getenv("SNOWFLAKE_USER", "")
    password: str = os.getenv("SNOWFLAKE_PASSWORD", "")
    private_key_path: str = os.getenv("SNOWFLAKE_PRIVATE_KEY_PATH", "")  # preferred over password for service accts
    role: str = os.getenv("SNOWFLAKE_ROLE", "R_DATA_ENGINEER")
    warehouse: str = os.getenv("SNOWFLAKE_WAREHOUSE", "WH_INGEST")
    database: str = os.getenv("SNOWFLAKE_DATABASE", "RUNNING_TELCO")
    schema: str = os.getenv("SNOWFLAKE_SCHEMA", "RAW")


@dataclass
class S3Config:
    bucket: str = os.getenv("S3_BUCKET", "running-telco-raw")
    region: str = os.getenv("AWS_REGION", "us-east-1")
    prefixes: dict = field(default_factory=lambda: {
        "customers": "customers/",
        "plans": "plans/",
        "devices": "devices/",
        "cdr": "cdr/",
        "billing": "billing/",
        "payments": "payments/",
        "towers": "towers/",
        "support_tickets": "support_tickets/",
    })


# Maps each source feed -> (RAW table, STAGING load procedure, S3 prefix key).
# "columns" is the exact ordered list of data columns in the RAW table that
# the source CSV populates - i.e. every column in the corresponding
# sql/01_raw_layer/tables_raw.sql table EXCEPT source_file_name (filled from
# METADATA$FILENAME) and _load_ts (has a DEFAULT). This list is what lets
# the orchestrator build a correct, per-feed COPY INTO with an explicit
# target column list instead of assuming every table is the same width.
FEED_REGISTRY = {
    "customers": {
        "raw_table": "RAW.RAW_CUSTOMERS", "proc": "STAGING.SP_LOAD_STG_CUSTOMERS",
        "job_name": "RAW_TO_STAGING_CUSTOMERS",
        "columns": ["customer_id", "first_name", "last_name", "date_of_birth", "national_id",
                    "email", "phone_number", "address_line1", "city", "region", "postal_code",
                    "plan_id", "activation_date", "account_status", "customer_segment", "credit_score"],
    },
    "plans": {
        "raw_table": "RAW.RAW_PLANS", "proc": "STAGING.SP_LOAD_STG_PLANS",
        "job_name": "RAW_TO_STAGING_PLANS",
        "columns": ["plan_id", "plan_name", "plan_type", "monthly_fee", "data_limit_gb",
                    "voice_minutes", "sms_count", "currency", "effective_date"],
    },
    "devices": {
        "raw_table": "RAW.RAW_DEVICES", "proc": "STAGING.SP_LOAD_STG_DEVICES",
        "job_name": "RAW_TO_STAGING_DEVICES",
        "columns": ["device_id", "imei", "customer_id", "device_model", "device_os",
                    "activation_date", "device_status"],
    },
    "cdr": {
        "raw_table": "RAW.RAW_CDR", "proc": "STAGING.SP_LOAD_STG_CDR",
        "job_name": "RAW_TO_STAGING_CDR",
        "columns": ["cdr_id", "customer_id", "call_type", "origin_number", "destination_number",
                    "cell_tower_id", "call_start_ts", "call_end_ts", "duration_seconds",
                    "data_volume_mb", "roaming_flag", "region"],
    },
    "billing": {
        "raw_table": "RAW.RAW_BILLING", "proc": "STAGING.SP_LOAD_STG_BILLING",
        "job_name": "RAW_TO_STAGING_BILLING",
        "columns": ["invoice_id", "customer_id", "billing_period", "plan_id", "usage_charges",
                    "tax_amount", "total_amount", "invoice_date", "due_date", "invoice_status"],
    },
    "payments": {
        "raw_table": "RAW.RAW_PAYMENTS", "proc": "STAGING.SP_LOAD_STG_PAYMENTS",
        "job_name": "RAW_TO_STAGING_PAYMENTS",
        "columns": ["payment_id", "invoice_id", "customer_id", "payment_date", "amount",
                    "payment_method", "card_last4", "payment_status"],
    },
    "towers": {
        "raw_table": "RAW.RAW_TOWERS", "proc": "STAGING.SP_LOAD_STG_TOWERS",
        "job_name": "RAW_TO_STAGING_TOWERS",
        "columns": ["tower_id", "region", "latitude", "longitude", "capacity_mbps", "tower_status"],
    },
    "support_tickets": {
        "raw_table": "RAW.RAW_SUPPORT_TICKETS", "proc": "STAGING.SP_LOAD_STG_SUPPORT_TICKETS",
        "job_name": "RAW_TO_STAGING_SUPPORT_TICKETS",
        "columns": ["ticket_id", "customer_id", "opened_at", "closed_at", "category",
                    "priority", "ticket_status", "channel"],
    },
}

CURATED_MERGE_PROCS = [
    ("STAGING_TO_CURATED_DIM_CUSTOMER", "CURATED.SP_MERGE_DIM_CUSTOMER"),
    ("STAGING_TO_CURATED_DIM_PLAN", "CURATED.SP_MERGE_DIM_PLAN"),
    ("STAGING_TO_CURATED_DIM_DEVICE", "CURATED.SP_MERGE_DIM_DEVICE"),
    ("STAGING_TO_CURATED_DIM_TOWER", "CURATED.SP_MERGE_DIM_TOWER"),
    ("STAGING_TO_CURATED_FACT_CDR", "CURATED.SP_MERGE_FACT_CDR_USAGE"),
    ("STAGING_TO_CURATED_FACT_BILLING", "CURATED.SP_MERGE_FACT_BILLING"),
    ("STAGING_TO_CURATED_FACT_PAYMENTS", "CURATED.SP_MERGE_FACT_PAYMENTS"),
    ("STAGING_TO_CURATED_FACT_TICKETS", "CURATED.SP_MERGE_FACT_SUPPORT_TICKETS"),
]
