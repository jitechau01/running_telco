#!/usr/bin/env bash
# ==============================================================================
# deploy.sh - deploys the full Running Telco Snowflake object graph in the
# correct dependency order using SnowSQL. Idempotent: every DDL script uses
# CREATE ... IF NOT EXISTS / CREATE OR REPLACE, safe to re-run.
#
# Prereqs:
#   - snowsql CLI installed and configured (~/.snowsql/config)
#   - a role with ACCOUNTADMIN or SECURITYADMIN+SYSADMIN privileges for the
#     one-time setup steps (warehouses, roles, storage integration, share).
#     If no ACCOUNTADMIN user exists in your account, see the README section
#     "Deploying without ACCOUNTADMIN access" for the alternative pattern.
#
# Usage:
#   ./deploy.sh <connection_name>
#   e.g. ./deploy.sh runningtelco_prod   (must exist in ~/.snowsql/config)
# ==============================================================================
set -euo pipefail

CONN="${1:?Usage: ./deploy.sh <snowsql_connection_name>}"

FILES=(
  "sql/00_setup/01_databases_schemas.sql"
  "sql/00_setup/02_warehouses_roles.sql"
  "sql/00_setup/03_file_formats_stages.sql"
  "sql/01_raw_layer/tables_raw.sql"
  "sql/01_raw_layer/02_snowpipe.sql"
  "sql/02_staging_layer/tables_staging.sql"
  "sql/03_curated_layer/tables_curated.sql"
  "sql/08_audit_control/01_control_tables.sql"
  "sql/08_audit_control/02_audit_procedures.sql"
  "sql/04_procedures/01_sp_raw_to_staging.sql"
  "sql/04_procedures/02_sp_staging_to_curated.sql"
  "sql/06_governance/01_tags.sql"
  "sql/06_governance/02_masking_policies.sql"
  "sql/06_governance/03_row_access_policies.sql"
  "sql/07_data_sharing/01_secure_views_and_share.sql"
  "sql/05_tasks/task_tree.sql"
)

for f in "${FILES[@]}"; do
  echo "=============================================================="
  echo ">> Deploying: $f"
  echo "=============================================================="
  snowsql -c "$CONN" -f "$f" -o echo=true --abort-detached-query -o exit_on_error=true
done

echo "Deployment complete. Verify with:"
echo "  SHOW TASKS IN SCHEMA RUNNING_TELCO.ORCHESTRATION;"
echo "  SELECT * FROM RUNNING_TELCO.AUDIT_CTL.VW_LATEST_RUN_STATUS;"
