
/* ==========================================================================
   RUNNING TELCO — RAW LAYER VALIDATION
   ERROR_SCHEMA: tables that back SP_VALIDATE_RAW_* (sql/09_validation/02_sp_validate_raw.sql)

   Three tables + a rule reference:
     VALIDATION_RUN_SUMMARY   -> one row per (run, rule) - pass/fail counts.
                                  Same shape/purpose as AUDIT_CTL.DQ_CHECK_LOG,
                                  kept here instead so all validation output
                                  (summary + detail) lives in one schema.
     VALIDATION_ERROR_LOG     -> one row per (record, rule) violation - the
                                  actual failing record (as VARIANT) plus
                                  which rule it broke. This is the "capture
                                  validation failing records" table.
     SRC_TARGET_COUNT_LOG     -> one row per source file - rows in the S3
                                  file (still readable from the external
                                  stage, PURGE=FALSE) vs rows landed in the
                                  RAW table for that file.
     VALIDATION_RULE_REGISTRY -> human-readable reference of every rule the
                                  procedures enforce. NOTE: this table is
                                  documentation, not configuration - editing
                                  a row here does not change what the
                                  procedures check (they're plain SQL, same
                                  as every other procedure in this repo, not
                                  a dynamic rule engine). Change the rule in
                                  the procedure body AND update this table so
                                  they stay in sync. See the header comment
                                  in 02_sp_validate_raw.sql for why.
   ========================================================================== */

USE DATABASE RUNNING_TELCO;
USE SCHEMA ERROR_SCHEMA;

CREATE TABLE IF NOT EXISTS ERROR_SCHEMA.VALIDATION_RUN_SUMMARY (
    validation_id       NUMBER AUTOINCREMENT START 1 INCREMENT 1,
    run_id               NUMBER,                  -- AUDIT_CTL.ETL_RUN_LOG.run_id for this validation execution
    job_name              VARCHAR(100),            -- e.g. 'VALIDATE_RAW_CUSTOMERS'
    feed_name               VARCHAR(50),           -- e.g. 'customers' (FEED_REGISTRY key in python/config/config.py)
    table_name                 VARCHAR(200),       -- e.g. 'RAW.RAW_CUSTOMERS'
    rule_type                     VARCHAR(50),     -- ROW_COUNT_RECONCILIATION | NOT_NULL | DATE_FORMAT | ACCEPTED_VALUES
    column_name                      VARCHAR(100), -- NULL for table-level rules (e.g. row count reconciliation)
    records_checked                     NUMBER,
    records_failed                         NUMBER,
    check_status                              VARCHAR(10),  -- PASS / FAIL
    checked_at            TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT PK_VALIDATION_RUN_SUMMARY PRIMARY KEY (validation_id)
)
COMMENT = 'One row per validation rule executed per run - pass/fail counts. Row-level detail is in VALIDATION_ERROR_LOG.';

CREATE TABLE IF NOT EXISTS ERROR_SCHEMA.VALIDATION_ERROR_LOG (
    error_row_id         NUMBER AUTOINCREMENT START 1 INCREMENT 1,
    run_id                 NUMBER,
    job_name                  VARCHAR(100),
    feed_name                    VARCHAR(50),
    table_name                      VARCHAR(200),
    rule_type                          VARCHAR(50),
    column_name                           VARCHAR(100),
    record_key                               VARCHAR(200),   -- best-effort natural key of the offending row (customer_id, cdr_id, ...) - can be NULL if the key column itself is what's null
    failed_value                                VARCHAR(4000),
    error_reason                                   VARCHAR(500),
    source_file_name                                  VARCHAR(500),
    raw_record                                           VARIANT,        -- OBJECT_CONSTRUCT(*) - the full offending RAW row, for triage/reprocessing
    load_ts                                                 TIMESTAMP_NTZ, -- the offending row's RAW._load_ts
    logged_at              TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    is_resolved               BOOLEAN DEFAULT FALSE,
    resolved_at                  TIMESTAMP_NTZ,
    resolved_by                     VARCHAR(100),
    CONSTRAINT PK_VALIDATION_ERROR_LOG PRIMARY KEY (error_row_id)
)
COMMENT = 'Individual RAW-layer records that failed a validation rule. One row per (record, rule) violation - a row breaking two rules produces two rows here.';

