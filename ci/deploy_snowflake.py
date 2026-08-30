"""
ci/deploy_snowflake.py

Deploys every SQL file in sql/ to Snowflake, in the same dependency order as
deploy.sh, using the Python connector directly instead of the snowsql binary.
This is what a GitHub Actions runner calls - it's simpler to `pip install`
a Python package into a fresh Ubuntu runner than to install and configure
the snowsql CLI binary just for CI.

Uses connection.execute_string() (not naive semicolon-splitting) so that
stored procedure bodies delimited with $$ ... $$ - which contain their own
semicolons - are parsed correctly as ONE statement, not split apart.

Credentials come entirely from environment variables (populated from GitHub
Actions secrets in the workflow) - key-pair auth, matching how the local
Python orchestrator authenticates (see python/config/config.py). Never uses
a password in CI.

Required environment variables:
    SNOWFLAKE_ACCOUNT
    SNOWFLAKE_USER
    SNOWFLAKE_ROLE          e.g. R_TELECOM_ADMIN or ACCOUNTADMIN for first deploy
    SNOWFLAKE_WAREHOUSE     e.g. WH_INGEST
    SNOWFLAKE_PRIVATE_KEY   the RSA private key PEM contents (not a file path -
                            GitHub Actions secrets are text, not files)

Usage:
    python ci/deploy_snowflake.py
"""
import os
import sys

import snowflake.connector
from cryptography.hazmat.primitives import serialization

# Exact same order as deploy.sh - keep these two in sync if you add a file.
FILES = [
    "sql/00_setup/01_databases_schemas.sql",
    "sql/00_setup/02_warehouses_roles.sql",
    "sql/00_setup/03_file_formats_stages.sql",
    "sql/01_raw_layer/tables_raw.sql",
    "sql/01_raw_layer/02_snowpipe.sql",
    "sql/02_staging_layer/tables_staging.sql",
    "sql/03_curated_layer/tables_curated.sql",
    "sql/08_audit_control/01_control_tables.sql",
    "sql/08_audit_control/02_audit_procedures.sql",
    "sql/04_procedures/01_sp_raw_to_staging.sql",
    "sql/04_procedures/02_sp_staging_to_curated.sql",
    "sql/06_governance/01_tags.sql",
    "sql/06_governance/02_masking_policies.sql",
    "sql/06_governance/03_row_access_policies.sql",
    "sql/07_data_sharing/01_secure_views_and_share.sql",
    "sql/05_tasks/task_tree.sql",
]


def load_private_key(pem_text: str) -> bytes:
    """GitHub Actions secrets store the PEM as plain text (with literal
    newlines). Parse it with the cryptography library and re-serialize to
    the DER bytes format the Snowflake connector's private_key param expects."""
    key = serialization.load_pem_private_key(pem_text.encode(), password=None)
    return key.private_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )


def main():
    required = ["SNOWFLAKE_ACCOUNT", "SNOWFLAKE_USER", "SNOWFLAKE_ROLE",
                "SNOWFLAKE_WAREHOUSE", "SNOWFLAKE_PRIVATE_KEY"]
    missing = [v for v in required if not os.getenv(v)]
    if missing:
        print(f"ERROR: missing required environment variable(s): {', '.join(missing)}")
        sys.exit(1)

    private_key_bytes = load_private_key(os.environ["SNOWFLAKE_PRIVATE_KEY"])

    conn = snowflake.connector.connect(
        account=os.environ["SNOWFLAKE_ACCOUNT"],
        user=os.environ["SNOWFLAKE_USER"],
        role=os.environ["SNOWFLAKE_ROLE"],
        warehouse=os.environ["SNOWFLAKE_WAREHOUSE"],
        private_key=private_key_bytes,
    )
    print(f"Connected: account={os.environ['SNOWFLAKE_ACCOUNT']} role={os.environ['SNOWFLAKE_ROLE']}")

    try:
        for path in FILES:
            print("=" * 70)
            print(f">> Deploying: {path}")
            print("=" * 70)
            with open(path) as f:
                sql_text = f.read()

            # execute_string handles multiple statements per file correctly,
            # including $$ ... $$ delimited procedure bodies.
            cursors = conn.execute_string(sql_text)
            for cur in cursors:
                for row in cur:
                    print(row)
    except Exception as e:
        print(f"DEPLOYMENT FAILED at {path}: {e}")
        sys.exit(1)
    finally:
        conn.close()

    print("=" * 70)
    print("ALL FILES DEPLOYED SUCCESSFULLY")
    print("=" * 70)


if __name__ == "__main__":
    main()
