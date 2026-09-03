
/* ==========================================================================
   RUNNING TELCO — SNOWFLAKE FOUNDATION SETUP
   Databases / Schemas
   Layering:
     RAW           -> exact copy of source files (S3), append-only, VARIANT/typed
     STAGING       -> typed, deduped, streams enabled for CDC
     CURATED       -> conformed dimensional model (facts/dims) used by BI/analytics
     AUDIT_CTL     -> audit & control framework (run log, error log, job master)
     ORCHESTRATION -> all TASK objects (must share one schema per DAG - see below)
     GOVERNANCE    -> tag definitions, masking policies, row access policies
     SHARE_OUT     -> secure views exposed via Snowflake Secure Data Sharing
   ========================================================================== */

CREATE DATABASE IF NOT EXISTS RUNNING_TELCO
  COMMENT = 'Running Telco - End to end Snowflake platform (RAW/STAGING/CURATED/GOVERNANCE/AUDIT/SHARE)';


USE DATABASE RUNNING_TELCO;

CREATE SCHEMA IF NOT EXISTS RAW
  COMMENT = 'Landing layer - 1:1 with source files from S3, append only';

CREATE SCHEMA IF NOT EXISTS STAGING
  COMMENT = 'Typed/cleaned staging layer, streams enabled for CDC into CURATED';

CREATE SCHEMA IF NOT EXISTS CURATED
  COMMENT = 'Conformed dimensional model - facts and dimensions for BI/analytics';

CREATE SCHEMA IF NOT EXISTS AUDIT_CTL
  COMMENT = 'Audit & Control framework - job master, run log, error log, stats';

CREATE SCHEMA IF NOT EXISTS ORCHESTRATION
  COMMENT = 'All TASK objects live here. Snowflake requires every task chained via AFTER in one DAG to share a schema, so root load tasks and downstream merge tasks are both created here even though the procedures they CALL live in STAGING/CURATED.';

CREATE SCHEMA IF NOT EXISTS GOVERNANCE
  COMMENT = 'Tag definitions, masking policies, row access policies';

CREATE SCHEMA IF NOT EXISTS SHARE_OUT
  COMMENT = 'Secure views published to external consumers via Data Sharing';