CREATE TABLE IF NOT EXISTS ERROR_SCHEMA.SRC_TARGET_COUNT_LOG (
    count_check_id        NUMBER AUTOINCREMENT START 1 INCREMENT 1,
    run_id                  NUMBER,
    feed_name                  VARCHAR(50),
    table_name                    VARCHAR(200),
    source_file_name                 VARCHAR(500),
    source_row_count                    NUMBER,      -- counted directly off the file still sitting in the external stage
    target_row_count                       NUMBER,   -- COUNT(*) in the RAW table for that source_file_name
    row_count_variance                        NUMBER, -- target - source; 0 = match
    check_status                                 VARCHAR(10), -- MATCH / MISMATCH / SKIPPED (file no longer readable in stage, e.g. purged)
    checked_at              TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT PK_SRC_TARGET_COUNT_LOG PRIMARY KEY (count_check_id)
)
COMMENT = 'Per-file reconciliation: rows in the S3 source file vs rows landed in the RAW table for that file. Relies on stages being loaded with PURGE=FALSE (see python/orchestration/snowflake_orchestrator.py).';

CREATE TABLE IF NOT EXISTS ERROR_SCHEMA.VALIDATION_RULE_REGISTRY (
    rule_id              NUMBER AUTOINCREMENT START 1 INCREMENT 1,
    feed_name              VARCHAR(50)  NOT NULL,
    table_name                VARCHAR(200) NOT NULL,
    column_name                  VARCHAR(100),
    rule_type                       VARCHAR(50)  NOT NULL,
    rule_detail                        VARCHAR(500),    -- human-readable description of what's enforced
    is_active                             BOOLEAN DEFAULT TRUE,
    CONSTRAINT PK_VALIDATION_RULE_REGISTRY PRIMARY KEY (rule_id)
)
COMMENT = 'Documentation of every rule SP_VALIDATE_RAW_* enforces - readable reference for auditors/analysts, not a config table the procedures read from.';

CREATE OR REPLACE VIEW ERROR_SCHEMA.VW_VALIDATION_SUMMARY_TODAY AS
SELECT feed_name, table_name, rule_type, column_name,
       SUM(records_checked)                        AS records_checked,
       SUM(records_failed)                          AS records_failed,
       ROUND(100.0 * SUM(records_failed) / NULLIF(SUM(records_checked), 0), 3) AS pct_failed,
       MAX(checked_at)                              AS last_checked_at
FROM ERROR_SCHEMA.VALIDATION_RUN_SUMMARY
WHERE checked_at::DATE = CURRENT_DATE()
GROUP BY feed_name, table_name, rule_type, column_name
ORDER BY records_failed DESC;

CREATE OR REPLACE VIEW ERROR_SCHEMA.VW_OPEN_VALIDATION_ERRORS AS
SELECT error_row_id, run_id, feed_name, table_name, rule_type, column_name,
       record_key, failed_value, error_reason, source_file_name, load_ts, logged_at
FROM ERROR_SCHEMA.VALIDATION_ERROR_LOG
WHERE is_resolved = FALSE
ORDER BY logged_at DESC;

CREATE OR REPLACE VIEW ERROR_SCHEMA.VW_COUNT_RECONCILIATION_MISMATCHES AS
SELECT feed_name, table_name, source_file_name, source_row_count, target_row_count,
       row_count_variance, checked_at
FROM ERROR_SCHEMA.SRC_TARGET_COUNT_LOG
WHERE check_status = 'MISMATCH'
ORDER BY checked_at DESC;

/* ==========================================================================
   RULE REGISTRY SEED DATA - keep in sync with the procedure bodies in
   02_sp_validate_raw.sql. See that file's header for the accepted-value
   domains and why they're hardcoded there rather than read from here.
   ========================================================================== */
