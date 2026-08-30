
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

