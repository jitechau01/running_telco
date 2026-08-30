/* ============================================================================
   RUNNING TELCO — CONSOLIDATED DEPLOYMENT SCRIPT
   All 16 files from sql/, concatenated in the exact order deploy.sh runs them.
   Each section is marked with a SELECT '>>> ...' statement so that if a
   statement fails, the LAST marker printed before the error tells you which
   original file you were in - same idea as running snowsql with -o echo=true,
   just visible without extra flags.

   ONE-TIME BOOTSTRAP (LEAD_ROLE only - already ACCOUNTADMIN/SYSADMIN callers
   can skip straight to the first marker below):
     USE ROLE ACCOUNTADMIN;
     GRANT ROLE SYSADMIN      TO ROLE LEAD_ROLE;
     GRANT ROLE SECURITYADMIN TO ROLE LEAD_ROLE;
   Run those two lines once, as ACCOUNTADMIN, before running this file the
   first time. Everything below this point is designed to run under
   LEAD_ROLE (or any role holding SYSADMIN+SECURITYADMIN) with no further
   ACCOUNTADMIN involvement, including on repeat/idempotent re-runs.
   ============================================================================ */

SELECT '>>> START: 00_setup/01_databases_schemas.sql' AS deploy_marker;

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

SELECT '>>> END: 01_databases_schemas.sql | START: 00_setup/02_warehouses_roles.sql' AS deploy_marker;

/* ==========================================================================
   WAREHOUSES
   ========================================================================== */
CREATE WAREHOUSE IF NOT EXISTS WH_INGEST
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE
  COMMENT = 'Used by Snowpipe / COPY INTO / staging loads';

CREATE WAREHOUSE IF NOT EXISTS WH_TRANSFORM
  WAREHOUSE_SIZE = 'SMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE
  COMMENT = 'Used by tasks/procedures for STAGING -> CURATED transforms';

CREATE WAREHOUSE IF NOT EXISTS WH_BI
  WAREHOUSE_SIZE = 'SMALL'
  AUTO_SUSPEND = 300
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE
  COMMENT = 'Used by BI/analysts/reader accounts querying CURATED/SHARE_OUT';

/* ==========================================================================
   FUNCTIONAL ROLES (RBAC)
   ========================================================================== */
CREATE ROLE IF NOT EXISTS R_TELECOM_ADMIN;
CREATE ROLE IF NOT EXISTS R_DATA_ENGINEER;
CREATE ROLE IF NOT EXISTS R_DATA_GOVERNANCE;
CREATE ROLE IF NOT EXISTS R_ANALYST_NORTH;
CREATE ROLE IF NOT EXISTS R_ANALYST_SOUTH;
CREATE ROLE IF NOT EXISTS R_ANALYST_GLOBAL;
CREATE ROLE IF NOT EXISTS R_COMPLIANCE_OFFICER;

GRANT ROLE R_DATA_ENGINEER      TO ROLE R_TELECOM_ADMIN;
GRANT ROLE R_DATA_GOVERNANCE    TO ROLE R_TELECOM_ADMIN;
GRANT ROLE R_ANALYST_GLOBAL     TO ROLE R_TELECOM_ADMIN;
GRANT ROLE R_COMPLIANCE_OFFICER TO ROLE R_TELECOM_ADMIN;
GRANT ROLE R_TELECOM_ADMIN      TO ROLE SYSADMIN;

-- Warehouse usage grants
GRANT USAGE ON WAREHOUSE WH_INGEST    TO ROLE R_DATA_ENGINEER;
GRANT USAGE ON WAREHOUSE WH_TRANSFORM TO ROLE R_DATA_ENGINEER;
GRANT USAGE ON WAREHOUSE WH_BI        TO ROLE R_ANALYST_NORTH;
GRANT USAGE ON WAREHOUSE WH_BI        TO ROLE R_ANALYST_SOUTH;
GRANT USAGE ON WAREHOUSE WH_BI        TO ROLE R_ANALYST_GLOBAL;
GRANT USAGE ON WAREHOUSE WH_BI        TO ROLE R_COMPLIANCE_OFFICER;

-- Database/Schema usage
GRANT USAGE ON DATABASE RUNNING_TELCO TO ROLE R_DATA_ENGINEER;
GRANT USAGE ON DATABASE RUNNING_TELCO TO ROLE R_DATA_GOVERNANCE;
GRANT USAGE ON DATABASE RUNNING_TELCO TO ROLE R_ANALYST_NORTH;
GRANT USAGE ON DATABASE RUNNING_TELCO TO ROLE R_ANALYST_SOUTH;
GRANT USAGE ON DATABASE RUNNING_TELCO TO ROLE R_ANALYST_GLOBAL;
GRANT USAGE ON DATABASE RUNNING_TELCO TO ROLE R_COMPLIANCE_OFFICER;

GRANT USAGE ON SCHEMA RUNNING_TELCO.RAW           TO ROLE R_DATA_ENGINEER;
GRANT USAGE ON SCHEMA RUNNING_TELCO.STAGING       TO ROLE R_DATA_ENGINEER;
GRANT USAGE ON SCHEMA RUNNING_TELCO.CURATED       TO ROLE R_DATA_ENGINEER;
GRANT USAGE ON SCHEMA RUNNING_TELCO.CURATED       TO ROLE R_ANALYST_NORTH;
GRANT USAGE ON SCHEMA RUNNING_TELCO.CURATED       TO ROLE R_ANALYST_SOUTH;
GRANT USAGE ON SCHEMA RUNNING_TELCO.CURATED       TO ROLE R_ANALYST_GLOBAL;
GRANT USAGE ON SCHEMA RUNNING_TELCO.CURATED       TO ROLE R_COMPLIANCE_OFFICER;
GRANT USAGE ON SCHEMA RUNNING_TELCO.AUDIT_CTL     TO ROLE R_DATA_ENGINEER;
GRANT USAGE ON SCHEMA RUNNING_TELCO.ORCHESTRATION TO ROLE R_DATA_ENGINEER;
GRANT USAGE ON SCHEMA RUNNING_TELCO.GOVERNANCE    TO ROLE R_DATA_GOVERNANCE;
GRANT USAGE ON SCHEMA RUNNING_TELCO.GOVERNANCE    TO ROLE R_DATA_ENGINEER;
GRANT USAGE ON SCHEMA RUNNING_TELCO.SHARE_OUT     TO ROLE R_DATA_ENGINEER;

/* ==========================================================================
   CREATE-OBJECT PRIVILEGES
   ========================================================================== */
GRANT CREATE TABLE, CREATE VIEW, CREATE FILE FORMAT, CREATE STAGE, CREATE PIPE,
      CREATE STREAM, CREATE PROCEDURE, CREATE FUNCTION, CREATE SEQUENCE
  ON SCHEMA RUNNING_TELCO.RAW TO ROLE R_DATA_ENGINEER;

GRANT CREATE TABLE, CREATE VIEW, CREATE FILE FORMAT, CREATE STAGE, CREATE PIPE,
      CREATE STREAM, CREATE PROCEDURE, CREATE FUNCTION, CREATE SEQUENCE
  ON SCHEMA RUNNING_TELCO.STAGING TO ROLE R_DATA_ENGINEER;

GRANT CREATE TABLE, CREATE VIEW, CREATE FILE FORMAT, CREATE STAGE, CREATE PIPE,
      CREATE STREAM, CREATE PROCEDURE, CREATE FUNCTION, CREATE SEQUENCE
  ON SCHEMA RUNNING_TELCO.CURATED TO ROLE R_DATA_ENGINEER;

GRANT CREATE TABLE, CREATE VIEW, CREATE PROCEDURE, CREATE FUNCTION, CREATE SEQUENCE
  ON SCHEMA RUNNING_TELCO.AUDIT_CTL TO ROLE R_DATA_ENGINEER;

GRANT CREATE TASK ON SCHEMA RUNNING_TELCO.ORCHESTRATION TO ROLE R_DATA_ENGINEER;

GRANT CREATE TABLE, CREATE VIEW, CREATE PROCEDURE
  ON SCHEMA RUNNING_TELCO.SHARE_OUT TO ROLE R_DATA_ENGINEER;

GRANT CREATE TAG, CREATE MASKING POLICY, CREATE ROW ACCESS POLICY, CREATE TABLE
  ON SCHEMA RUNNING_TELCO.GOVERNANCE TO ROLE R_DATA_GOVERNANCE;

-- CREATE INTEGRATION / CREATE SHARE ON ACCOUNT are removed here deliberately.
-- Redistributing an account-level privilege to another role requires either
-- ACCOUNTADMIN or holding that privilege WITH GRANT OPTION - LEAD_ROLE has
-- neither, and this environment has no ACCOUNTADMIN user. Workarounds below:
--   CREATE INTEGRATION: LEAD_ROLE already holds this directly (confirmed via
--     SHOW GRANTS), so the storage integration is created AS LEAD_ROLE
--     further down (see 03_file_formats_stages.sql section), then USAGE on
--     that one object is granted to R_DATA_ENGINEER - an ordinary
--     object-level grant, no account-level redistribution needed.
--   CREATE SHARE: LEAD_ROLE does not hold this privilege at all (not
--     inherited from SYSADMIN or SECURITYADMIN). Outbound Secure Data
--     Sharing genuinely cannot be provisioned without ACCOUNTADMIN in this
--     environment. The 07_data_sharing/01_secure_views_and_share.sql section
--     further down is split so the secure VIEWs still deploy (ordinary
--     CREATE VIEW privilege, already granted) - only the final CREATE SHARE
--     statement is skipped/deferred until ACCOUNTADMIN access is available.

/* ==========================================================================
   LEAD_ROLE SELF-GRANT — makes every USE ROLE switch later in this script
   (R_DATA_ENGINEER, R_DATA_GOVERNANCE, R_TELECOM_ADMIN) assumable by
   LEAD_ROLE without any further ACCOUNTADMIN involvement. Safe/idempotent
   to re-run. Comment this out if you are running as ACCOUNTADMIN directly.
   ========================================================================== */
GRANT ROLE R_TELECOM_ADMIN TO ROLE LEAD_ROLE;

SELECT '>>> END: 02_warehouses_roles.sql | START: 00_setup/03_file_formats_stages.sql' AS deploy_marker;

USE DATABASE RUNNING_TELCO;
USE SCHEMA RAW;
USE ROLE R_DATA_ENGINEER;
USE WAREHOUSE WH_INGEST;

/* ==========================================================================
   FILE FORMATS
   ========================================================================== */
CREATE FILE FORMAT IF NOT EXISTS RAW.FF_CSV_STANDARD
  TYPE = 'CSV'
  FIELD_DELIMITER = ','
  SKIP_HEADER = 1
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  NULL_IF = ('', 'NULL', 'null', 'NA')
  EMPTY_FIELD_AS_NULL = TRUE
  DATE_FORMAT = 'YYYY-MM-DD'
  TIMESTAMP_FORMAT = 'YYYY-MM-DD HH24:MI:SS'
  COMPRESSION = 'AUTO'
  ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE;

CREATE FILE FORMAT IF NOT EXISTS RAW.FF_JSON_STANDARD
  TYPE = 'JSON'
  STRIP_OUTER_ARRAY = TRUE
  COMPRESSION = 'AUTO';

/* ==========================================================================
   STORAGE INTEGRATION (AWS S3)
   Created AS LEAD_ROLE specifically - it is the only role in this account
   that holds CREATE INTEGRATION (confirmed via SHOW GRANTS TO ROLE LEAD_ROLE).
   R_DATA_ENGINEER cannot hold this privilege in this environment (no
   ACCOUNTADMIN available to redistribute it), so instead LEAD_ROLE creates
   the ONE integration object and grants USAGE on that specific object down
   to R_DATA_ENGINEER - an ordinary object-level grant, not an account-level
   privilege redistribution, so it works under LEAD_ROLE's ownership.
   ========================================================================== */
USE ROLE LEAD_ROLE;

CREATE STORAGE INTEGRATION IF NOT EXISTS S3_RUNNINGTELCO_INT
  TYPE = EXTERNAL_STAGE
  STORAGE_PROVIDER = 'S3'
  ENABLED = TRUE
  STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::<AWS_ACCOUNT_ID>:role/snowflake-runningtelco-s3-role'
  STORAGE_ALLOWED_LOCATIONS = (
      's3://running-telco-raw/customers/',
      's3://running-telco-raw/plans/',
      's3://running-telco-raw/devices/',
      's3://running-telco-raw/cdr/',
      's3://running-telco-raw/billing/',
      's3://running-telco-raw/payments/',
      's3://running-telco-raw/towers/',
      's3://running-telco-raw/support_tickets/'
  )
  COMMENT = 'Storage integration for Running Telco raw S3 landing bucket';

GRANT USAGE ON INTEGRATION S3_RUNNINGTELCO_INT TO ROLE R_DATA_ENGINEER;

USE ROLE R_DATA_ENGINEER;

-- DESC INTEGRATION S3_RUNNINGTELCO_INT;  -- copy STORAGE_AWS_IAM_USER_ARN + STORAGE_AWS_EXTERNAL_ID into AWS trust policy

/* ==========================================================================
   EXTERNAL STAGES
   ========================================================================== */
CREATE STAGE IF NOT EXISTS RAW.STG_CUSTOMERS
  URL = 's3://running-telco-raw/customers/'
  STORAGE_INTEGRATION = S3_RUNNINGTELCO_INT
  FILE_FORMAT = RAW.FF_CSV_STANDARD
  DIRECTORY = (ENABLE = TRUE)
  COMMENT = 'Customer master extract feed - daily full/delta CSV from CRM';

CREATE STAGE IF NOT EXISTS RAW.STG_PLANS
  URL = 's3://running-telco-raw/plans/'
  STORAGE_INTEGRATION = S3_RUNNINGTELCO_INT
  FILE_FORMAT = RAW.FF_CSV_STANDARD
  DIRECTORY = (ENABLE = TRUE);

