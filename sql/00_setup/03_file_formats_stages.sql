
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
   NOTE: storage_aws_role_arn is created in AWS IAM first, then the
   generated STORAGE_AWS_IAM_USER_ARN / EXTERNAL_ID from DESC INTEGRATION
   is pasted into the S3 bucket policy trust relationship. Chicken-and-egg
   two-step setup - standard Snowflake<->AWS pattern.
   ========================================================================== */
/*
CREATE STORAGE INTEGRATION IF NOT EXISTS S3_RUNNINGTELCO_INT
  TYPE = EXTERNAL_STAGE
  STORAGE_PROVIDER = 'S3'
  ENABLED = TRUE
  STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::1087-8209-1836:role/snowflake-runningtelco-s3-role'
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
  */

-- DESC INTEGRATION S3_RUNNINGTELCO_INT;  -- copy STORAGE_AWS_IAM_USER_ARN + STORAGE_AWS_EXTERNAL_ID into AWS trust policy

grant usage on integration S3_RUNNINGTELCO_INT to role R_DATA_ENGINEER;

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

