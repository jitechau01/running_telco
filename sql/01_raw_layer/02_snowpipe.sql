
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