CREATE STAGE IF NOT EXISTS RAW.STG_DEVICES
  URL = 's3://running-telco-raw/devices/'
  STORAGE_INTEGRATION = S3_RUNNINGTELCO_INT
  FILE_FORMAT = RAW.FF_CSV_STANDARD
  DIRECTORY = (ENABLE = TRUE);

CREATE STAGE IF NOT EXISTS RAW.STG_CDR
  URL = 's3://running-telco-raw/cdr/'
  STORAGE_INTEGRATION = S3_RUNNINGTELCO_INT
  FILE_FORMAT = RAW.FF_CSV_STANDARD
  DIRECTORY = (ENABLE = TRUE)
  COMMENT = 'Call Detail Records - high volume hourly drops from mediation platform';

CREATE STAGE IF NOT EXISTS RAW.STG_BILLING
  URL = 's3://running-telco-raw/billing/'
  STORAGE_INTEGRATION = S3_RUNNINGTELCO_INT
  FILE_FORMAT = RAW.FF_CSV_STANDARD
  DIRECTORY = (ENABLE = TRUE);

CREATE STAGE IF NOT EXISTS RAW.STG_PAYMENTS
  URL = 's3://running-telco-raw/payments/'
  STORAGE_INTEGRATION = S3_RUNNINGTELCO_INT
  FILE_FORMAT = RAW.FF_CSV_STANDARD
  DIRECTORY = (ENABLE = TRUE);

CREATE STAGE IF NOT EXISTS RAW.STG_TOWERS
  URL = 's3://running-telco-raw/towers/'
  STORAGE_INTEGRATION = S3_RUNNINGTELCO_INT
  FILE_FORMAT = RAW.FF_CSV_STANDARD
  DIRECTORY = (ENABLE = TRUE);

CREATE STAGE IF NOT EXISTS RAW.STG_SUPPORT_TICKETS
  URL = 's3://running-telco-raw/support_tickets/'
  STORAGE_INTEGRATION = S3_RUNNINGTELCO_INT
  FILE_FORMAT = RAW.FF_CSV_STANDARD
  DIRECTORY = (ENABLE = TRUE);

-- NOTE: Snowpipe (PIPE_CDR) is NOT created here - it COPY INTOs RAW.RAW_CDR,
-- which doesn't exist until the RAW tables section below runs. See the
-- "02_snowpipe.sql" section further down, deployed right after RAW tables.

SELECT '>>> END: 03_file_formats_stages.sql | START: 01_raw_layer/tables_raw.sql' AS deploy_marker;

USE DATABASE RUNNING_TELCO;
USE SCHEMA RAW;