MERGE INTO ERROR_SCHEMA.VALIDATION_RULE_REGISTRY tgt
USING (
    SELECT * FROM VALUES
    ('customers','RAW.RAW_CUSTOMERS','ALL','ROW_COUNT_RECONCILIATION','Source file row count vs RAW.RAW_CUSTOMERS row count, per source_file_name'),
    ('customers','RAW.RAW_CUSTOMERS','customer_id','NOT_NULL','customer_id must not be null'),
    ('customers','RAW.RAW_CUSTOMERS','date_of_birth','DATE_FORMAT','Must parse as a date (TRY_TO_DATE), expected YYYY-MM-DD'),
    ('customers','RAW.RAW_CUSTOMERS','activation_date','DATE_FORMAT','Must parse as a date (TRY_TO_DATE), expected YYYY-MM-DD'),
    ('customers','RAW.RAW_CUSTOMERS','account_status','ACCEPTED_VALUES','ACTIVE, SUSPENDED, CHURNED'),
    ('customers','RAW.RAW_CUSTOMERS','customer_segment','ACCEPTED_VALUES','CONSUMER, SME, ENTERPRISE'),
    ('customers','RAW.RAW_CUSTOMERS','region','ACCEPTED_VALUES','NORTH, SOUTH, EAST, WEST'),

    ('plans','RAW.RAW_PLANS','ALL','ROW_COUNT_RECONCILIATION','Source file row count vs RAW.RAW_PLANS row count, per source_file_name'),
    ('plans','RAW.RAW_PLANS','plan_id','NOT_NULL','plan_id must not be null'),
    ('plans','RAW.RAW_PLANS','effective_date','DATE_FORMAT','Must parse as a date (TRY_TO_DATE), expected YYYY-MM-DD'),
    ('plans','RAW.RAW_PLANS','plan_type','ACCEPTED_VALUES','PREPAID, POSTPAID'),

    ('devices','RAW.RAW_DEVICES','ALL','ROW_COUNT_RECONCILIATION','Source file row count vs RAW.RAW_DEVICES row count, per source_file_name'),
    ('devices','RAW.RAW_DEVICES','device_id','NOT_NULL','device_id must not be null'),
    ('devices','RAW.RAW_DEVICES','activation_date','DATE_FORMAT','Must parse as a date (TRY_TO_DATE), expected YYYY-MM-DD'),
    ('devices','RAW.RAW_DEVICES','device_status','ACCEPTED_VALUES','ACTIVE, INACTIVE'),

    ('cdr','RAW.RAW_CDR','ALL','ROW_COUNT_RECONCILIATION','Source file row count vs RAW.RAW_CDR row count, per source_file_name'),
    ('cdr','RAW.RAW_CDR','cdr_id','NOT_NULL','cdr_id must not be null'),
    ('cdr','RAW.RAW_CDR','call_start_ts','DATE_FORMAT','Must parse as a timestamp (TRY_TO_TIMESTAMP_NTZ), expected YYYY-MM-DD HH24:MI:SS'),
    ('cdr','RAW.RAW_CDR','call_end_ts','DATE_FORMAT','Must parse as a timestamp (TRY_TO_TIMESTAMP_NTZ), expected YYYY-MM-DD HH24:MI:SS'),
    ('cdr','RAW.RAW_CDR','call_type','ACCEPTED_VALUES','VOICE, SMS, DATA'),
    ('cdr','RAW.RAW_CDR','roaming_flag','ACCEPTED_VALUES','Y, N'),
    ('cdr','RAW.RAW_CDR','region','ACCEPTED_VALUES','NORTH, SOUTH, EAST, WEST'),

    ('billing','RAW.RAW_BILLING','ALL','ROW_COUNT_RECONCILIATION','Source file row count vs RAW.RAW_BILLING row count, per source_file_name'),
    ('billing','RAW.RAW_BILLING','invoice_id','NOT_NULL','invoice_id must not be null'),
    ('billing','RAW.RAW_BILLING','billing_period','DATE_FORMAT','Must match YYYY-MM'),
    ('billing','RAW.RAW_BILLING','invoice_date','DATE_FORMAT','Must parse as a date (TRY_TO_DATE), expected YYYY-MM-DD'),
    ('billing','RAW.RAW_BILLING','due_date','DATE_FORMAT','Must parse as a date (TRY_TO_DATE), expected YYYY-MM-DD'),
    ('billing','RAW.RAW_BILLING','invoice_status','ACCEPTED_VALUES','PAID, OPEN, OVERDUE'),

    ('payments','RAW.RAW_PAYMENTS','ALL','ROW_COUNT_RECONCILIATION','Source file row count vs RAW.RAW_PAYMENTS row count, per source_file_name'),
    ('payments','RAW.RAW_PAYMENTS','payment_id','NOT_NULL','payment_id must not be null'),
    ('payments','RAW.RAW_PAYMENTS','payment_date','DATE_FORMAT','Must parse as a date (TRY_TO_DATE), expected YYYY-MM-DD'),
    ('payments','RAW.RAW_PAYMENTS','payment_method','ACCEPTED_VALUES','CARD, BANK_TRANSFER, WALLET, CASH'),
    ('payments','RAW.RAW_PAYMENTS','payment_status','ACCEPTED_VALUES','SUCCESS, FAILED, PENDING, REFUNDED'),

    ('towers','RAW.RAW_TOWERS','ALL','ROW_COUNT_RECONCILIATION','Source file row count vs RAW.RAW_TOWERS row count, per source_file_name'),
    ('towers','RAW.RAW_TOWERS','tower_id','NOT_NULL','tower_id must not be null'),
    ('towers','RAW.RAW_TOWERS','region','ACCEPTED_VALUES','NORTH, SOUTH, EAST, WEST'),
    ('towers','RAW.RAW_TOWERS','tower_status','ACCEPTED_VALUES','ACTIVE, MAINTENANCE, INACTIVE'),

    ('support_tickets','RAW.RAW_SUPPORT_TICKETS','ALL','ROW_COUNT_RECONCILIATION','Source file row count vs RAW.RAW_SUPPORT_TICKETS row count, per source_file_name'),
    ('support_tickets','RAW.RAW_SUPPORT_TICKETS','ticket_id','NOT_NULL','ticket_id must not be null'),
    ('support_tickets','RAW.RAW_SUPPORT_TICKETS','opened_at','DATE_FORMAT','Must parse as a timestamp (TRY_TO_TIMESTAMP_NTZ)'),
    ('support_tickets','RAW.RAW_SUPPORT_TICKETS','closed_at','DATE_FORMAT','Must parse as a timestamp (TRY_TO_TIMESTAMP_NTZ) when not null'),
    ('support_tickets','RAW.RAW_SUPPORT_TICKETS','category','ACCEPTED_VALUES','BILLING, NETWORK, DEVICE, PLAN_CHANGE, OTHER'),
    ('support_tickets','RAW.RAW_SUPPORT_TICKETS','priority','ACCEPTED_VALUES','LOW, MEDIUM, HIGH, URGENT'),
    ('support_tickets','RAW.RAW_SUPPORT_TICKETS','ticket_status','ACCEPTED_VALUES','OPEN, CLOSED, IN_PROGRESS, ESCALATED'),
    ('support_tickets','RAW.RAW_SUPPORT_TICKETS','channel','ACCEPTED_VALUES','CALL, CHAT, EMAIL, APP')
) AS src(feed_name, table_name, column_name, rule_type, rule_detail)
ON  tgt.feed_name = src.feed_name AND tgt.table_name = src.table_name
    AND tgt.column_name = src.column_name AND tgt.rule_type = src.rule_type
WHEN NOT MATCHED THEN
  INSERT (feed_name, table_name, column_name, rule_type, rule_detail)
  VALUES (src.feed_name, src.table_name, src.column_name, src.rule_type, src.rule_detail);