CREATE TABLE IF NOT EXISTS RAW.RAW_CUSTOMERS (
    customer_id        VARCHAR(20),
    first_name         VARCHAR(100),
    last_name          VARCHAR(100),
    date_of_birth      VARCHAR(20),
    national_id        VARCHAR(30),
    email               VARCHAR(200),
    phone_number        VARCHAR(30),
    address_line1       VARCHAR(200),
    city                VARCHAR(100),
    region              VARCHAR(50),
    postal_code         VARCHAR(20),
    plan_id             VARCHAR(20),
    activation_date     VARCHAR(20),
    account_status      VARCHAR(20),
    customer_segment    VARCHAR(30),
    credit_score        VARCHAR(10),
    source_file_name    VARCHAR(500),
    _load_ts            TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS RAW.RAW_PLANS (
    plan_id             VARCHAR(20),
    plan_name           VARCHAR(100),
    plan_type           VARCHAR(20),
    monthly_fee         VARCHAR(20),
    data_limit_gb       VARCHAR(20),
    voice_minutes       VARCHAR(20),
    sms_count           VARCHAR(20),
    currency            VARCHAR(10),
    effective_date      VARCHAR(20),
    source_file_name    VARCHAR(500),
    _load_ts            TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS RAW.RAW_DEVICES (
    device_id           VARCHAR(20),
    imei                VARCHAR(30),
    customer_id         VARCHAR(20),
    device_model        VARCHAR(100),
    device_os           VARCHAR(50),
    activation_date     VARCHAR(20),
    device_status       VARCHAR(20),
    source_file_name    VARCHAR(500),
    _load_ts            TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS RAW.RAW_CDR (
    cdr_id               VARCHAR(40),
    customer_id          VARCHAR(20),
    call_type            VARCHAR(10),
    origin_number        VARCHAR(30),
    destination_number   VARCHAR(30),
    cell_tower_id        VARCHAR(20),
    call_start_ts        VARCHAR(30),
    call_end_ts          VARCHAR(30),
    duration_seconds     VARCHAR(20),
    data_volume_mb       VARCHAR(20),
    roaming_flag         VARCHAR(5),
    region               VARCHAR(50),
    source_file_name     VARCHAR(500),
    _load_ts             TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS RAW.RAW_BILLING (
    invoice_id          VARCHAR(20),
    customer_id         VARCHAR(20),
    billing_period      VARCHAR(10),
    plan_id             VARCHAR(20),
    usage_charges       VARCHAR(20),
    tax_amount          VARCHAR(20),
    total_amount        VARCHAR(20),
    invoice_date        VARCHAR(20),
    due_date            VARCHAR(20),
    invoice_status      VARCHAR(20),
    source_file_name    VARCHAR(500),
    _load_ts            TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS RAW.RAW_PAYMENTS (
    payment_id          VARCHAR(20),
    invoice_id          VARCHAR(20),
    customer_id         VARCHAR(20),
    payment_date        VARCHAR(20),
    amount              VARCHAR(20),
    payment_method      VARCHAR(30),
    card_last4          VARCHAR(10),
    payment_status      VARCHAR(20),
    source_file_name    VARCHAR(500),
    _load_ts            TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS RAW.RAW_TOWERS (
    tower_id            VARCHAR(20),
    region              VARCHAR(50),
    latitude            VARCHAR(20),
    longitude           VARCHAR(20),
    capacity_mbps       VARCHAR(20),
    tower_status        VARCHAR(20),
    source_file_name    VARCHAR(500),
    _load_ts            TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS RAW.RAW_SUPPORT_TICKETS (
    ticket_id           VARCHAR(20),
    customer_id         VARCHAR(20),
    opened_at           VARCHAR(30),
    closed_at           VARCHAR(30),
    category            VARCHAR(50),
    priority             VARCHAR(10),
    ticket_status         VARCHAR(20),
    channel               VARCHAR(20),
    source_file_name    VARCHAR(500),
    _load_ts            TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

SELECT '>>> END: tables_raw.sql | START: 01_raw_layer/02_snowpipe.sql' AS deploy_marker;

USE DATABASE RUNNING_TELCO;
USE SCHEMA RAW;
USE ROLE R_DATA_ENGINEER;

CREATE PIPE IF NOT EXISTS RAW.PIPE_CDR
  AUTO_INGEST = TRUE
  COMMENT = 'Auto-ingest CDR files landing in s3://running-telco-raw/cdr/'
  AS
  COPY INTO RAW.RAW_CDR
  FROM @RAW.STG_CDR
  FILE_FORMAT = (FORMAT_NAME = RAW.FF_CSV_STANDARD)
  ON_ERROR = 'CONTINUE';

-- SHOW PIPES; -- copy notification_channel (SQS ARN) into the S3 bucket event notification config

SELECT '>>> END: 02_snowpipe.sql | START: 02_staging_layer/tables_staging.sql' AS deploy_marker;

USE DATABASE RUNNING_TELCO;
USE SCHEMA STAGING;

CREATE TABLE IF NOT EXISTS STAGING.STG_CUSTOMERS (
    customer_id        VARCHAR(20)     NOT NULL,
    first_name         VARCHAR(100),
    last_name           VARCHAR(100),
    date_of_birth       DATE,
    national_id         VARCHAR(30),
    email                VARCHAR(200),
    phone_number         VARCHAR(30),
    address_line1        VARCHAR(200),
    city                 VARCHAR(100),
    region               VARCHAR(50),
    postal_code          VARCHAR(20),
    plan_id              VARCHAR(20),
    activation_date      DATE,
    account_status       VARCHAR(20),
    customer_segment     VARCHAR(30),
    credit_score         NUMBER(5,0),
    updated_at           TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT PK_STG_CUSTOMERS PRIMARY KEY (customer_id)
);

CREATE TABLE IF NOT EXISTS STAGING.STG_PLANS (
    plan_id             VARCHAR(20)     NOT NULL,
    plan_name           VARCHAR(100),
    plan_type            VARCHAR(20),
    monthly_fee          NUMBER(10,2),
    data_limit_gb         NUMBER(10,2),
    voice_minutes          NUMBER(10,0),
    sms_count               NUMBER(10,0),
    currency                 VARCHAR(10),
    effective_date            DATE,
    updated_at                  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT PK_STG_PLANS PRIMARY KEY (plan_id)
);

CREATE TABLE IF NOT EXISTS STAGING.STG_DEVICES (
    device_id           VARCHAR(20)     NOT NULL,
    imei                VARCHAR(30),
    customer_id          VARCHAR(20),
    device_model          VARCHAR(100),
    device_os               VARCHAR(50),
    activation_date          DATE,
    device_status              VARCHAR(20),
    updated_at                   TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT PK_STG_DEVICES PRIMARY KEY (device_id)
);

CREATE TABLE IF NOT EXISTS STAGING.STG_CDR (
    cdr_id                VARCHAR(40)   NOT NULL,
    customer_id           VARCHAR(20),
    call_type              VARCHAR(10),
    origin_number           VARCHAR(30),
    destination_number       VARCHAR(30),
    cell_tower_id              VARCHAR(20),
    call_start_ts                TIMESTAMP_NTZ,
    call_end_ts                    TIMESTAMP_NTZ,
    duration_seconds                 NUMBER(10,0),
    data_volume_mb                     NUMBER(12,3),
    roaming_flag                         BOOLEAN,
    region                                 VARCHAR(50),
    updated_at                               TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT PK_STG_CDR PRIMARY KEY (cdr_id)
);

CREATE TABLE IF NOT EXISTS STAGING.STG_BILLING (
    invoice_id          VARCHAR(20)     NOT NULL,
    customer_id         VARCHAR(20),
    billing_period       VARCHAR(10),
    plan_id               VARCHAR(20),
    usage_charges           NUMBER(12,2),
    tax_amount                 NUMBER(12,2),
    total_amount                  NUMBER(12,2),
    invoice_date                    DATE,
    due_date                          DATE,
    invoice_status                      VARCHAR(20),
    updated_at                            TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT PK_STG_BILLING PRIMARY KEY (invoice_id)
);

CREATE TABLE IF NOT EXISTS STAGING.STG_PAYMENTS (
    payment_id           VARCHAR(20)    NOT NULL,
    invoice_id            VARCHAR(20),
    customer_id             VARCHAR(20),
    payment_date               DATE,
    amount                        NUMBER(12,2),
    payment_method                   VARCHAR(30),
    card_last4                          VARCHAR(10),
    payment_status                        VARCHAR(20),
    updated_at                              TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT PK_STG_PAYMENTS PRIMARY KEY (payment_id)
);

CREATE TABLE IF NOT EXISTS STAGING.STG_TOWERS (
    tower_id            VARCHAR(20)     NOT NULL,
    region              VARCHAR(50),
    latitude             NUMBER(9,6),
    longitude              NUMBER(9,6),
    capacity_mbps             NUMBER(10,0),
    tower_status                 VARCHAR(20),
    updated_at                     TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT PK_STG_TOWERS PRIMARY KEY (tower_id)
);

CREATE TABLE IF NOT EXISTS STAGING.STG_SUPPORT_TICKETS (
    ticket_id           VARCHAR(20)     NOT NULL,
    customer_id         VARCHAR(20),
    opened_at            TIMESTAMP_NTZ,
    closed_at              TIMESTAMP_NTZ,
    category                 VARCHAR(50),
    priority                    VARCHAR(10),
    ticket_status                  VARCHAR(20),
    channel                          VARCHAR(20),
    updated_at                         TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT PK_STG_SUPPORT_TICKETS PRIMARY KEY (ticket_id)
);

/* ==========================================================================
   STREAMS
   ========================================================================== */
CREATE STREAM IF NOT EXISTS STAGING.STRM_CUSTOMERS
  ON TABLE STAGING.STG_CUSTOMERS
  APPEND_ONLY = FALSE
  COMMENT = 'CDC stream feeding CURATED.DIM_CUSTOMER (SCD2)';

CREATE STREAM IF NOT EXISTS STAGING.STRM_PLANS
  ON TABLE STAGING.STG_PLANS
  APPEND_ONLY = FALSE;

CREATE STREAM IF NOT EXISTS STAGING.STRM_DEVICES
  ON TABLE STAGING.STG_DEVICES
  APPEND_ONLY = FALSE;

CREATE STREAM IF NOT EXISTS STAGING.STRM_CDR
  ON TABLE STAGING.STG_CDR
  APPEND_ONLY = TRUE
  COMMENT = 'CDR is immutable/append-only - fact stream feeding FACT_CDR_USAGE';

CREATE STREAM IF NOT EXISTS STAGING.STRM_BILLING
  ON TABLE STAGING.STG_BILLING
  APPEND_ONLY = FALSE;

CREATE STREAM IF NOT EXISTS STAGING.STRM_PAYMENTS
  ON TABLE STAGING.STG_PAYMENTS
  APPEND_ONLY = FALSE;

CREATE STREAM IF NOT EXISTS STAGING.STRM_TOWERS
  ON TABLE STAGING.STG_TOWERS
  APPEND_ONLY = FALSE;

CREATE STREAM IF NOT EXISTS STAGING.STRM_SUPPORT_TICKETS
  ON TABLE STAGING.STG_SUPPORT_TICKETS
  APPEND_ONLY = FALSE;

SELECT '>>> END: tables_staging.sql | START: 03_curated_layer/tables_curated.sql' AS deploy_marker;

USE DATABASE RUNNING_TELCO;
USE SCHEMA CURATED;

CREATE TABLE IF NOT EXISTS CURATED.DIM_CUSTOMER (
    customer_sk         NUMBER AUTOINCREMENT START 1 INCREMENT 1,
    customer_id         VARCHAR(20)     NOT NULL,
    first_name          VARCHAR(100),
    last_name            VARCHAR(100),
    date_of_birth         DATE,
    national_id            VARCHAR(30),
    email                    VARCHAR(200),
    phone_number              VARCHAR(30),
    address_line1               VARCHAR(200),
    city                          VARCHAR(100),
    region                          VARCHAR(50),
    postal_code                       VARCHAR(20),
    plan_id                             VARCHAR(20),
    activation_date                       DATE,
    account_status                          VARCHAR(20),
    customer_segment                          VARCHAR(30),
    credit_score                                NUMBER(5,0),
    eff_start_ts         TIMESTAMP_NTZ NOT NULL,
    eff_end_ts            TIMESTAMP_NTZ,
    is_current              BOOLEAN DEFAULT TRUE,
    CONSTRAINT PK_DIM_CUSTOMER PRIMARY KEY (customer_sk)
)
COMMENT = 'SCD2 customer dimension. Query with is_current = TRUE for current snapshot.';

CREATE TABLE IF NOT EXISTS CURATED.DIM_PLAN (
    plan_sk              NUMBER AUTOINCREMENT START 1 INCREMENT 1,
    plan_id              VARCHAR(20)   NOT NULL,
    plan_name             VARCHAR(100),
    plan_type               VARCHAR(20),
    monthly_fee                NUMBER(10,2),
    data_limit_gb                 NUMBER(10,2),
    voice_minutes                    NUMBER(10,0),
    sms_count                           NUMBER(10,0),
    currency                              VARCHAR(10),
    effective_date                          DATE,
    updated_at                                TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT PK_DIM_PLAN PRIMARY KEY (plan_sk)
);

CREATE TABLE IF NOT EXISTS CURATED.DIM_DEVICE (
    device_sk            NUMBER AUTOINCREMENT START 1 INCREMENT 1,
    device_id            VARCHAR(20)   NOT NULL,
    imei                  VARCHAR(30),
    customer_id             VARCHAR(20),
    device_model               VARCHAR(100),
    device_os                     VARCHAR(50),
    activation_date                  DATE,
    device_status                       VARCHAR(20),
    updated_at                            TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT PK_DIM_DEVICE PRIMARY KEY (device_sk)
);

CREATE TABLE IF NOT EXISTS CURATED.DIM_TOWER (
    tower_sk             NUMBER AUTOINCREMENT START 1 INCREMENT 1,
    tower_id             VARCHAR(20)   NOT NULL,
    region                 VARCHAR(50),
    latitude                  NUMBER(9,6),
    longitude                    NUMBER(9,6),
    capacity_mbps                   NUMBER(10,0),
    tower_status                       VARCHAR(20),
    updated_at                           TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT PK_DIM_TOWER PRIMARY KEY (tower_sk)
);

CREATE TABLE IF NOT EXISTS CURATED.FACT_CDR_USAGE (
    cdr_id                VARCHAR(40)   NOT NULL,
    customer_id            VARCHAR(20),
    call_type                VARCHAR(10),
    origin_number               VARCHAR(30),
    destination_number             VARCHAR(30),
    cell_tower_id                     VARCHAR(20),
    call_start_ts                        TIMESTAMP_NTZ,
    call_end_ts                             TIMESTAMP_NTZ,
    duration_seconds                          NUMBER(10,0),
    data_volume_mb                              NUMBER(12,3),
    roaming_flag                                  BOOLEAN,
    region                                          VARCHAR(50),
    usage_date                                        DATE,
    loaded_at             TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT PK_FACT_CDR_USAGE PRIMARY KEY (cdr_id)
)
CLUSTER BY (usage_date, region)
COMMENT = 'High volume usage fact - clustered by usage_date/region for pruning';

CREATE TABLE IF NOT EXISTS CURATED.FACT_BILLING (
    invoice_id           VARCHAR(20)   NOT NULL,
    customer_id            VARCHAR(20),
    billing_period            VARCHAR(10),
    plan_id                     VARCHAR(20),
    usage_charges                  NUMBER(12,2),
    tax_amount                        NUMBER(12,2),
    total_amount                         NUMBER(12,2),
    invoice_date                           DATE,
    due_date                                 DATE,
    invoice_status                             VARCHAR(20),
    loaded_at             TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT PK_FACT_BILLING PRIMARY KEY (invoice_id)
);

CREATE TABLE IF NOT EXISTS CURATED.FACT_PAYMENTS (
    payment_id           VARCHAR(20)   NOT NULL,
    invoice_id             VARCHAR(20),
    customer_id               VARCHAR(20),
    payment_date                 DATE,
    amount                          NUMBER(12,2),
    payment_method                     VARCHAR(30),
    card_last4                            VARCHAR(10),
    payment_status                           VARCHAR(20),
    loaded_at             TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT PK_FACT_PAYMENTS PRIMARY KEY (payment_id)
);

CREATE TABLE IF NOT EXISTS CURATED.FACT_SUPPORT_TICKETS (
    ticket_id            VARCHAR(20)   NOT NULL,
    customer_id            VARCHAR(20),
    opened_at                 TIMESTAMP_NTZ,
    closed_at                    TIMESTAMP_NTZ,
    category                        VARCHAR(50),
    priority                           VARCHAR(10),
    ticket_status                         VARCHAR(20),
    channel                                 VARCHAR(20),
    resolution_minutes                        NUMBER(10,0),
    loaded_at             TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT PK_FACT_SUPPORT_TICKETS PRIMARY KEY (ticket_id)
);

CREATE OR REPLACE VIEW CURATED.VW_CUSTOMER_CURRENT AS
SELECT *
FROM CURATED.DIM_CUSTOMER
WHERE is_current = TRUE;

CREATE OR REPLACE VIEW CURATED.VW_CUSTOMER_MONTHLY_SUMMARY AS
SELECT
    b.customer_id,
    b.billing_period,
    c.region,
    c.customer_segment,
    b.total_amount                                            AS invoice_amount,
    p.paid_amount,
    COALESCE(u.total_data_mb, 0)                               AS total_data_mb,
    COALESCE(u.total_voice_seconds, 0)                          AS total_voice_seconds,
    COALESCE(u.total_sms, 0)                                     AS total_sms
FROM CURATED.FACT_BILLING b
JOIN CURATED.VW_CUSTOMER_CURRENT c ON c.customer_id = b.customer_id
LEFT JOIN (
    SELECT invoice_id, SUM(amount) AS paid_amount
    FROM CURATED.FACT_PAYMENTS
    WHERE payment_status = 'SUCCESS'
    GROUP BY invoice_id
) p ON p.invoice_id = b.invoice_id
LEFT JOIN (
    SELECT
        customer_id,
        TO_CHAR(usage_date, 'YYYY-MM')                          AS billing_period,
        SUM(IFF(call_type = 'DATA', data_volume_mb, 0))          AS total_data_mb,
        SUM(IFF(call_type = 'VOICE', duration_seconds, 0))       AS total_voice_seconds,
        COUNT_IF(call_type = 'SMS')                              AS total_sms
    FROM CURATED.FACT_CDR_USAGE
    GROUP BY 1, 2
) u ON u.customer_id = b.customer_id AND u.billing_period = b.billing_period;

SELECT '>>> END: tables_curated.sql | START: 08_audit_control/01_control_tables.sql' AS deploy_marker;

USE DATABASE RUNNING_TELCO;
USE SCHEMA AUDIT_CTL;

CREATE TABLE IF NOT EXISTS AUDIT_CTL.ETL_JOB_MASTER (
    job_id              NUMBER AUTOINCREMENT START 1 INCREMENT 1,
    job_name            VARCHAR(100)  NOT NULL,
    layer                 VARCHAR(20),
    source_object            VARCHAR(200),
    target_object               VARCHAR(200),
    schedule_cron                  VARCHAR(100),
    is_active                        BOOLEAN DEFAULT TRUE,
    created_at            TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT PK_ETL_JOB_MASTER PRIMARY KEY (job_id),
    CONSTRAINT UQ_JOB_NAME UNIQUE (job_name)
);

CREATE TABLE IF NOT EXISTS AUDIT_CTL.ETL_RUN_LOG (
    run_id               NUMBER AUTOINCREMENT START 1 INCREMENT 1,
    job_id                 NUMBER        NOT NULL,
    job_name                  VARCHAR(100)  NOT NULL,
    run_date                     DATE          DEFAULT CURRENT_DATE(),
    start_time                     TIMESTAMP_NTZ NOT NULL,
    end_time                          TIMESTAMP_NTZ,
    status                               VARCHAR(20)   DEFAULT 'RUNNING',
    rows_read                             NUMBER DEFAULT 0,
    rows_inserted                           NUMBER DEFAULT 0,
    rows_updated                              NUMBER DEFAULT 0,
    rows_deleted                                NUMBER DEFAULT 0,
    rows_rejected                                 NUMBER DEFAULT 0,
    duration_seconds                                NUMBER,
    triggered_by                                      VARCHAR(50),
    warehouse_used                                      VARCHAR(50),
    query_id                                              VARCHAR(50),
    comments                                                VARCHAR(1000),
    CONSTRAINT PK_ETL_RUN_LOG PRIMARY KEY (run_id)
)
COMMENT = 'Every pipeline execution - the audit trail. One row per run per job.';

CREATE TABLE IF NOT EXISTS AUDIT_CTL.ETL_ERROR_LOG (
    error_id             NUMBER AUTOINCREMENT START 1 INCREMENT 1,
    run_id                 NUMBER,
    job_name                  VARCHAR(100),
    error_time                  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    error_type                     VARCHAR(50),
    sql_state                        VARCHAR(20),
    error_message                       VARCHAR(4000),
    error_context                           VARIANT,
    severity                                  VARCHAR(10) DEFAULT 'ERROR',
    is_resolved                                 BOOLEAN DEFAULT FALSE,
    resolved_at                                   TIMESTAMP_NTZ,
    resolved_by                                     VARCHAR(100),
    CONSTRAINT PK_ETL_ERROR_LOG PRIMARY KEY (error_id),
    CONSTRAINT FK_ERR_RUN FOREIGN KEY (run_id) REFERENCES AUDIT_CTL.ETL_RUN_LOG(run_id)
)
COMMENT = 'Failure capture - every exception raised during a pipeline run.';

CREATE TABLE IF NOT EXISTS AUDIT_CTL.DQ_CHECK_LOG (
    dq_check_id           NUMBER AUTOINCREMENT START 1 INCREMENT 1,
    run_id                  NUMBER,
    job_name                  VARCHAR(100),
    check_name                   VARCHAR(200),
    table_name                     VARCHAR(200),
    check_sql                        VARCHAR(4000),
    records_checked                    NUMBER,
    records_failed                       NUMBER,
    check_status                           VARCHAR(10),
    checked_at             TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT PK_DQ_CHECK_LOG PRIMARY KEY (dq_check_id)
);

MERGE INTO AUDIT_CTL.ETL_JOB_MASTER tgt
USING (
    SELECT * FROM VALUES
    ('RAW_TO_STAGING_CUSTOMERS','STAGE_LOAD','RAW.RAW_CUSTOMERS','STAGING.STG_CUSTOMERS','0 6 * * *'),
    ('RAW_TO_STAGING_PLANS','STAGE_LOAD','RAW.RAW_PLANS','STAGING.STG_PLANS','0 6 * * *'),
    ('RAW_TO_STAGING_DEVICES','STAGE_LOAD','RAW.RAW_DEVICES','STAGING.STG_DEVICES','0 6 * * *'),
    ('RAW_TO_STAGING_CDR','STAGE_LOAD','RAW.RAW_CDR','STAGING.STG_CDR','0 * * * *'),
    ('RAW_TO_STAGING_BILLING','STAGE_LOAD','RAW.RAW_BILLING','STAGING.STG_BILLING','0 7 * * *'),
    ('RAW_TO_STAGING_PAYMENTS','STAGE_LOAD','RAW.RAW_PAYMENTS','STAGING.STG_PAYMENTS','0 7 * * *'),
    ('RAW_TO_STAGING_TOWERS','STAGE_LOAD','RAW.RAW_TOWERS','STAGING.STG_TOWERS','0 6 * * *'),
    ('RAW_TO_STAGING_SUPPORT_TICKETS','STAGE_LOAD','RAW.RAW_SUPPORT_TICKETS','STAGING.STG_SUPPORT_TICKETS','0 6 * * *'),
    ('STAGING_TO_CURATED_DIM_CUSTOMER','CURATED_MERGE','STAGING.STRM_CUSTOMERS','CURATED.DIM_CUSTOMER','0 8 * * *'),
    ('STAGING_TO_CURATED_DIM_PLAN','CURATED_MERGE','STAGING.STRM_PLANS','CURATED.DIM_PLAN','0 8 * * *'),
    ('STAGING_TO_CURATED_DIM_DEVICE','CURATED_MERGE','STAGING.STRM_DEVICES','CURATED.DIM_DEVICE','0 8 * * *'),
    ('STAGING_TO_CURATED_DIM_TOWER','CURATED_MERGE','STAGING.STRM_TOWERS','CURATED.DIM_TOWER','0 8 * * *'),
    ('STAGING_TO_CURATED_FACT_CDR','CURATED_MERGE','STAGING.STRM_CDR','CURATED.FACT_CDR_USAGE','15 * * * *'),
    ('STAGING_TO_CURATED_FACT_BILLING','CURATED_MERGE','STAGING.STRM_BILLING','CURATED.FACT_BILLING','0 9 * * *'),
    ('STAGING_TO_CURATED_FACT_PAYMENTS','CURATED_MERGE','STAGING.STRM_PAYMENTS','CURATED.FACT_PAYMENTS','0 9 * * *'),
    ('STAGING_TO_CURATED_FACT_TICKETS','CURATED_MERGE','STAGING.STRM_SUPPORT_TICKETS','CURATED.FACT_SUPPORT_TICKETS','0 9 * * *')
) AS src(job_name, layer, source_object, target_object, schedule_cron)
ON tgt.job_name = src.job_name
WHEN NOT MATCHED THEN
  INSERT (job_name, layer, source_object, target_object, schedule_cron)
  VALUES (src.job_name, src.layer, src.source_object, src.target_object, src.schedule_cron);

CREATE OR REPLACE VIEW AUDIT_CTL.VW_DAILY_RUN_STATS AS
SELECT
    run_date,
    job_name,
    COUNT(*)                                   AS total_runs,
    SUM(IFF(status = 'SUCCESS', 1, 0))         AS successful_runs,
    SUM(IFF(status = 'FAILED', 1, 0))          AS failed_runs,
    SUM(IFF(status = 'WARNING', 1, 0))         AS warning_runs,
    SUM(rows_read)                             AS total_rows_read,
    SUM(rows_inserted)                         AS total_rows_inserted,
    SUM(rows_updated)                          AS total_rows_updated,
    SUM(rows_rejected)                         AS total_rows_rejected,
    ROUND(AVG(duration_seconds), 1)            AS avg_duration_seconds,
    MAX(duration_seconds)                      AS max_duration_seconds
FROM AUDIT_CTL.ETL_RUN_LOG
GROUP BY run_date, job_name
ORDER BY run_date DESC, job_name;

CREATE OR REPLACE VIEW AUDIT_CTL.VW_LATEST_RUN_STATUS AS
SELECT job_name, status, start_time, end_time, duration_seconds,
       rows_read, rows_inserted, rows_updated, rows_rejected
FROM AUDIT_CTL.ETL_RUN_LOG
QUALIFY ROW_NUMBER() OVER (PARTITION BY job_name ORDER BY start_time DESC) = 1;

CREATE OR REPLACE VIEW AUDIT_CTL.VW_OPEN_ERRORS AS
SELECT e.error_id, e.run_id, e.job_name, e.error_time, e.error_type,
       e.severity, e.error_message, r.status AS run_status
FROM AUDIT_CTL.ETL_ERROR_LOG e
LEFT JOIN AUDIT_CTL.ETL_RUN_LOG r ON r.run_id = e.run_id
WHERE e.is_resolved = FALSE
ORDER BY e.error_time DESC;

SELECT '>>> END: 01_control_tables.sql | START: 08_audit_control/02_audit_procedures.sql' AS deploy_marker;

USE DATABASE RUNNING_TELCO;
USE SCHEMA AUDIT_CTL;

CREATE OR REPLACE PROCEDURE AUDIT_CTL.SP_AUDIT_START(
    P_JOB_NAME STRING,
    P_TRIGGERED_BY STRING
)
RETURNS NUMBER
LANGUAGE SQL
AS
$$
DECLARE
    v_job_id NUMBER;
    v_run_id NUMBER;
BEGIN
    SELECT job_id INTO :v_job_id
    FROM AUDIT_CTL.ETL_JOB_MASTER
    WHERE job_name = :P_JOB_NAME;

    IF (v_job_id IS NULL) THEN
        INSERT INTO AUDIT_CTL.ETL_JOB_MASTER (job_name, layer)
        VALUES (:P_JOB_NAME, 'AD_HOC');

        SELECT job_id INTO :v_job_id
        FROM AUDIT_CTL.ETL_JOB_MASTER
        WHERE job_name = :P_JOB_NAME;
    END IF;

    INSERT INTO AUDIT_CTL.ETL_RUN_LOG
        (job_id, job_name, start_time, status, triggered_by, warehouse_used)
    VALUES
        (:v_job_id, :P_JOB_NAME, CURRENT_TIMESTAMP(), 'RUNNING', :P_TRIGGERED_BY, CURRENT_WAREHOUSE());

    SELECT MAX(run_id) INTO :v_run_id
    FROM AUDIT_CTL.ETL_RUN_LOG
    WHERE job_id = :v_job_id;

    RETURN v_run_id;
END;
$$;

CREATE OR REPLACE PROCEDURE AUDIT_CTL.SP_AUDIT_END(
    P_RUN_ID NUMBER,
    P_ROWS_READ NUMBER,
    P_ROWS_INSERTED NUMBER,
    P_ROWS_UPDATED NUMBER,
    P_ROWS_DELETED NUMBER,
    P_ROWS_REJECTED NUMBER,
    P_COMMENTS STRING
)
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
    UPDATE AUDIT_CTL.ETL_RUN_LOG
    SET end_time          = CURRENT_TIMESTAMP(),
        status            = IFF(:P_ROWS_REJECTED > 0, 'WARNING', 'SUCCESS'),
        rows_read         = :P_ROWS_READ,
        rows_inserted     = :P_ROWS_INSERTED,
        rows_updated      = :P_ROWS_UPDATED,
        rows_deleted      = :P_ROWS_DELETED,
        rows_rejected     = :P_ROWS_REJECTED,
        duration_seconds  = DATEDIFF('second', start_time, CURRENT_TIMESTAMP()),
        comments          = :P_COMMENTS
    WHERE run_id = :P_RUN_ID;

    RETURN 'OK';
END;
$$;

CREATE OR REPLACE PROCEDURE AUDIT_CTL.SP_AUDIT_FAIL(
    P_RUN_ID NUMBER,
    P_ERROR_TYPE STRING,
    P_SQLCODE STRING,
    P_SQLERRM STRING,
    P_ERROR_CONTEXT VARIANT
)
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
    v_job_name STRING;
BEGIN
    SELECT job_name INTO :v_job_name FROM AUDIT_CTL.ETL_RUN_LOG WHERE run_id = :P_RUN_ID;

    UPDATE AUDIT_CTL.ETL_RUN_LOG
    SET end_time         = CURRENT_TIMESTAMP(),
        status           = 'FAILED',
        duration_seconds = DATEDIFF('second', start_time, CURRENT_TIMESTAMP()),
        comments         = LEFT(:P_SQLERRM, 1000)
    WHERE run_id = :P_RUN_ID;

    INSERT INTO AUDIT_CTL.ETL_ERROR_LOG
        (run_id, job_name, error_type, sql_state, error_message, error_context, severity)
    VALUES
        (:P_RUN_ID, :v_job_name, :P_ERROR_TYPE, :P_SQLCODE, :P_SQLERRM, :P_ERROR_CONTEXT, 'CRITICAL');

    RETURN 'FAILED_LOGGED';
END;
$$;

CREATE OR REPLACE PROCEDURE AUDIT_CTL.SP_LOG_DQ_CHECK(
    P_RUN_ID NUMBER,
    P_JOB_NAME STRING,
    P_CHECK_NAME STRING,
    P_TABLE_NAME STRING,
    P_RECORDS_CHECKED NUMBER,
    P_RECORDS_FAILED NUMBER,
    P_CHECK_SQL STRING
)
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
    INSERT INTO AUDIT_CTL.DQ_CHECK_LOG
        (run_id, job_name, check_name, table_name, check_sql,
         records_checked, records_failed, check_status)
    VALUES
        (:P_RUN_ID, :P_JOB_NAME, :P_CHECK_NAME, :P_TABLE_NAME, :P_CHECK_SQL,
         :P_RECORDS_CHECKED, :P_RECORDS_FAILED, IFF(:P_RECORDS_FAILED = 0, 'PASS', 'FAIL'));

    RETURN 'OK';
END;
$$;

SELECT '>>> END: 02_audit_procedures.sql | START: 04_procedures/01_sp_raw_to_staging.sql' AS deploy_marker;

USE DATABASE RUNNING_TELCO;
USE SCHEMA STAGING;

CREATE OR REPLACE PROCEDURE STAGING.SP_LOAD_STG_CUSTOMERS()
RETURNS STRING
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_run_id        NUMBER;
    v_rows_read     NUMBER DEFAULT 0;
    v_rows_merged   NUMBER DEFAULT 0;
    v_rows_rejected NUMBER DEFAULT 0;
BEGIN
    v_run_id := (CALL AUDIT_CTL.SP_AUDIT_START('RAW_TO_STAGING_CUSTOMERS', 'TASK'));

    SELECT COUNT(*) INTO :v_rows_rejected
    FROM RAW.RAW_CUSTOMERS
    WHERE customer_id IS NULL;

    CALL AUDIT_CTL.SP_LOG_DQ_CHECK(:v_run_id, 'RAW_TO_STAGING_CUSTOMERS', 'NULL_CUSTOMER_ID',
        'RAW.RAW_CUSTOMERS',
        (SELECT COUNT(*) FROM RAW.RAW_CUSTOMERS),
        :v_rows_rejected,
        'SELECT COUNT(*) FROM RAW.RAW_CUSTOMERS WHERE customer_id IS NULL');

    MERGE INTO STAGING.STG_CUSTOMERS tgt
    USING (
        SELECT customer_id, first_name, last_name,
               TRY_TO_DATE(date_of_birth)                  AS date_of_birth,
               national_id, email, phone_number, address_line1, city, region,
               postal_code, plan_id,
               TRY_TO_DATE(activation_date)                AS activation_date,
               account_status, customer_segment,
               TRY_TO_NUMBER(credit_score)                 AS credit_score
        FROM RAW.RAW_CUSTOMERS
        WHERE customer_id IS NOT NULL
        QUALIFY ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY _load_ts DESC) = 1
    ) src
    ON tgt.customer_id = src.customer_id
    WHEN MATCHED AND (tgt.account_status != src.account_status
                        OR tgt.plan_id != src.plan_id
                        OR tgt.address_line1 != src.address_line1
                        OR tgt.region != src.region) THEN
        UPDATE SET first_name = src.first_name, last_name = src.last_name,
                   date_of_birth = src.date_of_birth, national_id = src.national_id,
                   email = src.email, phone_number = src.phone_number,
                   address_line1 = src.address_line1, city = src.city, region = src.region,
                   postal_code = src.postal_code, plan_id = src.plan_id,
                   activation_date = src.activation_date, account_status = src.account_status,
                   customer_segment = src.customer_segment, credit_score = src.credit_score,
                   updated_at = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN
        INSERT (customer_id, first_name, last_name, date_of_birth, national_id, email,
                phone_number, address_line1, city, region, postal_code, plan_id,
                activation_date, account_status, customer_segment, credit_score)
        VALUES (src.customer_id, src.first_name, src.last_name, src.date_of_birth, src.national_id,
                src.email, src.phone_number, src.address_line1, src.city, src.region,
                src.postal_code, src.plan_id, src.activation_date, src.account_status,
                src.customer_segment, src.credit_score);

    v_rows_read   := SQLROWCOUNT;
    v_rows_merged := SQLROWCOUNT;

    CALL AUDIT_CTL.SP_AUDIT_END(:v_run_id, :v_rows_read, :v_rows_merged, 0, 0, :v_rows_rejected,
        'RAW_CUSTOMERS -> STG_CUSTOMERS merge complete');

    RETURN 'SUCCESS run_id=' || v_run_id;
EXCEPTION
    WHEN OTHER THEN
        CALL AUDIT_CTL.SP_AUDIT_FAIL(:v_run_id, 'SQL_ERROR', :sqlcode, :sqlerrm,
            OBJECT_CONSTRUCT('procedure', 'SP_LOAD_STG_CUSTOMERS'));
        RAISE;
END;
$$;

CREATE OR REPLACE PROCEDURE STAGING.SP_LOAD_STG_PLANS()
RETURNS STRING
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_run_id NUMBER;
    v_rows   NUMBER DEFAULT 0;
BEGIN
    v_run_id := (CALL AUDIT_CTL.SP_AUDIT_START('RAW_TO_STAGING_PLANS', 'TASK'));

    MERGE INTO STAGING.STG_PLANS tgt
    USING (
        SELECT plan_id, plan_name, plan_type,
               TRY_TO_DECIMAL(monthly_fee, 10, 2)   AS monthly_fee,
               TRY_TO_DECIMAL(data_limit_gb, 10, 2) AS data_limit_gb,
               TRY_TO_NUMBER(voice_minutes)         AS voice_minutes,
               TRY_TO_NUMBER(sms_count)             AS sms_count,
               currency, TRY_TO_DATE(effective_date) AS effective_date
        FROM RAW.RAW_PLANS
        WHERE plan_id IS NOT NULL
        QUALIFY ROW_NUMBER() OVER (PARTITION BY plan_id ORDER BY _load_ts DESC) = 1
    ) src
    ON tgt.plan_id = src.plan_id
    WHEN MATCHED THEN UPDATE SET
        plan_name = src.plan_name, plan_type = src.plan_type, monthly_fee = src.monthly_fee,
        data_limit_gb = src.data_limit_gb, voice_minutes = src.voice_minutes,
        sms_count = src.sms_count, currency = src.currency,
        effective_date = src.effective_date, updated_at = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT
        (plan_id, plan_name, plan_type, monthly_fee, data_limit_gb, voice_minutes, sms_count, currency, effective_date)
        VALUES (src.plan_id, src.plan_name, src.plan_type, src.monthly_fee, src.data_limit_gb,
                src.voice_minutes, src.sms_count, src.currency, src.effective_date);

    v_rows := SQLROWCOUNT;
    CALL AUDIT_CTL.SP_AUDIT_END(:v_run_id, :v_rows, :v_rows, 0, 0, 0, 'RAW_PLANS -> STG_PLANS merge complete');
    RETURN 'SUCCESS run_id=' || v_run_id;
EXCEPTION
    WHEN OTHER THEN
        CALL AUDIT_CTL.SP_AUDIT_FAIL(:v_run_id, 'SQL_ERROR', :sqlcode, :sqlerrm,
            OBJECT_CONSTRUCT('procedure', 'SP_LOAD_STG_PLANS'));
        RAISE;
END;
$$;

CREATE OR REPLACE PROCEDURE STAGING.SP_LOAD_STG_DEVICES()
RETURNS STRING
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_run_id NUMBER;
    v_rows   NUMBER DEFAULT 0;
BEGIN
    v_run_id := (CALL AUDIT_CTL.SP_AUDIT_START('RAW_TO_STAGING_DEVICES', 'TASK'));

    MERGE INTO STAGING.STG_DEVICES tgt
    USING (
        SELECT device_id, imei, customer_id, device_model, device_os,
               TRY_TO_DATE(activation_date) AS activation_date, device_status
        FROM RAW.RAW_DEVICES
        WHERE device_id IS NOT NULL
        QUALIFY ROW_NUMBER() OVER (PARTITION BY device_id ORDER BY _load_ts DESC) = 1
    ) src
    ON tgt.device_id = src.device_id
    WHEN MATCHED THEN UPDATE SET
        imei = src.imei, customer_id = src.customer_id, device_model = src.device_model,
        device_os = src.device_os, activation_date = src.activation_date,
        device_status = src.device_status, updated_at = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT
        (device_id, imei, customer_id, device_model, device_os, activation_date, device_status)
        VALUES (src.device_id, src.imei, src.customer_id, src.device_model, src.device_os,
                src.activation_date, src.device_status);

    v_rows := SQLROWCOUNT;
    CALL AUDIT_CTL.SP_AUDIT_END(:v_run_id, :v_rows, :v_rows, 0, 0, 0, 'RAW_DEVICES -> STG_DEVICES merge complete');
    RETURN 'SUCCESS run_id=' || v_run_id;
EXCEPTION
    WHEN OTHER THEN
        CALL AUDIT_CTL.SP_AUDIT_FAIL(:v_run_id, 'SQL_ERROR', :sqlcode, :sqlerrm,
            OBJECT_CONSTRUCT('procedure', 'SP_LOAD_STG_DEVICES'));
        RAISE;
END;
$$;

CREATE OR REPLACE PROCEDURE STAGING.SP_LOAD_STG_CDR()
RETURNS STRING
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_run_id        NUMBER;
    v_rows_inserted NUMBER DEFAULT 0;
    v_rows_rejected NUMBER DEFAULT 0;
BEGIN
    v_run_id := (CALL AUDIT_CTL.SP_AUDIT_START('RAW_TO_STAGING_CDR', 'TASK'));

    SELECT COUNT(*) INTO :v_rows_rejected
    FROM RAW.RAW_CDR
    WHERE cdr_id IS NULL OR TRY_TO_TIMESTAMP_NTZ(call_start_ts) IS NULL;

    CALL AUDIT_CTL.SP_LOG_DQ_CHECK(:v_run_id, 'RAW_TO_STAGING_CDR', 'NULL_KEY_OR_BAD_TS',
        'RAW.RAW_CDR', (SELECT COUNT(*) FROM RAW.RAW_CDR), :v_rows_rejected,
        'cdr_id IS NULL OR call_start_ts not parseable');

    INSERT INTO STAGING.STG_CDR
        (cdr_id, customer_id, call_type, origin_number, destination_number, cell_tower_id,
         call_start_ts, call_end_ts, duration_seconds, data_volume_mb, roaming_flag, region)
    SELECT
        cdr_id, customer_id, call_type, origin_number, destination_number, cell_tower_id,
        TRY_TO_TIMESTAMP_NTZ(call_start_ts), TRY_TO_TIMESTAMP_NTZ(call_end_ts),
        TRY_TO_NUMBER(duration_seconds), TRY_TO_DECIMAL(data_volume_mb, 12, 3),
        IFF(UPPER(roaming_flag) IN ('Y','TRUE','1'), TRUE, FALSE), region
    FROM RAW.RAW_CDR src
    WHERE cdr_id IS NOT NULL
      AND TRY_TO_TIMESTAMP_NTZ(call_start_ts) IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM STAGING.STG_CDR tgt WHERE tgt.cdr_id = src.cdr_id);

    v_rows_inserted := SQLROWCOUNT;
    CALL AUDIT_CTL.SP_AUDIT_END(:v_run_id, :v_rows_inserted, :v_rows_inserted, 0, 0, :v_rows_rejected,
        'RAW_CDR -> STG_CDR insert-only load complete');
    RETURN 'SUCCESS run_id=' || v_run_id;
EXCEPTION
    WHEN OTHER THEN
        CALL AUDIT_CTL.SP_AUDIT_FAIL(:v_run_id, 'SQL_ERROR', :sqlcode, :sqlerrm,
            OBJECT_CONSTRUCT('procedure', 'SP_LOAD_STG_CDR'));
        RAISE;
END;
$$;

CREATE OR REPLACE PROCEDURE STAGING.SP_LOAD_STG_BILLING()
RETURNS STRING
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_run_id NUMBER;
    v_rows   NUMBER DEFAULT 0;
BEGIN
    v_run_id := (CALL AUDIT_CTL.SP_AUDIT_START('RAW_TO_STAGING_BILLING', 'TASK'));

    MERGE INTO STAGING.STG_BILLING tgt
    USING (
        SELECT invoice_id, customer_id, billing_period, plan_id,
               TRY_TO_DECIMAL(usage_charges, 12, 2) AS usage_charges,
               TRY_TO_DECIMAL(tax_amount, 12, 2)     AS tax_amount,
               TRY_TO_DECIMAL(total_amount, 12, 2)   AS total_amount,
               TRY_TO_DATE(invoice_date)             AS invoice_date,
               TRY_TO_DATE(due_date)                 AS due_date,
               invoice_status
        FROM RAW.RAW_BILLING
        WHERE invoice_id IS NOT NULL
        QUALIFY ROW_NUMBER() OVER (PARTITION BY invoice_id ORDER BY _load_ts DESC) = 1
    ) src
    ON tgt.invoice_id = src.invoice_id
    WHEN MATCHED THEN UPDATE SET
        usage_charges = src.usage_charges, tax_amount = src.tax_amount,
        total_amount = src.total_amount, invoice_status = src.invoice_status,
        updated_at = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT
        (invoice_id, customer_id, billing_period, plan_id, usage_charges, tax_amount,
         total_amount, invoice_date, due_date, invoice_status)
        VALUES (src.invoice_id, src.customer_id, src.billing_period, src.plan_id, src.usage_charges,
                src.tax_amount, src.total_amount, src.invoice_date, src.due_date, src.invoice_status);

    v_rows := SQLROWCOUNT;
    CALL AUDIT_CTL.SP_AUDIT_END(:v_run_id, :v_rows, :v_rows, 0, 0, 0, 'RAW_BILLING -> STG_BILLING merge complete');
    RETURN 'SUCCESS run_id=' || v_run_id;
EXCEPTION
    WHEN OTHER THEN
        CALL AUDIT_CTL.SP_AUDIT_FAIL(:v_run_id, 'SQL_ERROR', :sqlcode, :sqlerrm,
            OBJECT_CONSTRUCT('procedure', 'SP_LOAD_STG_BILLING'));
        RAISE;
END;
$$;

CREATE OR REPLACE PROCEDURE STAGING.SP_LOAD_STG_PAYMENTS()
RETURNS STRING
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_run_id NUMBER;
    v_rows   NUMBER DEFAULT 0;
BEGIN
    v_run_id := (CALL AUDIT_CTL.SP_AUDIT_START('RAW_TO_STAGING_PAYMENTS', 'TASK'));

    MERGE INTO STAGING.STG_PAYMENTS tgt
    USING (
        SELECT payment_id, invoice_id, customer_id, TRY_TO_DATE(payment_date) AS payment_date,
               TRY_TO_DECIMAL(amount, 12, 2) AS amount, payment_method, card_last4, payment_status
        FROM RAW.RAW_PAYMENTS
        WHERE payment_id IS NOT NULL
        QUALIFY ROW_NUMBER() OVER (PARTITION BY payment_id ORDER BY _load_ts DESC) = 1
    ) src
    ON tgt.payment_id = src.payment_id
    WHEN MATCHED THEN UPDATE SET
        payment_status = src.payment_status, amount = src.amount, updated_at = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT
        (payment_id, invoice_id, customer_id, payment_date, amount, payment_method, card_last4, payment_status)
        VALUES (src.payment_id, src.invoice_id, src.customer_id, src.payment_date, src.amount,
                src.payment_method, src.card_last4, src.payment_status);

    v_rows := SQLROWCOUNT;
    CALL AUDIT_CTL.SP_AUDIT_END(:v_run_id, :v_rows, :v_rows, 0, 0, 0, 'RAW_PAYMENTS -> STG_PAYMENTS merge complete');
    RETURN 'SUCCESS run_id=' || v_run_id;
EXCEPTION
    WHEN OTHER THEN
        CALL AUDIT_CTL.SP_AUDIT_FAIL(:v_run_id, 'SQL_ERROR', :sqlcode, :sqlerrm,
            OBJECT_CONSTRUCT('procedure', 'SP_LOAD_STG_PAYMENTS'));
        RAISE;
END;
$$;

CREATE OR REPLACE PROCEDURE STAGING.SP_LOAD_STG_TOWERS()
RETURNS STRING
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_run_id NUMBER;
    v_rows   NUMBER DEFAULT 0;
BEGIN
    v_run_id := (CALL AUDIT_CTL.SP_AUDIT_START('RAW_TO_STAGING_TOWERS', 'TASK'));

    MERGE INTO STAGING.STG_TOWERS tgt
    USING (
        SELECT tower_id, region, TRY_TO_DECIMAL(latitude, 9, 6) AS latitude,
               TRY_TO_DECIMAL(longitude, 9, 6) AS longitude,
               TRY_TO_NUMBER(capacity_mbps) AS capacity_mbps, tower_status
        FROM RAW.RAW_TOWERS
        WHERE tower_id IS NOT NULL
        QUALIFY ROW_NUMBER() OVER (PARTITION BY tower_id ORDER BY _load_ts DESC) = 1
    ) src
    ON tgt.tower_id = src.tower_id
    WHEN MATCHED THEN UPDATE SET
        tower_status = src.tower_status, capacity_mbps = src.capacity_mbps, updated_at = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT
        (tower_id, region, latitude, longitude, capacity_mbps, tower_status)
        VALUES (src.tower_id, src.region, src.latitude, src.longitude, src.capacity_mbps, src.tower_status);

    v_rows := SQLROWCOUNT;
    CALL AUDIT_CTL.SP_AUDIT_END(:v_run_id, :v_rows, :v_rows, 0, 0, 0, 'RAW_TOWERS -> STG_TOWERS merge complete');
    RETURN 'SUCCESS run_id=' || v_run_id;
EXCEPTION
    WHEN OTHER THEN
        CALL AUDIT_CTL.SP_AUDIT_FAIL(:v_run_id, 'SQL_ERROR', :sqlcode, :sqlerrm,
            OBJECT_CONSTRUCT('procedure', 'SP_LOAD_STG_TOWERS'));
        RAISE;
END;
$$;

CREATE OR REPLACE PROCEDURE STAGING.SP_LOAD_STG_SUPPORT_TICKETS()
RETURNS STRING
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_run_id NUMBER;
    v_rows   NUMBER DEFAULT 0;
BEGIN
    v_run_id := (CALL AUDIT_CTL.SP_AUDIT_START('RAW_TO_STAGING_SUPPORT_TICKETS', 'TASK'));

    MERGE INTO STAGING.STG_SUPPORT_TICKETS tgt
    USING (
        SELECT ticket_id, customer_id, TRY_TO_TIMESTAMP_NTZ(opened_at) AS opened_at,
               TRY_TO_TIMESTAMP_NTZ(closed_at) AS closed_at, category, priority,
               ticket_status, channel
        FROM RAW.RAW_SUPPORT_TICKETS
        WHERE ticket_id IS NOT NULL
        QUALIFY ROW_NUMBER() OVER (PARTITION BY ticket_id ORDER BY _load_ts DESC) = 1
    ) src
    ON tgt.ticket_id = src.ticket_id
    WHEN MATCHED THEN UPDATE SET
        closed_at = src.closed_at, ticket_status = src.ticket_status, updated_at = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT
        (ticket_id, customer_id, opened_at, closed_at, category, priority, ticket_status, channel)
        VALUES (src.ticket_id, src.customer_id, src.opened_at, src.closed_at, src.category,
                src.priority, src.ticket_status, src.channel);

    v_rows := SQLROWCOUNT;
    CALL AUDIT_CTL.SP_AUDIT_END(:v_run_id, :v_rows, :v_rows, 0, 0, 0, 'RAW_SUPPORT_TICKETS -> STG_SUPPORT_TICKETS merge complete');
    RETURN 'SUCCESS run_id=' || v_run_id;
EXCEPTION
    WHEN OTHER THEN
        CALL AUDIT_CTL.SP_AUDIT_FAIL(:v_run_id, 'SQL_ERROR', :sqlcode, :sqlerrm,
            OBJECT_CONSTRUCT('procedure', 'SP_LOAD_STG_SUPPORT_TICKETS'));
        RAISE;
END;
$$;

SELECT '>>> END: 01_sp_raw_to_staging.sql | START: 04_procedures/02_sp_staging_to_curated.sql' AS deploy_marker;

USE DATABASE RUNNING_TELCO;
USE SCHEMA CURATED;

CREATE OR REPLACE PROCEDURE CURATED.SP_MERGE_DIM_CUSTOMER()
RETURNS STRING
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_run_id       NUMBER;
    v_rows_read    NUMBER DEFAULT 0;
    v_rows_closed  NUMBER DEFAULT 0;
    v_rows_new     NUMBER DEFAULT 0;
BEGIN
    v_run_id := (CALL AUDIT_CTL.SP_AUDIT_START('STAGING_TO_CURATED_DIM_CUSTOMER', 'TASK'));

    SELECT COUNT(*) INTO :v_rows_read FROM STAGING.STRM_CUSTOMERS;

    IF (v_rows_read = 0) THEN
        CALL AUDIT_CTL.SP_AUDIT_END(:v_run_id, 0, 0, 0, 0, 0, 'No new stream data - nothing to merge');
        RETURN 'SUCCESS no-op run_id=' || v_run_id;
    END IF;

    CREATE OR REPLACE TEMPORARY TABLE _tmp_customer_changes AS
    SELECT customer_id, first_name, last_name, date_of_birth, national_id, email,
           phone_number, address_line1, city, region, postal_code, plan_id,
           activation_date, account_status, customer_segment, credit_score,
           METADATA$ACTION AS dml_action, METADATA$ISUPDATE AS is_update
    FROM STAGING.STRM_CUSTOMERS
    QUALIFY ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY updated_at DESC) = 1;

    UPDATE CURATED.DIM_CUSTOMER tgt
    SET eff_end_ts = CURRENT_TIMESTAMP(), is_current = FALSE
    WHERE is_current = TRUE
      AND customer_id IN (SELECT customer_id FROM _tmp_customer_changes WHERE dml_action = 'INSERT');

    v_rows_closed := SQLROWCOUNT;

    INSERT INTO CURATED.DIM_CUSTOMER
        (customer_id, first_name, last_name, date_of_birth, national_id, email, phone_number,
         address_line1, city, region, postal_code, plan_id, activation_date, account_status,
         customer_segment, credit_score, eff_start_ts, eff_end_ts, is_current)
    SELECT customer_id, first_name, last_name, date_of_birth, national_id, email, phone_number,
           address_line1, city, region, postal_code, plan_id, activation_date, account_status,
           customer_segment, credit_score, CURRENT_TIMESTAMP(), NULL, TRUE
    FROM _tmp_customer_changes
    WHERE dml_action = 'INSERT';

    v_rows_new := SQLROWCOUNT;

    CALL AUDIT_CTL.SP_AUDIT_END(:v_run_id, :v_rows_read, :v_rows_new, :v_rows_closed, 0, 0,
        'SCD2 merge into DIM_CUSTOMER complete');

    RETURN 'SUCCESS run_id=' || v_run_id || ' new_versions=' || v_rows_new;
EXCEPTION
    WHEN OTHER THEN
        CALL AUDIT_CTL.SP_AUDIT_FAIL(:v_run_id, 'SQL_ERROR', :sqlcode, :sqlerrm,
            OBJECT_CONSTRUCT('procedure', 'SP_MERGE_DIM_CUSTOMER'));
        RAISE;
END;
$$;

CREATE OR REPLACE PROCEDURE CURATED.SP_MERGE_DIM_PLAN()
RETURNS STRING
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_run_id NUMBER;
    v_rows   NUMBER DEFAULT 0;
BEGIN
    v_run_id := (CALL AUDIT_CTL.SP_AUDIT_START('STAGING_TO_CURATED_DIM_PLAN', 'TASK'));

    MERGE INTO CURATED.DIM_PLAN tgt
    USING (
        SELECT plan_id, plan_name, plan_type, monthly_fee, data_limit_gb, voice_minutes,
               sms_count, currency, effective_date
        FROM STAGING.STRM_PLANS
        QUALIFY ROW_NUMBER() OVER (PARTITION BY plan_id ORDER BY updated_at DESC) = 1
    ) src
    ON tgt.plan_id = src.plan_id
    WHEN MATCHED THEN UPDATE SET
        plan_name = src.plan_name, plan_type = src.plan_type, monthly_fee = src.monthly_fee,
        data_limit_gb = src.data_limit_gb, voice_minutes = src.voice_minutes,
        sms_count = src.sms_count, currency = src.currency, effective_date = src.effective_date,
        updated_at = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT
        (plan_id, plan_name, plan_type, monthly_fee, data_limit_gb, voice_minutes, sms_count, currency, effective_date)
        VALUES (src.plan_id, src.plan_name, src.plan_type, src.monthly_fee, src.data_limit_gb,
                src.voice_minutes, src.sms_count, src.currency, src.effective_date);

    v_rows := SQLROWCOUNT;
    CALL AUDIT_CTL.SP_AUDIT_END(:v_run_id, :v_rows, :v_rows, 0, 0, 0, 'DIM_PLAN merge complete');
    RETURN 'SUCCESS run_id=' || v_run_id;
EXCEPTION
    WHEN OTHER THEN
        CALL AUDIT_CTL.SP_AUDIT_FAIL(:v_run_id, 'SQL_ERROR', :sqlcode, :sqlerrm,
            OBJECT_CONSTRUCT('procedure', 'SP_MERGE_DIM_PLAN'));
        RAISE;
END;
$$;

CREATE OR REPLACE PROCEDURE CURATED.SP_MERGE_DIM_DEVICE()
RETURNS STRING
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_run_id NUMBER;
    v_rows   NUMBER DEFAULT 0;
BEGIN
    v_run_id := (CALL AUDIT_CTL.SP_AUDIT_START('STAGING_TO_CURATED_DIM_DEVICE', 'TASK'));

    MERGE INTO CURATED.DIM_DEVICE tgt
    USING (
        SELECT device_id, imei, customer_id, device_model, device_os, activation_date, device_status
        FROM STAGING.STRM_DEVICES
        QUALIFY ROW_NUMBER() OVER (PARTITION BY device_id ORDER BY updated_at DESC) = 1
    ) src
    ON tgt.device_id = src.device_id
    WHEN MATCHED THEN UPDATE SET
        imei = src.imei, customer_id = src.customer_id, device_model = src.device_model,
        device_os = src.device_os, device_status = src.device_status, updated_at = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT
        (device_id, imei, customer_id, device_model, device_os, activation_date, device_status)
        VALUES (src.device_id, src.imei, src.customer_id, src.device_model, src.device_os,
                src.activation_date, src.device_status);

    v_rows := SQLROWCOUNT;
    CALL AUDIT_CTL.SP_AUDIT_END(:v_run_id, :v_rows, :v_rows, 0, 0, 0, 'DIM_DEVICE merge complete');
    RETURN 'SUCCESS run_id=' || v_run_id;
EXCEPTION
    WHEN OTHER THEN
        CALL AUDIT_CTL.SP_AUDIT_FAIL(:v_run_id, 'SQL_ERROR', :sqlcode, :sqlerrm,
            OBJECT_CONSTRUCT('procedure', 'SP_MERGE_DIM_DEVICE'));
        RAISE;
END;
$$;

CREATE OR REPLACE PROCEDURE CURATED.SP_MERGE_DIM_TOWER()
RETURNS STRING
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_run_id NUMBER;
    v_rows   NUMBER DEFAULT 0;
BEGIN
    v_run_id := (CALL AUDIT_CTL.SP_AUDIT_START('STAGING_TO_CURATED_DIM_TOWER', 'TASK'));

    MERGE INTO CURATED.DIM_TOWER tgt
    USING (
        SELECT tower_id, region, latitude, longitude, capacity_mbps, tower_status
        FROM STAGING.STRM_TOWERS
        QUALIFY ROW_NUMBER() OVER (PARTITION BY tower_id ORDER BY updated_at DESC) = 1
    ) src
    ON tgt.tower_id = src.tower_id
    WHEN MATCHED THEN UPDATE SET
        tower_status = src.tower_status, capacity_mbps = src.capacity_mbps, updated_at = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT
        (tower_id, region, latitude, longitude, capacity_mbps, tower_status)
        VALUES (src.tower_id, src.region, src.latitude, src.longitude, src.capacity_mbps, src.tower_status);

    v_rows := SQLROWCOUNT;
    CALL AUDIT_CTL.SP_AUDIT_END(:v_run_id, :v_rows, :v_rows, 0, 0, 0, 'DIM_TOWER merge complete');
    RETURN 'SUCCESS run_id=' || v_run_id;
EXCEPTION
    WHEN OTHER THEN
        CALL AUDIT_CTL.SP_AUDIT_FAIL(:v_run_id, 'SQL_ERROR', :sqlcode, :sqlerrm,
            OBJECT_CONSTRUCT('procedure', 'SP_MERGE_DIM_TOWER'));
        RAISE;
END;
$$;

CREATE OR REPLACE PROCEDURE CURATED.SP_MERGE_FACT_CDR_USAGE()
RETURNS STRING
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_run_id NUMBER;
    v_rows   NUMBER DEFAULT 0;
BEGIN
    v_run_id := (CALL AUDIT_CTL.SP_AUDIT_START('STAGING_TO_CURATED_FACT_CDR', 'TASK'));

    INSERT INTO CURATED.FACT_CDR_USAGE
        (cdr_id, customer_id, call_type, origin_number, destination_number, cell_tower_id,
         call_start_ts, call_end_ts, duration_seconds, data_volume_mb, roaming_flag, region, usage_date)
    SELECT cdr_id, customer_id, call_type, origin_number, destination_number, cell_tower_id,
           call_start_ts, call_end_ts, duration_seconds, data_volume_mb, roaming_flag, region,
           DATE(call_start_ts)
    FROM STAGING.STRM_CDR
    WHERE METADATA$ACTION = 'INSERT';

    v_rows := SQLROWCOUNT;
    CALL AUDIT_CTL.SP_AUDIT_END(:v_run_id, :v_rows, :v_rows, 0, 0, 0, 'FACT_CDR_USAGE append-only load complete');
    RETURN 'SUCCESS run_id=' || v_run_id;
EXCEPTION
    WHEN OTHER THEN
        CALL AUDIT_CTL.SP_AUDIT_FAIL(:v_run_id, 'SQL_ERROR', :sqlcode, :sqlerrm,
            OBJECT_CONSTRUCT('procedure', 'SP_MERGE_FACT_CDR_USAGE'));
        RAISE;
END;
$$;

CREATE OR REPLACE PROCEDURE CURATED.SP_MERGE_FACT_BILLING()
RETURNS STRING
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_run_id NUMBER;
    v_rows   NUMBER DEFAULT 0;
BEGIN
    v_run_id := (CALL AUDIT_CTL.SP_AUDIT_START('STAGING_TO_CURATED_FACT_BILLING', 'TASK'));

    MERGE INTO CURATED.FACT_BILLING tgt
    USING (
        SELECT invoice_id, customer_id, billing_period, plan_id, usage_charges, tax_amount,
               total_amount, invoice_date, due_date, invoice_status
        FROM STAGING.STRM_BILLING
        QUALIFY ROW_NUMBER() OVER (PARTITION BY invoice_id ORDER BY updated_at DESC) = 1
    ) src
    ON tgt.invoice_id = src.invoice_id
    WHEN MATCHED THEN UPDATE SET
        total_amount = src.total_amount, invoice_status = src.invoice_status, loaded_at = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT
        (invoice_id, customer_id, billing_period, plan_id, usage_charges, tax_amount, total_amount,
         invoice_date, due_date, invoice_status)
        VALUES (src.invoice_id, src.customer_id, src.billing_period, src.plan_id, src.usage_charges,
                src.tax_amount, src.total_amount, src.invoice_date, src.due_date, src.invoice_status);

    v_rows := SQLROWCOUNT;
    CALL AUDIT_CTL.SP_AUDIT_END(:v_run_id, :v_rows, :v_rows, 0, 0, 0, 'FACT_BILLING merge complete');
    RETURN 'SUCCESS run_id=' || v_run_id;
EXCEPTION
    WHEN OTHER THEN
        CALL AUDIT_CTL.SP_AUDIT_FAIL(:v_run_id, 'SQL_ERROR', :sqlcode, :sqlerrm,
            OBJECT_CONSTRUCT('procedure', 'SP_MERGE_FACT_BILLING'));
        RAISE;
END;
$$;

CREATE OR REPLACE PROCEDURE CURATED.SP_MERGE_FACT_PAYMENTS()
RETURNS STRING
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_run_id NUMBER;
    v_rows   NUMBER DEFAULT 0;
BEGIN
    v_run_id := (CALL AUDIT_CTL.SP_AUDIT_START('STAGING_TO_CURATED_FACT_PAYMENTS', 'TASK'));

    MERGE INTO CURATED.FACT_PAYMENTS tgt
    USING (
        SELECT payment_id, invoice_id, customer_id, payment_date, amount, payment_method,
               card_last4, payment_status
        FROM STAGING.STRM_PAYMENTS
        QUALIFY ROW_NUMBER() OVER (PARTITION BY payment_id ORDER BY updated_at DESC) = 1
    ) src
    ON tgt.payment_id = src.payment_id
    WHEN MATCHED THEN UPDATE SET
        payment_status = src.payment_status, amount = src.amount, loaded_at = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT
        (payment_id, invoice_id, customer_id, payment_date, amount, payment_method, card_last4, payment_status)
        VALUES (src.payment_id, src.invoice_id, src.customer_id, src.payment_date, src.amount,
                src.payment_method, src.card_last4, src.payment_status);

    v_rows := SQLROWCOUNT;
    CALL AUDIT_CTL.SP_AUDIT_END(:v_run_id, :v_rows, :v_rows, 0, 0, 0, 'FACT_PAYMENTS merge complete');
    RETURN 'SUCCESS run_id=' || v_run_id;
EXCEPTION
    WHEN OTHER THEN
        CALL AUDIT_CTL.SP_AUDIT_FAIL(:v_run_id, 'SQL_ERROR', :sqlcode, :sqlerrm,
            OBJECT_CONSTRUCT('procedure', 'SP_MERGE_FACT_PAYMENTS'));
        RAISE;
END;
$$;

CREATE OR REPLACE PROCEDURE CURATED.SP_MERGE_FACT_SUPPORT_TICKETS()
RETURNS STRING
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_run_id NUMBER;
    v_rows   NUMBER DEFAULT 0;
BEGIN
    v_run_id := (CALL AUDIT_CTL.SP_AUDIT_START('STAGING_TO_CURATED_FACT_TICKETS', 'TASK'));

    MERGE INTO CURATED.FACT_SUPPORT_TICKETS tgt
    USING (
        SELECT ticket_id, customer_id, opened_at, closed_at, category, priority,
               ticket_status, channel,
               DATEDIFF('minute', opened_at, closed_at) AS resolution_minutes
        FROM STAGING.STRM_SUPPORT_TICKETS
        QUALIFY ROW_NUMBER() OVER (PARTITION BY ticket_id ORDER BY updated_at DESC) = 1
    ) src
    ON tgt.ticket_id = src.ticket_id
    WHEN MATCHED THEN UPDATE SET
        closed_at = src.closed_at, ticket_status = src.ticket_status,
        resolution_minutes = src.resolution_minutes, loaded_at = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT
        (ticket_id, customer_id, opened_at, closed_at, category, priority, ticket_status, channel, resolution_minutes)
        VALUES (src.ticket_id, src.customer_id, src.opened_at, src.closed_at, src.category,
                src.priority, src.ticket_status, src.channel, src.resolution_minutes);

    v_rows := SQLROWCOUNT;
    CALL AUDIT_CTL.SP_AUDIT_END(:v_run_id, :v_rows, :v_rows, 0, 0, 0, 'FACT_SUPPORT_TICKETS merge complete');
    RETURN 'SUCCESS run_id=' || v_run_id;
EXCEPTION
    WHEN OTHER THEN
        CALL AUDIT_CTL.SP_AUDIT_FAIL(:v_run_id, 'SQL_ERROR', :sqlcode, :sqlerrm,
            OBJECT_CONSTRUCT('procedure', 'SP_MERGE_FACT_SUPPORT_TICKETS'));
        RAISE;
END;
$$;

SELECT '>>> END: 02_sp_staging_to_curated.sql | START: 06_governance/01_tags.sql' AS deploy_marker;

USE DATABASE RUNNING_TELCO;
USE SCHEMA GOVERNANCE;
USE ROLE R_DATA_GOVERNANCE;

CREATE TAG IF NOT EXISTS GOVERNANCE.DATA_CLASSIFICATION
  ALLOWED_VALUES 'PII', 'FINANCIAL', 'CONFIDENTIAL', 'PUBLIC', 'INTERNAL'
  COMMENT = 'Top level sensitivity classification for a column';

CREATE TAG IF NOT EXISTS GOVERNANCE.PII_CATEGORY
  ALLOWED_VALUES 'NAME', 'NATIONAL_ID', 'CONTACT_INFO', 'ADDRESS', 'DOB', 'PAYMENT_CARD', 'NONE'
  COMMENT = 'Sub-category of PII for regulatory reporting (GDPR/CCPA style inventories)';

CREATE TAG IF NOT EXISTS GOVERNANCE.COST_CENTER
  COMMENT = 'Free-text cost center tag applied at warehouse/database level for chargeback reporting';

ALTER TABLE CURATED.DIM_CUSTOMER MODIFY COLUMN first_name     SET TAG GOVERNANCE.DATA_CLASSIFICATION = 'PII', GOVERNANCE.PII_CATEGORY = 'NAME';
ALTER TABLE CURATED.DIM_CUSTOMER MODIFY COLUMN last_name      SET TAG GOVERNANCE.DATA_CLASSIFICATION = 'PII', GOVERNANCE.PII_CATEGORY = 'NAME';
ALTER TABLE CURATED.DIM_CUSTOMER MODIFY COLUMN date_of_birth  SET TAG GOVERNANCE.DATA_CLASSIFICATION = 'PII', GOVERNANCE.PII_CATEGORY = 'DOB';
ALTER TABLE CURATED.DIM_CUSTOMER MODIFY COLUMN national_id    SET TAG GOVERNANCE.DATA_CLASSIFICATION = 'CONFIDENTIAL', GOVERNANCE.PII_CATEGORY = 'NATIONAL_ID';
ALTER TABLE CURATED.DIM_CUSTOMER MODIFY COLUMN email          SET TAG GOVERNANCE.DATA_CLASSIFICATION = 'PII', GOVERNANCE.PII_CATEGORY = 'CONTACT_INFO';
ALTER TABLE CURATED.DIM_CUSTOMER MODIFY COLUMN phone_number   SET TAG GOVERNANCE.DATA_CLASSIFICATION = 'PII', GOVERNANCE.PII_CATEGORY = 'CONTACT_INFO';
ALTER TABLE CURATED.DIM_CUSTOMER MODIFY COLUMN address_line1  SET TAG GOVERNANCE.DATA_CLASSIFICATION = 'PII', GOVERNANCE.PII_CATEGORY = 'ADDRESS';
ALTER TABLE CURATED.DIM_CUSTOMER MODIFY COLUMN credit_score   SET TAG GOVERNANCE.DATA_CLASSIFICATION = 'FINANCIAL', GOVERNANCE.PII_CATEGORY = 'NONE';

ALTER TABLE CURATED.FACT_PAYMENTS MODIFY COLUMN card_last4 SET TAG GOVERNANCE.DATA_CLASSIFICATION = 'FINANCIAL', GOVERNANCE.PII_CATEGORY = 'PAYMENT_CARD';
ALTER TABLE CURATED.FACT_PAYMENTS MODIFY COLUMN amount     SET TAG GOVERNANCE.DATA_CLASSIFICATION = 'FINANCIAL', GOVERNANCE.PII_CATEGORY = 'NONE';

ALTER TABLE CURATED.FACT_CDR_USAGE MODIFY COLUMN origin_number      SET TAG GOVERNANCE.DATA_CLASSIFICATION = 'PII', GOVERNANCE.PII_CATEGORY = 'CONTACT_INFO';
ALTER TABLE CURATED.FACT_CDR_USAGE MODIFY COLUMN destination_number SET TAG GOVERNANCE.DATA_CLASSIFICATION = 'PII', GOVERNANCE.PII_CATEGORY = 'CONTACT_INFO';

ALTER TABLE CURATED.FACT_BILLING MODIFY COLUMN total_amount   SET TAG GOVERNANCE.DATA_CLASSIFICATION = 'FINANCIAL';
ALTER TABLE CURATED.FACT_BILLING MODIFY COLUMN usage_charges  SET TAG GOVERNANCE.DATA_CLASSIFICATION = 'FINANCIAL';

ALTER WAREHOUSE WH_TRANSFORM SET TAG GOVERNANCE.COST_CENTER = 'DATA_ENGINEERING';
ALTER WAREHOUSE WH_BI        SET TAG GOVERNANCE.COST_CENTER = 'ANALYTICS';
ALTER WAREHOUSE WH_INGEST    SET TAG GOVERNANCE.COST_CENTER = 'DATA_ENGINEERING';

SELECT '>>> END: 01_tags.sql | START: 06_governance/02_masking_policies.sql' AS deploy_marker;

USE DATABASE RUNNING_TELCO;
USE SCHEMA GOVERNANCE;
USE ROLE R_DATA_GOVERNANCE;

CREATE OR REPLACE MASKING POLICY GOVERNANCE.MP_MASK_NATIONAL_ID AS (val STRING) RETURNS STRING ->
  CASE
    WHEN CURRENT_ROLE() IN ('R_COMPLIANCE_OFFICER', 'R_TELECOM_ADMIN') THEN val
    ELSE 'XXX-XX-' || RIGHT(val, 4)
  END;

CREATE OR REPLACE MASKING POLICY GOVERNANCE.MP_MASK_EMAIL AS (val STRING) RETURNS STRING ->
  CASE
    WHEN CURRENT_ROLE() IN ('R_COMPLIANCE_OFFICER', 'R_TELECOM_ADMIN') THEN val
    WHEN CURRENT_ROLE() IN ('R_ANALYST_GLOBAL', 'R_ANALYST_NORTH', 'R_ANALYST_SOUTH')
      THEN CONCAT('***@', SPLIT_PART(val, '@', 2))
    ELSE '***MASKED***'
  END;

CREATE OR REPLACE MASKING POLICY GOVERNANCE.MP_MASK_PHONE AS (val STRING) RETURNS STRING ->
  CASE
    WHEN CURRENT_ROLE() IN ('R_COMPLIANCE_OFFICER', 'R_TELECOM_ADMIN') THEN val
    ELSE CONCAT(LEFT(val, 3), '-XXX-', RIGHT(val, 2))
  END;

CREATE OR REPLACE MASKING POLICY GOVERNANCE.MP_MASK_ADDRESS AS (val STRING) RETURNS STRING ->
  CASE
    WHEN CURRENT_ROLE() IN ('R_COMPLIANCE_OFFICER', 'R_TELECOM_ADMIN') THEN val
    ELSE '***ADDRESS REDACTED***'
  END;

CREATE OR REPLACE MASKING POLICY GOVERNANCE.MP_MASK_DOB AS (val DATE) RETURNS DATE ->
  CASE
    WHEN CURRENT_ROLE() IN ('R_COMPLIANCE_OFFICER', 'R_TELECOM_ADMIN') THEN val
    WHEN CURRENT_ROLE() IN ('R_ANALYST_GLOBAL', 'R_ANALYST_NORTH', 'R_ANALYST_SOUTH')
      THEN DATE_FROM_PARTS(YEAR(val), 1, 1)
    ELSE NULL
  END;

CREATE OR REPLACE MASKING POLICY GOVERNANCE.MP_MASK_CARD AS (val STRING) RETURNS STRING ->
  CASE
    WHEN CURRENT_ROLE() IN ('R_COMPLIANCE_OFFICER', 'R_TELECOM_ADMIN') THEN val
    ELSE '**' || RIGHT(val, 2)
  END;

CREATE OR REPLACE MASKING POLICY GOVERNANCE.MP_ROUND_CURRENCY AS (val NUMBER(12,2)) RETURNS NUMBER(12,2) ->
  CASE
    WHEN CURRENT_ROLE() IN ('R_COMPLIANCE_OFFICER', 'R_TELECOM_ADMIN', 'R_DATA_ENGINEER') THEN val
    ELSE ROUND(val, -1)
  END;

ALTER TABLE CURATED.DIM_CUSTOMER MODIFY COLUMN national_id   SET MASKING POLICY GOVERNANCE.MP_MASK_NATIONAL_ID;
ALTER TABLE CURATED.DIM_CUSTOMER MODIFY COLUMN email         SET MASKING POLICY GOVERNANCE.MP_MASK_EMAIL;
ALTER TABLE CURATED.DIM_CUSTOMER MODIFY COLUMN phone_number  SET MASKING POLICY GOVERNANCE.MP_MASK_PHONE;
ALTER TABLE CURATED.DIM_CUSTOMER MODIFY COLUMN address_line1 SET MASKING POLICY GOVERNANCE.MP_MASK_ADDRESS;
ALTER TABLE CURATED.DIM_CUSTOMER MODIFY COLUMN date_of_birth SET MASKING POLICY GOVERNANCE.MP_MASK_DOB;

ALTER TABLE CURATED.FACT_PAYMENTS MODIFY COLUMN card_last4 SET MASKING POLICY GOVERNANCE.MP_MASK_CARD;

ALTER TABLE CURATED.FACT_CDR_USAGE MODIFY COLUMN origin_number      SET MASKING POLICY GOVERNANCE.MP_MASK_PHONE;
ALTER TABLE CURATED.FACT_CDR_USAGE MODIFY COLUMN destination_number SET MASKING POLICY GOVERNANCE.MP_MASK_PHONE;

SELECT '>>> END: 02_masking_policies.sql | START: 06_governance/03_row_access_policies.sql' AS deploy_marker;

USE DATABASE RUNNING_TELCO;
USE SCHEMA GOVERNANCE;
USE ROLE R_DATA_GOVERNANCE;

CREATE TABLE IF NOT EXISTS GOVERNANCE.ROLE_REGION_MAP (
    role_name     VARCHAR(100) NOT NULL,
    region        VARCHAR(50)  NOT NULL,
    CONSTRAINT PK_ROLE_REGION_MAP PRIMARY KEY (role_name, region)
)
COMMENT = 'Drives ROW ACCESS POLICY RAP_REGION_RESTRICT - which role sees which region(s)';

INSERT INTO GOVERNANCE.ROLE_REGION_MAP (role_name, region) VALUES
    ('R_ANALYST_NORTH', 'NORTH'),
    ('R_ANALYST_SOUTH', 'SOUTH');

CREATE OR REPLACE ROW ACCESS POLICY GOVERNANCE.RAP_REGION_RESTRICT
  AS (region_col STRING) RETURNS BOOLEAN ->
  CURRENT_ROLE() IN ('R_TELECOM_ADMIN', 'R_DATA_ENGINEER', 'R_DATA_GOVERNANCE',
                      'R_ANALYST_GLOBAL', 'R_COMPLIANCE_OFFICER')
  OR EXISTS (
      SELECT 1 FROM GOVERNANCE.ROLE_REGION_MAP m
      WHERE m.role_name = CURRENT_ROLE()
        AND m.region = region_col
  );

ALTER TABLE CURATED.DIM_CUSTOMER
  ADD ROW ACCESS POLICY GOVERNANCE.RAP_REGION_RESTRICT ON (region);

ALTER TABLE CURATED.FACT_CDR_USAGE
  ADD ROW ACCESS POLICY GOVERNANCE.RAP_REGION_RESTRICT ON (region);

ALTER TABLE CURATED.DIM_TOWER
  ADD ROW ACCESS POLICY GOVERNANCE.RAP_REGION_RESTRICT ON (region);

GRANT SELECT ON ALL TABLES IN SCHEMA CURATED TO ROLE R_ANALYST_NORTH;
GRANT SELECT ON ALL TABLES IN SCHEMA CURATED TO ROLE R_ANALYST_SOUTH;
GRANT SELECT ON ALL TABLES IN SCHEMA CURATED TO ROLE R_ANALYST_GLOBAL;
GRANT SELECT ON ALL TABLES IN SCHEMA CURATED TO ROLE R_COMPLIANCE_OFFICER;
GRANT SELECT ON ALL VIEWS  IN SCHEMA CURATED TO ROLE R_ANALYST_NORTH;
GRANT SELECT ON ALL VIEWS  IN SCHEMA CURATED TO ROLE R_ANALYST_SOUTH;
GRANT SELECT ON ALL VIEWS  IN SCHEMA CURATED TO ROLE R_ANALYST_GLOBAL;
GRANT SELECT ON ALL VIEWS  IN SCHEMA CURATED TO ROLE R_COMPLIANCE_OFFICER;

GRANT SELECT ON FUTURE TABLES IN SCHEMA CURATED TO ROLE R_ANALYST_GLOBAL;
GRANT SELECT ON FUTURE VIEWS  IN SCHEMA CURATED TO ROLE R_ANALYST_GLOBAL;

SELECT '>>> END: 03_row_access_policies.sql | START: 07_data_sharing/01_secure_views_and_share.sql' AS deploy_marker;

USE DATABASE RUNNING_TELCO;
USE SCHEMA SHARE_OUT;
USE ROLE R_TELECOM_ADMIN;

CREATE OR REPLACE SECURE VIEW SHARE_OUT.VW_SHARE_REGIONAL_USAGE_DAILY AS
SELECT
    usage_date,
    region,
    call_type,
    COUNT(*)                          AS session_count,
    SUM(duration_seconds)             AS total_duration_seconds,
    SUM(data_volume_mb)               AS total_data_mb,
    COUNT(DISTINCT customer_id)       AS distinct_customers
FROM CURATED.FACT_CDR_USAGE
GROUP BY usage_date, region, call_type;

CREATE OR REPLACE SECURE VIEW SHARE_OUT.VW_SHARE_REGIONAL_REVENUE_MONTHLY AS
SELECT
    b.billing_period,
    c.region,
    c.customer_segment,
    COUNT(DISTINCT b.customer_id)     AS billed_customers,
    SUM(b.total_amount)               AS total_billed,
    SUM(p.paid_amount)                AS total_collected
FROM CURATED.FACT_BILLING b
JOIN CURATED.VW_CUSTOMER_CURRENT c ON c.customer_id = b.customer_id
LEFT JOIN (
    SELECT invoice_id, SUM(amount) AS paid_amount
    FROM CURATED.FACT_PAYMENTS
    WHERE payment_status = 'SUCCESS'
    GROUP BY invoice_id
) p ON p.invoice_id = b.invoice_id
GROUP BY b.billing_period, c.region, c.customer_segment;

CREATE OR REPLACE SECURE VIEW SHARE_OUT.VW_SHARE_TOWER_STATUS AS
SELECT tower_id, region, capacity_mbps, tower_status
FROM CURATED.DIM_TOWER;

GRANT SELECT ON SHARE_OUT.VW_SHARE_REGIONAL_USAGE_DAILY     TO ROLE R_DATA_ENGINEER;
GRANT SELECT ON SHARE_OUT.VW_SHARE_REGIONAL_REVENUE_MONTHLY TO ROLE R_DATA_ENGINEER;
GRANT SELECT ON SHARE_OUT.VW_SHARE_TOWER_STATUS              TO ROLE R_DATA_ENGINEER;

/* ==========================================================================
   OUTBOUND SHARE - DEFERRED. CREATE SHARE requires ACCOUNTADMIN (or a role
   holding CREATE SHARE WITH GRANT OPTION) to provision; LEAD_ROLE holds
   neither in this environment, and no ACCOUNTADMIN user exists here. The
   secure views above ARE fully deployed and already SELECT-granted to
   R_DATA_ENGINEER, so the sharing story is demoable by querying them
   directly - only the actual outbound SHARE object to an external account
   is blocked. Uncomment and run this block once ACCOUNTADMIN access is
   available (a single one-time action, not a recurring dependency):

CREATE SHARE IF NOT EXISTS SHR_RUNNINGTELCO_PARTNER_ANALYTICS
  COMMENT = 'Outbound share: aggregated regional usage/revenue/network KPIs for external partner';

GRANT USAGE ON DATABASE RUNNING_TELCO         TO SHARE SHR_RUNNINGTELCO_PARTNER_ANALYTICS;
GRANT USAGE ON SCHEMA RUNNING_TELCO.SHARE_OUT TO SHARE SHR_RUNNINGTELCO_PARTNER_ANALYTICS;
GRANT SELECT ON SHARE_OUT.VW_SHARE_REGIONAL_USAGE_DAILY     TO SHARE SHR_RUNNINGTELCO_PARTNER_ANALYTICS;
GRANT SELECT ON SHARE_OUT.VW_SHARE_REGIONAL_REVENUE_MONTHLY TO SHARE SHR_RUNNINGTELCO_PARTNER_ANALYTICS;
GRANT SELECT ON SHARE_OUT.VW_SHARE_TOWER_STATUS              TO SHARE SHR_RUNNINGTELCO_PARTNER_ANALYTICS;

-- ALTER SHARE SHR_RUNNINGTELCO_PARTNER_ANALYTICS ADD ACCOUNTS = ('PARTNER_ACCOUNT_LOCATOR');
-- CREATE MANAGED ACCOUNT partner_reader_acct ADMIN_NAME = 'partner_admin', ADMIN_PASSWORD = '<set-strong-password>', TYPE = READER;

   ========================================================================== */

SELECT '>>> END: 01_secure_views_and_share.sql (CREATE SHARE deferred - needs ACCOUNTADMIN) | START: 05_tasks/task_tree.sql' AS deploy_marker;

USE DATABASE RUNNING_TELCO;
USE SCHEMA ORCHESTRATION;

CREATE TASK IF NOT EXISTS ORCHESTRATION.TASK_LOAD_STG_CUSTOMERS
  WAREHOUSE = WH_TRANSFORM
  SCHEDULE = 'USING CRON 0 6 * * * UTC'
  COMMENT = 'Root: RAW_CUSTOMERS -> STG_CUSTOMERS, daily 06:00 UTC'
  AS
  CALL STAGING.SP_LOAD_STG_CUSTOMERS();

CREATE TASK IF NOT EXISTS ORCHESTRATION.TASK_MERGE_DIM_CUSTOMER
  WAREHOUSE = WH_TRANSFORM
  AFTER ORCHESTRATION.TASK_LOAD_STG_CUSTOMERS
  WHEN SYSTEM$STREAM_HAS_DATA('RUNNING_TELCO.STAGING.STRM_CUSTOMERS')
  AS
  CALL CURATED.SP_MERGE_DIM_CUSTOMER();

CREATE TASK IF NOT EXISTS ORCHESTRATION.TASK_LOAD_STG_PLANS
  WAREHOUSE = WH_TRANSFORM
  SCHEDULE = 'USING CRON 0 6 * * * UTC'
  AS
  CALL STAGING.SP_LOAD_STG_PLANS();

CREATE TASK IF NOT EXISTS ORCHESTRATION.TASK_MERGE_DIM_PLAN
  WAREHOUSE = WH_TRANSFORM
  AFTER ORCHESTRATION.TASK_LOAD_STG_PLANS
  WHEN SYSTEM$STREAM_HAS_DATA('RUNNING_TELCO.STAGING.STRM_PLANS')
  AS
  CALL CURATED.SP_MERGE_DIM_PLAN();

CREATE TASK IF NOT EXISTS ORCHESTRATION.TASK_LOAD_STG_DEVICES
  WAREHOUSE = WH_TRANSFORM
  SCHEDULE = 'USING CRON 0 6 * * * UTC'
  AS
  CALL STAGING.SP_LOAD_STG_DEVICES();

CREATE TASK IF NOT EXISTS ORCHESTRATION.TASK_MERGE_DIM_DEVICE
  WAREHOUSE = WH_TRANSFORM
  AFTER ORCHESTRATION.TASK_LOAD_STG_DEVICES
  WHEN SYSTEM$STREAM_HAS_DATA('RUNNING_TELCO.STAGING.STRM_DEVICES')
  AS
  CALL CURATED.SP_MERGE_DIM_DEVICE();

CREATE TASK IF NOT EXISTS ORCHESTRATION.TASK_LOAD_STG_TOWERS
  WAREHOUSE = WH_TRANSFORM
  SCHEDULE = 'USING CRON 0 6 * * * UTC'
  AS
  CALL STAGING.SP_LOAD_STG_TOWERS();

CREATE TASK IF NOT EXISTS ORCHESTRATION.TASK_MERGE_DIM_TOWER
  WAREHOUSE = WH_TRANSFORM
  AFTER ORCHESTRATION.TASK_LOAD_STG_TOWERS
  WHEN SYSTEM$STREAM_HAS_DATA('RUNNING_TELCO.STAGING.STRM_TOWERS')
  AS
  CALL CURATED.SP_MERGE_DIM_TOWER();

CREATE TASK IF NOT EXISTS ORCHESTRATION.TASK_LOAD_STG_BILLING
  WAREHOUSE = WH_TRANSFORM
  SCHEDULE = 'USING CRON 0 7 * * * UTC'
  COMMENT = 'Runs after billing run typically completes upstream (07:00 UTC)'
  AS
  CALL STAGING.SP_LOAD_STG_BILLING();

CREATE TASK IF NOT EXISTS ORCHESTRATION.TASK_MERGE_FACT_BILLING
  WAREHOUSE = WH_TRANSFORM
  AFTER ORCHESTRATION.TASK_LOAD_STG_BILLING
  WHEN SYSTEM$STREAM_HAS_DATA('RUNNING_TELCO.STAGING.STRM_BILLING')
  AS
  CALL CURATED.SP_MERGE_FACT_BILLING();

CREATE TASK IF NOT EXISTS ORCHESTRATION.TASK_LOAD_STG_PAYMENTS
  WAREHOUSE = WH_TRANSFORM
  SCHEDULE = 'USING CRON 0 7 * * * UTC'
  AS
  CALL STAGING.SP_LOAD_STG_PAYMENTS();

CREATE TASK IF NOT EXISTS ORCHESTRATION.TASK_MERGE_FACT_PAYMENTS
  WAREHOUSE = WH_TRANSFORM
  AFTER ORCHESTRATION.TASK_LOAD_STG_PAYMENTS
  WHEN SYSTEM$STREAM_HAS_DATA('RUNNING_TELCO.STAGING.STRM_PAYMENTS')
  AS
  CALL CURATED.SP_MERGE_FACT_PAYMENTS();

CREATE TASK IF NOT EXISTS ORCHESTRATION.TASK_LOAD_STG_SUPPORT_TICKETS
  WAREHOUSE = WH_TRANSFORM
  SCHEDULE = 'USING CRON 0 6 * * * UTC'
  AS
  CALL STAGING.SP_LOAD_STG_SUPPORT_TICKETS();

CREATE TASK IF NOT EXISTS ORCHESTRATION.TASK_MERGE_FACT_SUPPORT_TICKETS
  WAREHOUSE = WH_TRANSFORM
  AFTER ORCHESTRATION.TASK_LOAD_STG_SUPPORT_TICKETS
  WHEN SYSTEM$STREAM_HAS_DATA('RUNNING_TELCO.STAGING.STRM_SUPPORT_TICKETS')
  AS
  CALL CURATED.SP_MERGE_FACT_SUPPORT_TICKETS();

CREATE TASK IF NOT EXISTS ORCHESTRATION.TASK_LOAD_STG_CDR
  WAREHOUSE = WH_TRANSFORM
  SCHEDULE = 'USING CRON 0 * * * * UTC'
  COMMENT = 'Root: RAW_CDR -> STG_CDR, hourly'
  AS
  CALL STAGING.SP_LOAD_STG_CDR();

CREATE TASK IF NOT EXISTS ORCHESTRATION.TASK_MERGE_FACT_CDR_USAGE
  WAREHOUSE = WH_TRANSFORM
  AFTER ORCHESTRATION.TASK_LOAD_STG_CDR
  WHEN SYSTEM$STREAM_HAS_DATA('RUNNING_TELCO.STAGING.STRM_CDR')
  AS
  CALL CURATED.SP_MERGE_FACT_CDR_USAGE();

ALTER TASK ORCHESTRATION.TASK_MERGE_DIM_CUSTOMER         RESUME;
ALTER TASK ORCHESTRATION.TASK_MERGE_DIM_PLAN             RESUME;
ALTER TASK ORCHESTRATION.TASK_MERGE_DIM_DEVICE           RESUME;
ALTER TASK ORCHESTRATION.TASK_MERGE_DIM_TOWER             RESUME;
ALTER TASK ORCHESTRATION.TASK_MERGE_FACT_BILLING          RESUME;
ALTER TASK ORCHESTRATION.TASK_MERGE_FACT_PAYMENTS         RESUME;
ALTER TASK ORCHESTRATION.TASK_MERGE_FACT_SUPPORT_TICKETS  RESUME;
ALTER TASK ORCHESTRATION.TASK_MERGE_FACT_CDR_USAGE        RESUME;

ALTER TASK ORCHESTRATION.TASK_LOAD_STG_CUSTOMERS          RESUME;
ALTER TASK ORCHESTRATION.TASK_LOAD_STG_PLANS              RESUME;
ALTER TASK ORCHESTRATION.TASK_LOAD_STG_DEVICES            RESUME;
ALTER TASK ORCHESTRATION.TASK_LOAD_STG_TOWERS             RESUME;
ALTER TASK ORCHESTRATION.TASK_LOAD_STG_BILLING            RESUME;
ALTER TASK ORCHESTRATION.TASK_LOAD_STG_PAYMENTS           RESUME;
ALTER TASK ORCHESTRATION.TASK_LOAD_STG_SUPPORT_TICKETS    RESUME;
ALTER TASK ORCHESTRATION.TASK_LOAD_STG_CDR                RESUME;

SELECT '>>> ALL 16 FILES DEPLOYED SUCCESSFULLY' AS deploy_marker;

