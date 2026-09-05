
/* ==========================================================================
   RUNNING TELCO — RAW LAYER VALIDATION PROCEDURES
   One SP_VALIDATE_RAW_<FEED>() per feed, same shape as
   STAGING.SP_LOAD_STG_<FEED>() in sql/04_procedures/01_sp_raw_to_staging.sql
   so the pattern is familiar: raw load (Python COPY INTO) -> THIS -> staging
   load. Called from python/orchestration/snowflake_orchestrator.py via
   `--layer validate` (added alongside raw|staging|curated - see that file
   and python/config/config.py FEED_REGISTRY[*]['validate_proc']), or
   directly: CALL ERROR_SCHEMA.SP_VALIDATE_RAW_CUSTOMERS();

   WHAT EACH PROCEDURE CHECKS (per the four categories asked for):
     1. ROW COUNT RECONCILIATION - for every distinct source_file_name
        already landed in the RAW table, re-count the same file directly off
        the external stage (SELECT COUNT(*) FROM @stage/<file> ...) and
        compare to COUNT(*) in the RAW table for that file. Requires the
        file to still be sitting in the stage, i.e. PURGE=FALSE on the COPY
        INTO that loaded it - true today (see snowflake_orchestrator.py). If
        a file has since been purged/archived out of the stage, the check is
        logged as SKIPPED, not FAILED - a missing file to compare against is
        not itself a data quality defect.
     2. NOT NULL - every column this repo already treats as a required key
        elsewhere (the same columns STAGING.SP_LOAD_STG_* filters out with
        `WHERE <key> IS NOT NULL`), checked one layer earlier, at RAW.
     3. DATE FORMAT - every column that STAGING.SP_LOAD_STG_* wraps in
        TRY_TO_DATE / TRY_TO_TIMESTAMP_NTZ, checked here with the same
        function so a row that would silently become NULL downstream is
        instead caught and logged with the original unparseable string.
     4. ACCEPTED VALUES - every enum-like column, checked against the
        domain the source system actually produces (see
        python/ingestion/generate_telecom_data.py). These lists are
        HARDCODED in each procedure below rather than read from
        ERROR_SCHEMA.VALIDATION_RULE_REGISTRY at runtime - that table is a
        readable reference only (see its comment in 01_error_schema_tables.sql
        for why: a fully dynamic rule engine would need EXECUTE IMMEDIATE
        for every single check, which is harder to read, debug, and unit
        test than plain SQL, and would be inconsistent with how every other
        procedure in this repo is written). If your real source system's
        domain differs, edit the IN (...) list below AND the matching row in
        VALIDATION_RULE_REGISTRY so the two stay in sync.

   Every failing row is inserted into ERROR_SCHEMA.VALIDATION_ERROR_LOG with
   the full RAW row captured as VARIANT (OBJECT_CONSTRUCT(*)) for triage/
   reprocessing, and every rule's pass/fail counts go to
   ERROR_SCHEMA.VALIDATION_RUN_SUMMARY. Nothing here blocks or deletes from
   RAW - validation is observability, not a gate; STAGING.SP_LOAD_STG_* still
   does its own defensive filtering independently, exactly as before this
   file existed.
   ========================================================================== */

USE DATABASE RUNNING_TELCO;
USE SCHEMA ERROR_SCHEMA;

-- ------------------------------------------------------------------------ --
-- Shared helper - logs one rule's pass/fail counts. Same pattern as
-- AUDIT_CTL.SP_LOG_DQ_CHECK, kept in ERROR_SCHEMA so summary + detail live
-- together.
-- ------------------------------------------------------------------------ --
CREATE OR REPLACE PROCEDURE ERROR_SCHEMA.SP_LOG_VALIDATION_RESULT(
    P_RUN_ID NUMBER,
    P_JOB_NAME STRING,
    P_FEED_NAME STRING,
    P_TABLE_NAME STRING,
    P_RULE_TYPE STRING,
    P_COLUMN_NAME STRING,
    P_RECORDS_CHECKED NUMBER,
    P_RECORDS_FAILED NUMBER
)
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
    INSERT INTO ERROR_SCHEMA.VALIDATION_RUN_SUMMARY
        (run_id, job_name, feed_name, table_name, rule_type, column_name,
         records_checked, records_failed, check_status)
    VALUES
        (:P_RUN_ID, :P_JOB_NAME, :P_FEED_NAME, :P_TABLE_NAME, :P_RULE_TYPE, :P_COLUMN_NAME,
         :P_RECORDS_CHECKED, :P_RECORDS_FAILED, IFF(:P_RECORDS_FAILED = 0, 'PASS', 'FAIL'));
    RETURN 'OK';
END;
$$;


/* ==========================================================================
   1. CUSTOMERS
   ========================================================================== */
CREATE OR REPLACE PROCEDURE ERROR_SCHEMA.SP_VALIDATE_RAW_CUSTOMERS()
RETURNS STRING
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_run_id       NUMBER;
    v_job_name     STRING DEFAULT 'VALIDATE_RAW_CUSTOMERS';
    v_total_rows   NUMBER DEFAULT 0;
    v_total_failed NUMBER DEFAULT 0;
    v_failed       NUMBER DEFAULT 0;
    v_file         STRING;
    v_safe_file    STRING;
    v_stmt         STRING;
    v_src_count    NUMBER;
    v_tgt_count    NUMBER;
    file_cursor CURSOR FOR
        SELECT DISTINCT source_file_name AS fname
        FROM RAW.RAW_CUSTOMERS
        WHERE source_file_name IS NOT NULL;
BEGIN
    v_run_id := (CALL AUDIT_CTL.SP_AUDIT_START(:v_job_name, 'TASK'));
    SELECT COUNT(*) INTO :v_total_rows FROM RAW.RAW_CUSTOMERS;

    -- ---- 1. ROW COUNT RECONCILIATION (source file vs RAW table, per file) ----
    FOR rec IN file_cursor DO
        v_file := rec.fname;
        v_safe_file := REPLACE(v_file, '''', '''''');

        SELECT COUNT(*) INTO :v_tgt_count
        FROM RAW.RAW_CUSTOMERS WHERE source_file_name = :v_file;

        BEGIN
            v_stmt := 'SELECT COUNT(*) AS CNT FROM @RAW.STG_CUSTOMERS/' || v_safe_file ||
                      ' (FILE_FORMAT => ''RAW.FF_CSV_STANDARD'')';
            EXECUTE IMMEDIATE :v_stmt;
            SELECT CNT INTO :v_src_count FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
        EXCEPTION
            WHEN OTHER THEN
                v_src_count := NULL;  -- file no longer readable in stage (purged/moved) - can't reconcile
        END;

        INSERT INTO ERROR_SCHEMA.SRC_TARGET_COUNT_LOG
            (run_id, feed_name, table_name, source_file_name, source_row_count, target_row_count,
             row_count_variance, check_status)
        VALUES
            (:v_run_id, 'customers', 'RAW.RAW_CUSTOMERS', :v_file, :v_src_count, :v_tgt_count,
             IFF(:v_src_count IS NULL, NULL, :v_tgt_count - :v_src_count),
             CASE WHEN :v_src_count IS NULL THEN 'SKIPPED'
                  WHEN :v_src_count = :v_tgt_count THEN 'MATCH'
                  ELSE 'MISMATCH' END);
    END FOR;

    -- ---- 2. NOT NULL: customer_id ----
    SELECT COUNT(*) INTO :v_failed FROM RAW.RAW_CUSTOMERS WHERE customer_id IS NULL;
    IF (v_failed > 0) THEN
        INSERT INTO ERROR_SCHEMA.VALIDATION_ERROR_LOG
            (run_id, job_name, feed_name, table_name, rule_type, column_name, record_key,
             failed_value, error_reason, source_file_name, raw_record, load_ts)
        SELECT :v_run_id, :v_job_name, 'customers', 'RAW.RAW_CUSTOMERS', 'NOT_NULL', 'customer_id',
               customer_id, customer_id, 'customer_id is NULL', source_file_name, OBJECT_CONSTRUCT(*), _load_ts
        FROM RAW.RAW_CUSTOMERS WHERE customer_id IS NULL;
    END IF;
    CALL ERROR_SCHEMA.SP_LOG_VALIDATION_RESULT(:v_run_id, :v_job_name, 'customers', 'RAW.RAW_CUSTOMERS',
        'NOT_NULL', 'customer_id', :v_total_rows, :v_failed);
    v_total_failed := v_total_failed + v_failed;

    -- ---- 3. DATE FORMAT: date_of_birth, activation_date ----
    SELECT COUNT(*) INTO :v_failed FROM RAW.RAW_CUSTOMERS
    WHERE date_of_birth IS NOT NULL AND TRY_TO_DATE(date_of_birth) IS NULL;
    IF (v_failed > 0) THEN
        INSERT INTO ERROR_SCHEMA.VALIDATION_ERROR_LOG
            (run_id, job_name, feed_name, table_name, rule_type, column_name, record_key,
             failed_value, error_reason, source_file_name, raw_record, load_ts)
        SELECT :v_run_id, :v_job_name, 'customers', 'RAW.RAW_CUSTOMERS', 'DATE_FORMAT', 'date_of_birth',
               customer_id, date_of_birth, 'date_of_birth is not a parseable date (expected YYYY-MM-DD)',
               source_file_name, OBJECT_CONSTRUCT(*), _load_ts
        FROM RAW.RAW_CUSTOMERS
        WHERE date_of_birth IS NOT NULL AND TRY_TO_DATE(date_of_birth) IS NULL;
    END IF;
    CALL ERROR_SCHEMA.SP_LOG_VALIDATION_RESULT(:v_run_id, :v_job_name, 'customers', 'RAW.RAW_CUSTOMERS',
        'DATE_FORMAT', 'date_of_birth', :v_total_rows, :v_failed);
    v_total_failed := v_total_failed + v_failed;

    SELECT COUNT(*) INTO :v_failed FROM RAW.RAW_CUSTOMERS
    WHERE activation_date IS NOT NULL AND TRY_TO_DATE(activation_date) IS NULL;
    IF (v_failed > 0) THEN
        INSERT INTO ERROR_SCHEMA.VALIDATION_ERROR_LOG
            (run_id, job_name, feed_name, table_name, rule_type, column_name, record_key,
             failed_value, error_reason, source_file_name, raw_record, load_ts)
        SELECT :v_run_id, :v_job_name, 'customers', 'RAW.RAW_CUSTOMERS', 'DATE_FORMAT', 'activation_date',
               customer_id, activation_date, 'activation_date is not a parseable date (expected YYYY-MM-DD)',
               source_file_name, OBJECT_CONSTRUCT(*), _load_ts
        FROM RAW.RAW_CUSTOMERS
        WHERE activation_date IS NOT NULL AND TRY_TO_DATE(activation_date) IS NULL;
    END IF;
    CALL ERROR_SCHEMA.SP_LOG_VALIDATION_RESULT(:v_run_id, :v_job_name, 'customers', 'RAW.RAW_CUSTOMERS',
        'DATE_FORMAT', 'activation_date', :v_total_rows, :v_failed);
    v_total_failed := v_total_failed + v_failed;

    -- ---- 4. ACCEPTED VALUES: account_status, customer_segment, region ----
    SELECT COUNT(*) INTO :v_failed FROM RAW.RAW_CUSTOMERS
    WHERE account_status IS NOT NULL AND account_status NOT IN ('ACTIVE','SUSPENDED','CHURNED');
    IF (v_failed > 0) THEN
        INSERT INTO ERROR_SCHEMA.VALIDATION_ERROR_LOG
            (run_id, job_name, feed_name, table_name, rule_type, column_name, record_key,
             failed_value, error_reason, source_file_name, raw_record, load_ts)
        SELECT :v_run_id, :v_job_name, 'customers', 'RAW.RAW_CUSTOMERS', 'ACCEPTED_VALUES', 'account_status',
               customer_id, account_status, 'account_status not in (ACTIVE, SUSPENDED, CHURNED)',
               source_file_name, OBJECT_CONSTRUCT(*), _load_ts
        FROM RAW.RAW_CUSTOMERS
        WHERE account_status IS NOT NULL AND account_status NOT IN ('ACTIVE','SUSPENDED','CHURNED');
    END IF;
    CALL ERROR_SCHEMA.SP_LOG_VALIDATION_RESULT(:v_run_id, :v_job_name, 'customers', 'RAW.RAW_CUSTOMERS',
        'ACCEPTED_VALUES', 'account_status', :v_total_rows, :v_failed);
    v_total_failed := v_total_failed + v_failed;

    SELECT COUNT(*) INTO :v_failed FROM RAW.RAW_CUSTOMERS
    WHERE customer_segment IS NOT NULL AND customer_segment NOT IN ('CONSUMER','SME','ENTERPRISE');
    IF (v_failed > 0) THEN
        INSERT INTO ERROR_SCHEMA.VALIDATION_ERROR_LOG
            (run_id, job_name, feed_name, table_name, rule_type, column_name, record_key,
             failed_value, error_reason, source_file_name, raw_record, load_ts)
        SELECT :v_run_id, :v_job_name, 'customers', 'RAW.RAW_CUSTOMERS', 'ACCEPTED_VALUES', 'customer_segment',
               customer_id, customer_segment, 'customer_segment not in (CONSUMER, SME, ENTERPRISE)',
               source_file_name, OBJECT_CONSTRUCT(*), _load_ts
        FROM RAW.RAW_CUSTOMERS
        WHERE customer_segment IS NOT NULL AND customer_segment NOT IN ('CONSUMER','SME','ENTERPRISE');
    END IF;
    CALL ERROR_SCHEMA.SP_LOG_VALIDATION_RESULT(:v_run_id, :v_job_name, 'customers', 'RAW.RAW_CUSTOMERS',
        'ACCEPTED_VALUES', 'customer_segment', :v_total_rows, :v_failed);
    v_total_failed := v_total_failed + v_failed;

    SELECT COUNT(*) INTO :v_failed FROM RAW.RAW_CUSTOMERS
    WHERE region IS NOT NULL AND region NOT IN ('NORTH','SOUTH','EAST','WEST');
    IF (v_failed > 0) THEN
        INSERT INTO ERROR_SCHEMA.VALIDATION_ERROR_LOG
            (run_id, job_name, feed_name, table_name, rule_type, column_name, record_key,
             failed_value, error_reason, source_file_name, raw_record, load_ts)
        SELECT :v_run_id, :v_job_name, 'customers', 'RAW.RAW_CUSTOMERS', 'ACCEPTED_VALUES', 'region',
               customer_id, region, 'region not in (NORTH, SOUTH, EAST, WEST)',
               source_file_name, OBJECT_CONSTRUCT(*), _load_ts
        FROM RAW.RAW_CUSTOMERS
        WHERE region IS NOT NULL AND region NOT IN ('NORTH','SOUTH','EAST','WEST');
    END IF;
    CALL ERROR_SCHEMA.SP_LOG_VALIDATION_RESULT(:v_run_id, :v_job_name, 'customers', 'RAW.RAW_CUSTOMERS',
        'ACCEPTED_VALUES', 'region', :v_total_rows, :v_failed);
    v_total_failed := v_total_failed + v_failed;

    CALL AUDIT_CTL.SP_AUDIT_END(:v_run_id, :v_total_rows, :v_total_rows, 0, 0, :v_total_failed,
        'RAW_CUSTOMERS validation complete: ' || v_total_failed || ' rule violation(s) across ' || v_total_rows || ' row(s)');
    RETURN 'SUCCESS run_id=' || v_run_id || ' rows_checked=' || v_total_rows || ' violations=' || v_total_failed;
EXCEPTION
    WHEN OTHER THEN
        CALL AUDIT_CTL.SP_AUDIT_FAIL(:v_run_id, 'SQL_ERROR', :sqlcode, :sqlerrm,
            OBJECT_CONSTRUCT('procedure', 'SP_VALIDATE_RAW_CUSTOMERS'));
        RAISE;
END;
$$;


/* ==========================================================================
   2. PLANS
   ========================================================================== */
CREATE OR REPLACE PROCEDURE ERROR_SCHEMA.SP_VALIDATE_RAW_PLANS()
RETURNS STRING
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_run_id       NUMBER;
    v_job_name     STRING DEFAULT 'VALIDATE_RAW_PLANS';
    v_total_rows   NUMBER DEFAULT 0;
    v_total_failed NUMBER DEFAULT 0;
    v_failed       NUMBER DEFAULT 0;
    v_file         STRING;
    v_safe_file    STRING;
    v_stmt         STRING;
    v_src_count    NUMBER;
    v_tgt_count    NUMBER;
    file_cursor CURSOR FOR
        SELECT DISTINCT source_file_name AS fname FROM RAW.RAW_PLANS WHERE source_file_name IS NOT NULL;
BEGIN
    v_run_id := (CALL AUDIT_CTL.SP_AUDIT_START(:v_job_name, 'TASK'));
    SELECT COUNT(*) INTO :v_total_rows FROM RAW.RAW_PLANS;

    FOR rec IN file_cursor DO
        v_file := rec.fname;
        v_safe_file := REPLACE(v_file, '''', '''''');
        SELECT COUNT(*) INTO :v_tgt_count FROM RAW.RAW_PLANS WHERE source_file_name = :v_file;
        BEGIN
            v_stmt := 'SELECT COUNT(*) AS CNT FROM @RAW.STG_PLANS/' || v_safe_file ||
                      ' (FILE_FORMAT => ''RAW.FF_CSV_STANDARD'')';
            EXECUTE IMMEDIATE :v_stmt;
            SELECT CNT INTO :v_src_count FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
        EXCEPTION
            WHEN OTHER THEN v_src_count := NULL;
        END;
        INSERT INTO ERROR_SCHEMA.SRC_TARGET_COUNT_LOG
            (run_id, feed_name, table_name, source_file_name, source_row_count, target_row_count,
             row_count_variance, check_status)
        VALUES
            (:v_run_id, 'plans', 'RAW.RAW_PLANS', :v_file, :v_src_count, :v_tgt_count,
             IFF(:v_src_count IS NULL, NULL, :v_tgt_count - :v_src_count),
             CASE WHEN :v_src_count IS NULL THEN 'SKIPPED'
                  WHEN :v_src_count = :v_tgt_count THEN 'MATCH' ELSE 'MISMATCH' END);
    END FOR;

    -- NOT NULL: plan_id
    SELECT COUNT(*) INTO :v_failed FROM RAW.RAW_PLANS WHERE plan_id IS NULL;
    IF (v_failed > 0) THEN
        INSERT INTO ERROR_SCHEMA.VALIDATION_ERROR_LOG
            (run_id, job_name, feed_name, table_name, rule_type, column_name, record_key,
             failed_value, error_reason, source_file_name, raw_record, load_ts)
        SELECT :v_run_id, :v_job_name, 'plans', 'RAW.RAW_PLANS', 'NOT_NULL', 'plan_id',
               plan_id, plan_id, 'plan_id is NULL', source_file_name, OBJECT_CONSTRUCT(*), _load_ts
        FROM RAW.RAW_PLANS WHERE plan_id IS NULL;
    END IF;
    CALL ERROR_SCHEMA.SP_LOG_VALIDATION_RESULT(:v_run_id, :v_job_name, 'plans', 'RAW.RAW_PLANS',
        'NOT_NULL', 'plan_id', :v_total_rows, :v_failed);
    v_total_failed := v_total_failed + v_failed;

    -- DATE FORMAT: effective_date
    SELECT COUNT(*) INTO :v_failed FROM RAW.RAW_PLANS
    WHERE effective_date IS NOT NULL AND TRY_TO_DATE(effective_date) IS NULL;
    IF (v_failed > 0) THEN
        INSERT INTO ERROR_SCHEMA.VALIDATION_ERROR_LOG
            (run_id, job_name, feed_name, table_name, rule_type, column_name, record_key,
             failed_value, error_reason, source_file_name, raw_record, load_ts)
        SELECT :v_run_id, :v_job_name, 'plans', 'RAW.RAW_PLANS', 'DATE_FORMAT', 'effective_date',
               plan_id, effective_date, 'effective_date is not a parseable date (expected YYYY-MM-DD)',
               source_file_name, OBJECT_CONSTRUCT(*), _load_ts
        FROM RAW.RAW_PLANS WHERE effective_date IS NOT NULL AND TRY_TO_DATE(effective_date) IS NULL;
    END IF;
    CALL ERROR_SCHEMA.SP_LOG_VALIDATION_RESULT(:v_run_id, :v_job_name, 'plans', 'RAW.RAW_PLANS',
        'DATE_FORMAT', 'effective_date', :v_total_rows, :v_failed);
    v_total_failed := v_total_failed + v_failed;

    -- ACCEPTED VALUES: plan_type
    SELECT COUNT(*) INTO :v_failed FROM RAW.RAW_PLANS
    WHERE plan_type IS NOT NULL AND plan_type NOT IN ('PREPAID','POSTPAID');
    IF (v_failed > 0) THEN
        INSERT INTO ERROR_SCHEMA.VALIDATION_ERROR_LOG
            (run_id, job_name, feed_name, table_name, rule_type, column_name, record_key,
             failed_value, error_reason, source_file_name, raw_record, load_ts)
        SELECT :v_run_id, :v_job_name, 'plans', 'RAW.RAW_PLANS', 'ACCEPTED_VALUES', 'plan_type',
               plan_id, plan_type, 'plan_type not in (PREPAID, POSTPAID)',
               source_file_name, OBJECT_CONSTRUCT(*), _load_ts
        FROM RAW.RAW_PLANS WHERE plan_type IS NOT NULL AND plan_type NOT IN ('PREPAID','POSTPAID');
    END IF;
    CALL ERROR_SCHEMA.SP_LOG_VALIDATION_RESULT(:v_run_id, :v_job_name, 'plans', 'RAW.RAW_PLANS',
        'ACCEPTED_VALUES', 'plan_type', :v_total_rows, :v_failed);
    v_total_failed := v_total_failed + v_failed;

    CALL AUDIT_CTL.SP_AUDIT_END(:v_run_id, :v_total_rows, :v_total_rows, 0, 0, :v_total_failed,
        'RAW_PLANS validation complete: ' || v_total_failed || ' rule violation(s) across ' || v_total_rows || ' row(s)');
    RETURN 'SUCCESS run_id=' || v_run_id || ' rows_checked=' || v_total_rows || ' violations=' || v_total_failed;
EXCEPTION
    WHEN OTHER THEN
        CALL AUDIT_CTL.SP_AUDIT_FAIL(:v_run_id, 'SQL_ERROR', :sqlcode, :sqlerrm,
            OBJECT_CONSTRUCT('procedure', 'SP_VALIDATE_RAW_PLANS'));
        RAISE;
END;
$$;


/* ==========================================================================
   3. DEVICES
   ========================================================================== */
CREATE OR REPLACE PROCEDURE ERROR_SCHEMA.SP_VALIDATE_RAW_DEVICES()
RETURNS STRING
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_run_id       NUMBER;
    v_job_name     STRING DEFAULT 'VALIDATE_RAW_DEVICES';
    v_total_rows   NUMBER DEFAULT 0;
    v_total_failed NUMBER DEFAULT 0;
    v_failed       NUMBER DEFAULT 0;
    v_file         STRING;
    v_safe_file    STRING;
    v_stmt         STRING;
    v_src_count    NUMBER;
    v_tgt_count    NUMBER;
    file_cursor CURSOR FOR
        SELECT DISTINCT source_file_name AS fname FROM RAW.RAW_DEVICES WHERE source_file_name IS NOT NULL;
BEGIN
    v_run_id := (CALL AUDIT_CTL.SP_AUDIT_START(:v_job_name, 'TASK'));
    SELECT COUNT(*) INTO :v_total_rows FROM RAW.RAW_DEVICES;

    FOR rec IN file_cursor DO
        v_file := rec.fname;
        v_safe_file := REPLACE(v_file, '''', '''''');
        SELECT COUNT(*) INTO :v_tgt_count FROM RAW.RAW_DEVICES WHERE source_file_name = :v_file;
        BEGIN
            v_stmt := 'SELECT COUNT(*) AS CNT FROM @RAW.STG_DEVICES/' || v_safe_file ||
                      ' (FILE_FORMAT => ''RAW.FF_CSV_STANDARD'')';
            EXECUTE IMMEDIATE :v_stmt;
            SELECT CNT INTO :v_src_count FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
        EXCEPTION
            WHEN OTHER THEN v_src_count := NULL;
        END;
        INSERT INTO ERROR_SCHEMA.SRC_TARGET_COUNT_LOG
            (run_id, feed_name, table_name, source_file_name, source_row_count, target_row_count,
             row_count_variance, check_status)
        VALUES
            (:v_run_id, 'devices', 'RAW.RAW_DEVICES', :v_file, :v_src_count, :v_tgt_count,
             IFF(:v_src_count IS NULL, NULL, :v_tgt_count - :v_src_count),
             CASE WHEN :v_src_count IS NULL THEN 'SKIPPED'
                  WHEN :v_src_count = :v_tgt_count THEN 'MATCH' ELSE 'MISMATCH' END);
    END FOR;

    -- NOT NULL: device_id
    SELECT COUNT(*) INTO :v_failed FROM RAW.RAW_DEVICES WHERE device_id IS NULL;
    IF (v_failed > 0) THEN
        INSERT INTO ERROR_SCHEMA.VALIDATION_ERROR_LOG
            (run_id, job_name, feed_name, table_name, rule_type, column_name, record_key,
             failed_value, error_reason, source_file_name, raw_record, load_ts)
        SELECT :v_run_id, :v_job_name, 'devices', 'RAW.RAW_DEVICES', 'NOT_NULL', 'device_id',
               device_id, device_id, 'device_id is NULL', source_file_name, OBJECT_CONSTRUCT(*), _load_ts
        FROM RAW.RAW_DEVICES WHERE device_id IS NULL;
    END IF;
    CALL ERROR_SCHEMA.SP_LOG_VALIDATION_RESULT(:v_run_id, :v_job_name, 'devices', 'RAW.RAW_DEVICES',
        'NOT_NULL', 'device_id', :v_total_rows, :v_failed);
    v_total_failed := v_total_failed + v_failed;

    -- DATE FORMAT: activation_date
    SELECT COUNT(*) INTO :v_failed FROM RAW.RAW_DEVICES
    WHERE activation_date IS NOT NULL AND TRY_TO_DATE(activation_date) IS NULL;
    IF (v_failed > 0) THEN
        INSERT INTO ERROR_SCHEMA.VALIDATION_ERROR_LOG
            (run_id, job_name, feed_name, table_name, rule_type, column_name, record_key,
             failed_value, error_reason, source_file_name, raw_record, load_ts)
        SELECT :v_run_id, :v_job_name, 'devices', 'RAW.RAW_DEVICES', 'DATE_FORMAT', 'activation_date',
               device_id, activation_date, 'activation_date is not a parseable date (expected YYYY-MM-DD)',
               source_file_name, OBJECT_CONSTRUCT(*), _load_ts
        FROM RAW.RAW_DEVICES WHERE activation_date IS NOT NULL AND TRY_TO_DATE(activation_date) IS NULL;
    END IF;
    CALL ERROR_SCHEMA.SP_LOG_VALIDATION_RESULT(:v_run_id, :v_job_name, 'devices', 'RAW.RAW_DEVICES',
        'DATE_FORMAT', 'activation_date', :v_total_rows, :v_failed);
    v_total_failed := v_total_failed + v_failed;

    -- ACCEPTED VALUES: device_status
    SELECT COUNT(*) INTO :v_failed FROM RAW.RAW_DEVICES
    WHERE device_status IS NOT NULL AND device_status NOT IN ('ACTIVE','INACTIVE');
    IF (v_failed > 0) THEN
        INSERT INTO ERROR_SCHEMA.VALIDATION_ERROR_LOG
            (run_id, job_name, feed_name, table_name, rule_type, column_name, record_key,
             failed_value, error_reason, source_file_name, raw_record, load_ts)
        SELECT :v_run_id, :v_job_name, 'devices', 'RAW.RAW_DEVICES', 'ACCEPTED_VALUES', 'device_status',
               device_id, device_status, 'device_status not in (ACTIVE, INACTIVE)',
               source_file_name, OBJECT_CONSTRUCT(*), _load_ts
        FROM RAW.RAW_DEVICES WHERE device_status IS NOT NULL AND device_status NOT IN ('ACTIVE','INACTIVE');
    END IF;
    CALL ERROR_SCHEMA.SP_LOG_VALIDATION_RESULT(:v_run_id, :v_job_name, 'devices', 'RAW.RAW_DEVICES',
        'ACCEPTED_VALUES', 'device_status', :v_total_rows, :v_failed);
    v_total_failed := v_total_failed + v_failed;

    CALL AUDIT_CTL.SP_AUDIT_END(:v_run_id, :v_total_rows, :v_total_rows, 0, 0, :v_total_failed,
        'RAW_DEVICES validation complete: ' || v_total_failed || ' rule violation(s) across ' || v_total_rows || ' row(s)');
    RETURN 'SUCCESS run_id=' || v_run_id || ' rows_checked=' || v_total_rows || ' violations=' || v_total_failed;
EXCEPTION
    WHEN OTHER THEN
        CALL AUDIT_CTL.SP_AUDIT_FAIL(:v_run_id, 'SQL_ERROR', :sqlcode, :sqlerrm,
            OBJECT_CONSTRUCT('procedure', 'SP_VALIDATE_RAW_DEVICES'));
        RAISE;
END;
$$;


/* ==========================================================================
   4. CDR (highest volume feed - hourly/Snowpipe)
   The row-count reconciliation loop below re-reads every distinct file
   already landed for this feed; with CDR loading hourly this is normally a
   handful of recent files, not the whole history, since old
   source_file_name values still in RAW.RAW_CDR whose files have since been
   purged simply come back SKIPPED (see the note at the top of this file).
   ========================================================================== */
CREATE OR REPLACE PROCEDURE ERROR_SCHEMA.SP_VALIDATE_RAW_CDR()
RETURNS STRING
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_run_id       NUMBER;
    v_job_name     STRING DEFAULT 'VALIDATE_RAW_CDR';
    v_total_rows   NUMBER DEFAULT 0;
    v_total_failed NUMBER DEFAULT 0;
    v_failed       NUMBER DEFAULT 0;
    v_file         STRING;
    v_safe_file    STRING;
    v_stmt         STRING;
    v_src_count    NUMBER;
    v_tgt_count    NUMBER;
    file_cursor CURSOR FOR
        SELECT DISTINCT source_file_name AS fname FROM RAW.RAW_CDR WHERE source_file_name IS NOT NULL;
BEGIN
    v_run_id := (CALL AUDIT_CTL.SP_AUDIT_START(:v_job_name, 'TASK'));
    SELECT COUNT(*) INTO :v_total_rows FROM RAW.RAW_CDR;

    FOR rec IN file_cursor DO
        v_file := rec.fname;
        v_safe_file := REPLACE(v_file, '''', '''''');
        SELECT COUNT(*) INTO :v_tgt_count FROM RAW.RAW_CDR WHERE source_file_name = :v_file;
        BEGIN
            v_stmt := 'SELECT COUNT(*) AS CNT FROM @RAW.STG_CDR/' || v_safe_file ||
                      ' (FILE_FORMAT => ''RAW.FF_CSV_STANDARD'')';
            EXECUTE IMMEDIATE :v_stmt;
            SELECT CNT INTO :v_src_count FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
        EXCEPTION
            WHEN OTHER THEN v_src_count := NULL;
        END;
        INSERT INTO ERROR_SCHEMA.SRC_TARGET_COUNT_LOG
            (run_id, feed_name, table_name, source_file_name, source_row_count, target_row_count,
             row_count_variance, check_status)
        VALUES
            (:v_run_id, 'cdr', 'RAW.RAW_CDR', :v_file, :v_src_count, :v_tgt_count,
             IFF(:v_src_count IS NULL, NULL, :v_tgt_count - :v_src_count),
             CASE WHEN :v_src_count IS NULL THEN 'SKIPPED'
                  WHEN :v_src_count = :v_tgt_count THEN 'MATCH' ELSE 'MISMATCH' END);
    END FOR;

    -- NOT NULL: cdr_id
    SELECT COUNT(*) INTO :v_failed FROM RAW.RAW_CDR WHERE cdr_id IS NULL;
    IF (v_failed > 0) THEN
        INSERT INTO ERROR_SCHEMA.VALIDATION_ERROR_LOG
            (run_id, job_name, feed_name, table_name, rule_type, column_name, record_key,
             failed_value, error_reason, source_file_name, raw_record, load_ts)
        SELECT :v_run_id, :v_job_name, 'cdr', 'RAW.RAW_CDR', 'NOT_NULL', 'cdr_id',
               cdr_id, cdr_id, 'cdr_id is NULL', source_file_name, OBJECT_CONSTRUCT(*), _load_ts
        FROM RAW.RAW_CDR WHERE cdr_id IS NULL;
    END IF;
    CALL ERROR_SCHEMA.SP_LOG_VALIDATION_RESULT(:v_run_id, :v_job_name, 'cdr', 'RAW.RAW_CDR',
        'NOT_NULL', 'cdr_id', :v_total_rows, :v_failed);
    v_total_failed := v_total_failed + v_failed;

    -- DATE FORMAT: call_start_ts, call_end_ts
    SELECT COUNT(*) INTO :v_failed FROM RAW.RAW_CDR
    WHERE call_start_ts IS NOT NULL AND TRY_TO_TIMESTAMP_NTZ(call_start_ts) IS NULL;
    IF (v_failed > 0) THEN
        INSERT INTO ERROR_SCHEMA.VALIDATION_ERROR_LOG
            (run_id, job_name, feed_name, table_name, rule_type, column_name, record_key,
             failed_value, error_reason, source_file_name, raw_record, load_ts)
        SELECT :v_run_id, :v_job_name, 'cdr', 'RAW.RAW_CDR', 'DATE_FORMAT', 'call_start_ts',
               cdr_id, call_start_ts, 'call_start_ts is not a parseable timestamp (expected YYYY-MM-DD HH24:MI:SS)',
               source_file_name, OBJECT_CONSTRUCT(*), _load_ts
        FROM RAW.RAW_CDR WHERE call_start_ts IS NOT NULL AND TRY_TO_TIMESTAMP_NTZ(call_start_ts) IS NULL;
    END IF;
    CALL ERROR_SCHEMA.SP_LOG_VALIDATION_RESULT(:v_run_id, :v_job_name, 'cdr', 'RAW.RAW_CDR',
        'DATE_FORMAT', 'call_start_ts', :v_total_rows, :v_failed);
    v_total_failed := v_total_failed + v_failed;

    SELECT COUNT(*) INTO :v_failed FROM RAW.RAW_CDR
    WHERE call_end_ts IS NOT NULL AND TRY_TO_TIMESTAMP_NTZ(call_end_ts) IS NULL;
    IF (v_failed > 0) THEN
        INSERT INTO ERROR_SCHEMA.VALIDATION_ERROR_LOG
            (run_id, job_name, feed_name, table_name, rule_type, column_name, record_key,
             failed_value, error_reason, source_file_name, raw_record, load_ts)
        SELECT :v_run_id, :v_job_name, 'cdr', 'RAW.RAW_CDR', 'DATE_FORMAT', 'call_end_ts',
               cdr_id, call_end_ts, 'call_end_ts is not a parseable timestamp (expected YYYY-MM-DD HH24:MI:SS)',
               source_file_name, OBJECT_CONSTRUCT(*), _load_ts
        FROM RAW.RAW_CDR WHERE call_end_ts IS NOT NULL AND TRY_TO_TIMESTAMP_NTZ(call_end_ts) IS NULL;
    END IF;
    CALL ERROR_SCHEMA.SP_LOG_VALIDATION_RESULT(:v_run_id, :v_job_name, 'cdr', 'RAW.RAW_CDR',
        'DATE_FORMAT', 'call_end_ts', :v_total_rows, :v_failed);
    v_total_failed := v_total_failed + v_failed;

    -- ACCEPTED VALUES: call_type, roaming_flag, region
    SELECT COUNT(*) INTO :v_failed FROM RAW.RAW_CDR
    WHERE call_type IS NOT NULL AND call_type NOT IN ('VOICE','SMS','DATA');
    IF (v_failed > 0) THEN
        INSERT INTO ERROR_SCHEMA.VALIDATION_ERROR_LOG
            (run_id, job_name, feed_name, table_name, rule_type, column_name, record_key,
             failed_value, error_reason, source_file_name, raw_record, load_ts)
        SELECT :v_run_id, :v_job_name, 'cdr', 'RAW.RAW_CDR', 'ACCEPTED_VALUES', 'call_type',
               cdr_id, call_type, 'call_type not in (VOICE, SMS, DATA)',
               source_file_name, OBJECT_CONSTRUCT(*), _load_ts
        FROM RAW.RAW_CDR WHERE call_type IS NOT NULL AND call_type NOT IN ('VOICE','SMS','DATA');
    END IF;
    CALL ERROR_SCHEMA.SP_LOG_VALIDATION_RESULT(:v_run_id, :v_job_name, 'cdr', 'RAW.RAW_CDR',
        'ACCEPTED_VALUES', 'call_type', :v_total_rows, :v_failed);
    v_total_failed := v_total_failed + v_failed;

    SELECT COUNT(*) INTO :v_failed FROM RAW.RAW_CDR
    WHERE roaming_flag IS NOT NULL AND UPPER(roaming_flag) NOT IN ('Y','N');
    IF (v_failed > 0) THEN
        INSERT INTO ERROR_SCHEMA.VALIDATION_ERROR_LOG
            (run_id, job_name, feed_name, table_name, rule_type, column_name, record_key,
             failed_value, error_reason, source_file_name, raw_record, load_ts)
        SELECT :v_run_id, :v_job_name, 'cdr', 'RAW.RAW_CDR', 'ACCEPTED_VALUES', 'roaming_flag',
               cdr_id, roaming_flag, 'roaming_flag not in (Y, N)',
               source_file_name, OBJECT_CONSTRUCT(*), _load_ts
        FROM RAW.RAW_CDR WHERE roaming_flag IS NOT NULL AND UPPER(roaming_flag) NOT IN ('Y','N');
    END IF;
    CALL ERROR_SCHEMA.SP_LOG_VALIDATION_RESULT(:v_run_id, :v_job_name, 'cdr', 'RAW.RAW_CDR',
        'ACCEPTED_VALUES', 'roaming_flag', :v_total_rows, :v_failed);
    v_total_failed := v_total_failed + v_failed;

    SELECT COUNT(*) INTO :v_failed FROM RAW.RAW_CDR
    WHERE region IS NOT NULL AND region NOT IN ('NORTH','SOUTH','EAST','WEST');
    IF (v_failed > 0) THEN
        INSERT INTO ERROR_SCHEMA.VALIDATION_ERROR_LOG
            (run_id, job_name, feed_name, table_name, rule_type, column_name, record_key,
             failed_value, error_reason, source_file_name, raw_record, load_ts)
        SELECT :v_run_id, :v_job_name, 'cdr', 'RAW.RAW_CDR', 'ACCEPTED_VALUES', 'region',
               cdr_id, region, 'region not in (NORTH, SOUTH, EAST, WEST)',
               source_file_name, OBJECT_CONSTRUCT(*), _load_ts
        FROM RAW.RAW_CDR WHERE region IS NOT NULL AND region NOT IN ('NORTH','SOUTH','EAST','WEST');
    END IF;
    CALL ERROR_SCHEMA.SP_LOG_VALIDATION_RESULT(:v_run_id, :v_job_name, 'cdr', 'RAW.RAW_CDR',
        'ACCEPTED_VALUES', 'region', :v_total_rows, :v_failed);
    v_total_failed := v_total_failed + v_failed;

    CALL AUDIT_CTL.SP_AUDIT_END(:v_run_id, :v_total_rows, :v_total_rows, 0, 0, :v_total_failed,
        'RAW_CDR validation complete: ' || v_total_failed || ' rule violation(s) across ' || v_total_rows || ' row(s)');
    RETURN 'SUCCESS run_id=' || v_run_id || ' rows_checked=' || v_total_rows || ' violations=' || v_total_failed;
EXCEPTION
    WHEN OTHER THEN
        CALL AUDIT_CTL.SP_AUDIT_FAIL(:v_run_id, 'SQL_ERROR', :sqlcode, :sqlerrm,
            OBJECT_CONSTRUCT('procedure', 'SP_VALIDATE_RAW_CDR'));
        RAISE;
END;
$$;


/* ==========================================================================
   5. BILLING (billing_period is a plain YYYY-MM string, not a full date -
   checked with a regex rather than TRY_TO_DATE)
   ========================================================================== */
CREATE OR REPLACE PROCEDURE ERROR_SCHEMA.SP_VALIDATE_RAW_BILLING()
RETURNS STRING
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_run_id       NUMBER;
    v_job_name     STRING DEFAULT 'VALIDATE_RAW_BILLING';
    v_total_rows   NUMBER DEFAULT 0;
    v_total_failed NUMBER DEFAULT 0;
    v_failed       NUMBER DEFAULT 0;
    v_file         STRING;
    v_safe_file    STRING;
    v_stmt         STRING;
    v_src_count    NUMBER;
    v_tgt_count    NUMBER;
    file_cursor CURSOR FOR
        SELECT DISTINCT source_file_name AS fname FROM RAW.RAW_BILLING WHERE source_file_name IS NOT NULL;
BEGIN
    v_run_id := (CALL AUDIT_CTL.SP_AUDIT_START(:v_job_name, 'TASK'));
    SELECT COUNT(*) INTO :v_total_rows FROM RAW.RAW_BILLING;

    FOR rec IN file_cursor DO
        v_file := rec.fname;
        v_safe_file := REPLACE(v_file, '''', '''''');
        SELECT COUNT(*) INTO :v_tgt_count FROM RAW.RAW_BILLING WHERE source_file_name = :v_file;
        BEGIN
            v_stmt := 'SELECT COUNT(*) AS CNT FROM @RAW.STG_BILLING/' || v_safe_file ||
                      ' (FILE_FORMAT => ''RAW.FF_CSV_STANDARD'')';
            EXECUTE IMMEDIATE :v_stmt;
            SELECT CNT INTO :v_src_count FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
        EXCEPTION
            WHEN OTHER THEN v_src_count := NULL;
        END;
        INSERT INTO ERROR_SCHEMA.SRC_TARGET_COUNT_LOG
            (run_id, feed_name, table_name, source_file_name, source_row_count, target_row_count,
             row_count_variance, check_status)
        VALUES
            (:v_run_id, 'billing', 'RAW.RAW_BILLING', :v_file, :v_src_count, :v_tgt_count,
             IFF(:v_src_count IS NULL, NULL, :v_tgt_count - :v_src_count),
             CASE WHEN :v_src_count IS NULL THEN 'SKIPPED'
                  WHEN :v_src_count = :v_tgt_count THEN 'MATCH' ELSE 'MISMATCH' END);
    END FOR;

    -- NOT NULL: invoice_id
    SELECT COUNT(*) INTO :v_failed FROM RAW.RAW_BILLING WHERE invoice_id IS NULL;
    IF (v_failed > 0) THEN
        INSERT INTO ERROR_SCHEMA.VALIDATION_ERROR_LOG
            (run_id, job_name, feed_name, table_name, rule_type, column_name, record_key,
             failed_value, error_reason, source_file_name, raw_record, load_ts)
        SELECT :v_run_id, :v_job_name, 'billing', 'RAW.RAW_BILLING', 'NOT_NULL', 'invoice_id',
               invoice_id, invoice_id, 'invoice_id is NULL', source_file_name, OBJECT_CONSTRUCT(*), _load_ts
        FROM RAW.RAW_BILLING WHERE invoice_id IS NULL;
    END IF;
    CALL ERROR_SCHEMA.SP_LOG_VALIDATION_RESULT(:v_run_id, :v_job_name, 'billing', 'RAW.RAW_BILLING',
        'NOT_NULL', 'invoice_id', :v_total_rows, :v_failed);
    v_total_failed := v_total_failed + v_failed;

    -- DATE FORMAT: billing_period (YYYY-MM), invoice_date, due_date
    SELECT COUNT(*) INTO :v_failed FROM RAW.RAW_BILLING
    WHERE billing_period IS NOT NULL AND NOT REGEXP_LIKE(billing_period, '^[0-9]{4}-(0[1-9]|1[0-2])$');
    IF (v_failed > 0) THEN
        INSERT INTO ERROR_SCHEMA.VALIDATION_ERROR_LOG
            (run_id, job_name, feed_name, table_name, rule_type, column_name, record_key,
             failed_value, error_reason, source_file_name, raw_record, load_ts)
        SELECT :v_run_id, :v_job_name, 'billing', 'RAW.RAW_BILLING', 'DATE_FORMAT', 'billing_period',
               invoice_id, billing_period, 'billing_period does not match YYYY-MM',
               source_file_name, OBJECT_CONSTRUCT(*), _load_ts
        FROM RAW.RAW_BILLING
        WHERE billing_period IS NOT NULL AND NOT REGEXP_LIKE(billing_period, '^[0-9]{4}-(0[1-9]|1[0-2])$');
    END IF;
    CALL ERROR_SCHEMA.SP_LOG_VALIDATION_RESULT(:v_run_id, :v_job_name, 'billing', 'RAW.RAW_BILLING',
        'DATE_FORMAT', 'billing_period', :v_total_rows, :v_failed);
    v_total_failed := v_total_failed + v_failed;

    SELECT COUNT(*) INTO :v_failed FROM RAW.RAW_BILLING
    WHERE invoice_date IS NOT NULL AND TRY_TO_DATE(invoice_date) IS NULL;
    IF (v_failed > 0) THEN
        INSERT INTO ERROR_SCHEMA.VALIDATION_ERROR_LOG
            (run_id, job_name, feed_name, table_name, rule_type, column_name, record_key,
             failed_value, error_reason, source_file_name, raw_record, load_ts)
        SELECT :v_run_id, :v_job_name, 'billing', 'RAW.RAW_BILLING', 'DATE_FORMAT', 'invoice_date',
               invoice_id, invoice_date, 'invoice_date is not a parseable date (expected YYYY-MM-DD)',
               source_file_name, OBJECT_CONSTRUCT(*), _load_ts
        FROM RAW.RAW_BILLING WHERE invoice_date IS NOT NULL AND TRY_TO_DATE(invoice_date) IS NULL;
    END IF;
    CALL ERROR_SCHEMA.SP_LOG_VALIDATION_RESULT(:v_run_id, :v_job_name, 'billing', 'RAW.RAW_BILLING',
        'DATE_FORMAT', 'invoice_date', :v_total_rows, :v_failed);
    v_total_failed := v_total_failed + v_failed;

    SELECT COUNT(*) INTO :v_failed FROM RAW.RAW_BILLING
    WHERE due_date IS NOT NULL AND TRY_TO_DATE(due_date) IS NULL;
    IF (v_failed > 0) THEN
        INSERT INTO ERROR_SCHEMA.VALIDATION_ERROR_LOG
            (run_id, job_name, feed_name, table_name, rule_type, column_name, record_key,
             failed_value, error_reason, source_file_name, raw_record, load_ts)
        SELECT :v_run_id, :v_job_name, 'billing', 'RAW.RAW_BILLING', 'DATE_FORMAT', 'due_date',
               invoice_id, due_date, 'due_date is not a parseable date (expected YYYY-MM-DD)',
               source_file_name, OBJECT_CONSTRUCT(*), _load_ts
        FROM RAW.RAW_BILLING WHERE due_date IS NOT NULL AND TRY_TO_DATE(due_date) IS NULL;
    END IF;
    CALL ERROR_SCHEMA.SP_LOG_VALIDATION_RESULT(:v_run_id, :v_job_name, 'billing', 'RAW.RAW_BILLING',
        'DATE_FORMAT', 'due_date', :v_total_rows, :v_failed);
    v_total_failed := v_total_failed + v_failed;

    -- ACCEPTED VALUES: invoice_status
    SELECT COUNT(*) INTO :v_failed FROM RAW.RAW_BILLING
    WHERE invoice_status IS NOT NULL AND invoice_status NOT IN ('PAID','OPEN','OVERDUE');
    IF (v_failed > 0) THEN
        INSERT INTO ERROR_SCHEMA.VALIDATION_ERROR_LOG
            (run_id, job_name, feed_name, table_name, rule_type, column_name, record_key,
             failed_value, error_reason, source_file_name, raw_record, load_ts)
        SELECT :v_run_id, :v_job_name, 'billing', 'RAW.RAW_BILLING', 'ACCEPTED_VALUES', 'invoice_status',
               invoice_id, invoice_status, 'invoice_status not in (PAID, OPEN, OVERDUE)',
               source_file_name, OBJECT_CONSTRUCT(*), _load_ts
        FROM RAW.RAW_BILLING WHERE invoice_status IS NOT NULL AND invoice_status NOT IN ('PAID','OPEN','OVERDUE');
    END IF;
    CALL ERROR_SCHEMA.SP_LOG_VALIDATION_RESULT(:v_run_id, :v_job_name, 'billing', 'RAW.RAW_BILLING',
        'ACCEPTED_VALUES', 'invoice_status', :v_total_rows, :v_failed);
    v_total_failed := v_total_failed + v_failed;

    CALL AUDIT_CTL.SP_AUDIT_END(:v_run_id, :v_total_rows, :v_total_rows, 0, 0, :v_total_failed,
        'RAW_BILLING validation complete: ' || v_total_failed || ' rule violation(s) across ' || v_total_rows || ' row(s)');
    RETURN 'SUCCESS run_id=' || v_run_id || ' rows_checked=' || v_total_rows || ' violations=' || v_total_failed;
EXCEPTION
    WHEN OTHER THEN
        CALL AUDIT_CTL.SP_AUDIT_FAIL(:v_run_id, 'SQL_ERROR', :sqlcode, :sqlerrm,
            OBJECT_CONSTRUCT('procedure', 'SP_VALIDATE_RAW_BILLING'));
        RAISE;
END;
$$;


/* ==========================================================================
   6. PAYMENTS
   ========================================================================== */
CREATE OR REPLACE PROCEDURE ERROR_SCHEMA.SP_VALIDATE_RAW_PAYMENTS()
RETURNS STRING
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_run_id       NUMBER;
    v_job_name     STRING DEFAULT 'VALIDATE_RAW_PAYMENTS';
    v_total_rows   NUMBER DEFAULT 0;
    v_total_failed NUMBER DEFAULT 0;
    v_failed       NUMBER DEFAULT 0;
    v_file         STRING;
    v_safe_file    STRING;
    v_stmt         STRING;
    v_src_count    NUMBER;
    v_tgt_count    NUMBER;
    file_cursor CURSOR FOR
        SELECT DISTINCT source_file_name AS fname FROM RAW.RAW_PAYMENTS WHERE source_file_name IS NOT NULL;
BEGIN
    v_run_id := (CALL AUDIT_CTL.SP_AUDIT_START(:v_job_name, 'TASK'));
    SELECT COUNT(*) INTO :v_total_rows FROM RAW.RAW_PAYMENTS;

    FOR rec IN file_cursor DO
        v_file := rec.fname;
        v_safe_file := REPLACE(v_file, '''', '''''');
        SELECT COUNT(*) INTO :v_tgt_count FROM RAW.RAW_PAYMENTS WHERE source_file_name = :v_file;
        BEGIN
            v_stmt := 'SELECT COUNT(*) AS CNT FROM @RAW.STG_PAYMENTS/' || v_safe_file ||
                      ' (FILE_FORMAT => ''RAW.FF_CSV_STANDARD'')';
            EXECUTE IMMEDIATE :v_stmt;
            SELECT CNT INTO :v_src_count FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
        EXCEPTION
            WHEN OTHER THEN v_src_count := NULL;
        END;
        INSERT INTO ERROR_SCHEMA.SRC_TARGET_COUNT_LOG
            (run_id, feed_name, table_name, source_file_name, source_row_count, target_row_count,
             row_count_variance, check_status)
        VALUES
            (:v_run_id, 'payments', 'RAW.RAW_PAYMENTS', :v_file, :v_src_count, :v_tgt_count,
             IFF(:v_src_count IS NULL, NULL, :v_tgt_count - :v_src_count),
             CASE WHEN :v_src_count IS NULL THEN 'SKIPPED'
                  WHEN :v_src_count = :v_tgt_count THEN 'MATCH' ELSE 'MISMATCH' END);
    END FOR;

    -- NOT NULL: payment_id
    SELECT COUNT(*) INTO :v_failed FROM RAW.RAW_PAYMENTS WHERE payment_id IS NULL;
    IF (v_failed > 0) THEN
        INSERT INTO ERROR_SCHEMA.VALIDATION_ERROR_LOG
            (run_id, job_name, feed_name, table_name, rule_type, column_name, record_key,
             failed_value, error_reason, source_file_name, raw_record, load_ts)
        SELECT :v_run_id, :v_job_name, 'payments', 'RAW.RAW_PAYMENTS', 'NOT_NULL', 'payment_id',
               payment_id, payment_id, 'payment_id is NULL', source_file_name, OBJECT_CONSTRUCT(*), _load_ts
        FROM RAW.RAW_PAYMENTS WHERE payment_id IS NULL;
    END IF;
    CALL ERROR_SCHEMA.SP_LOG_VALIDATION_RESULT(:v_run_id, :v_job_name, 'payments', 'RAW.RAW_PAYMENTS',
        'NOT_NULL', 'payment_id', :v_total_rows, :v_failed);
    v_total_failed := v_total_failed + v_failed;

    -- DATE FORMAT: payment_date
    SELECT COUNT(*) INTO :v_failed FROM RAW.RAW_PAYMENTS
    WHERE payment_date IS NOT NULL AND TRY_TO_DATE(payment_date) IS NULL;
    IF (v_failed > 0) THEN
        INSERT INTO ERROR_SCHEMA.VALIDATION_ERROR_LOG
            (run_id, job_name, feed_name, table_name, rule_type, column_name, record_key,
             failed_value, error_reason, source_file_name, raw_record, load_ts)
        SELECT :v_run_id, :v_job_name, 'payments', 'RAW.RAW_PAYMENTS', 'DATE_FORMAT', 'payment_date',
               payment_id, payment_date, 'payment_date is not a parseable date (expected YYYY-MM-DD)',
               source_file_name, OBJECT_CONSTRUCT(*), _load_ts
        FROM RAW.RAW_PAYMENTS WHERE payment_date IS NOT NULL AND TRY_TO_DATE(payment_date) IS NULL;
    END IF;
    CALL ERROR_SCHEMA.SP_LOG_VALIDATION_RESULT(:v_run_id, :v_job_name, 'payments', 'RAW.RAW_PAYMENTS',
        'DATE_FORMAT', 'payment_date', :v_total_rows, :v_failed);
    v_total_failed := v_total_failed + v_failed;

    -- ACCEPTED VALUES: payment_method, payment_status
    SELECT COUNT(*) INTO :v_failed FROM RAW.RAW_PAYMENTS
    WHERE payment_method IS NOT NULL AND payment_method NOT IN ('CARD','BANK_TRANSFER','WALLET','CASH');
    IF (v_failed > 0) THEN
        INSERT INTO ERROR_SCHEMA.VALIDATION_ERROR_LOG
            (run_id, job_name, feed_name, table_name, rule_type, column_name, record_key,
             failed_value, error_reason, source_file_name, raw_record, load_ts)
        SELECT :v_run_id, :v_job_name, 'payments', 'RAW.RAW_PAYMENTS', 'ACCEPTED_VALUES', 'payment_method',
               payment_id, payment_method, 'payment_method not in (CARD, BANK_TRANSFER, WALLET, CASH)',
               source_file_name, OBJECT_CONSTRUCT(*), _load_ts
        FROM RAW.RAW_PAYMENTS
        WHERE payment_method IS NOT NULL AND payment_method NOT IN ('CARD','BANK_TRANSFER','WALLET','CASH');
    END IF;
    CALL ERROR_SCHEMA.SP_LOG_VALIDATION_RESULT(:v_run_id, :v_job_name, 'payments', 'RAW.RAW_PAYMENTS',
        'ACCEPTED_VALUES', 'payment_method', :v_total_rows, :v_failed);
    v_total_failed := v_total_failed + v_failed;

    SELECT COUNT(*) INTO :v_failed FROM RAW.RAW_PAYMENTS
    WHERE payment_status IS NOT NULL AND payment_status NOT IN ('SUCCESS','FAILED','PENDING','REFUNDED');
    IF (v_failed > 0) THEN
        INSERT INTO ERROR_SCHEMA.VALIDATION_ERROR_LOG
            (run_id, job_name, feed_name, table_name, rule_type, column_name, record_key,
             failed_value, error_reason, source_file_name, raw_record, load_ts)
        SELECT :v_run_id, :v_job_name, 'payments', 'RAW.RAW_PAYMENTS', 'ACCEPTED_VALUES', 'payment_status',
               payment_id, payment_status, 'payment_status not in (SUCCESS, FAILED, PENDING, REFUNDED)',
               source_file_name, OBJECT_CONSTRUCT(*), _load_ts
        FROM RAW.RAW_PAYMENTS
        WHERE payment_status IS NOT NULL AND payment_status NOT IN ('SUCCESS','FAILED','PENDING','REFUNDED');
    END IF;
    CALL ERROR_SCHEMA.SP_LOG_VALIDATION_RESULT(:v_run_id, :v_job_name, 'payments', 'RAW.RAW_PAYMENTS',
        'ACCEPTED_VALUES', 'payment_status', :v_total_rows, :v_failed);
    v_total_failed := v_total_failed + v_failed;

    CALL AUDIT_CTL.SP_AUDIT_END(:v_run_id, :v_total_rows, :v_total_rows, 0, 0, :v_total_failed,
        'RAW_PAYMENTS validation complete: ' || v_total_failed || ' rule violation(s) across ' || v_total_rows || ' row(s)');
    RETURN 'SUCCESS run_id=' || v_run_id || ' rows_checked=' || v_total_rows || ' violations=' || v_total_failed;
EXCEPTION
    WHEN OTHER THEN
        CALL AUDIT_CTL.SP_AUDIT_FAIL(:v_run_id, 'SQL_ERROR', :sqlcode, :sqlerrm,
            OBJECT_CONSTRUCT('procedure', 'SP_VALIDATE_RAW_PAYMENTS'));
        RAISE;
END;
$$;


/* ==========================================================================
   7. TOWERS (no date columns - count reconciliation, not-null, accepted values only)
   ========================================================================== */
CREATE OR REPLACE PROCEDURE ERROR_SCHEMA.SP_VALIDATE_RAW_TOWERS()
RETURNS STRING
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_run_id       NUMBER;
    v_job_name     STRING DEFAULT 'VALIDATE_RAW_TOWERS';
    v_total_rows   NUMBER DEFAULT 0;
    v_total_failed NUMBER DEFAULT 0;
    v_failed       NUMBER DEFAULT 0;
    v_file         STRING;
    v_safe_file    STRING;
    v_stmt         STRING;
    v_src_count    NUMBER;
    v_tgt_count    NUMBER;
    file_cursor CURSOR FOR
        SELECT DISTINCT source_file_name AS fname FROM RAW.RAW_TOWERS WHERE source_file_name IS NOT NULL;
BEGIN
    v_run_id := (CALL AUDIT_CTL.SP_AUDIT_START(:v_job_name, 'TASK'));
    SELECT COUNT(*) INTO :v_total_rows FROM RAW.RAW_TOWERS;

    FOR rec IN file_cursor DO
        v_file := rec.fname;
        v_safe_file := REPLACE(v_file, '''', '''''');
        SELECT COUNT(*) INTO :v_tgt_count FROM RAW.RAW_TOWERS WHERE source_file_name = :v_file;
        BEGIN
            v_stmt := 'SELECT COUNT(*) AS CNT FROM @RAW.STG_TOWERS/' || v_safe_file ||
                      ' (FILE_FORMAT => ''RAW.FF_CSV_STANDARD'')';
            EXECUTE IMMEDIATE :v_stmt;
            SELECT CNT INTO :v_src_count FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
        EXCEPTION
            WHEN OTHER THEN v_src_count := NULL;
        END;
        INSERT INTO ERROR_SCHEMA.SRC_TARGET_COUNT_LOG
            (run_id, feed_name, table_name, source_file_name, source_row_count, target_row_count,
             row_count_variance, check_status)
        VALUES
            (:v_run_id, 'towers', 'RAW.RAW_TOWERS', :v_file, :v_src_count, :v_tgt_count,
             IFF(:v_src_count IS NULL, NULL, :v_tgt_count - :v_src_count),
             CASE WHEN :v_src_count IS NULL THEN 'SKIPPED'
                  WHEN :v_src_count = :v_tgt_count THEN 'MATCH' ELSE 'MISMATCH' END);
    END FOR;

    -- NOT NULL: tower_id
    SELECT COUNT(*) INTO :v_failed FROM RAW.RAW_TOWERS WHERE tower_id IS NULL;
    IF (v_failed > 0) THEN
        INSERT INTO ERROR_SCHEMA.VALIDATION_ERROR_LOG
            (run_id, job_name, feed_name, table_name, rule_type, column_name, record_key,
             failed_value, error_reason, source_file_name, raw_record, load_ts)
        SELECT :v_run_id, :v_job_name, 'towers', 'RAW.RAW_TOWERS', 'NOT_NULL', 'tower_id',
               tower_id, tower_id, 'tower_id is NULL', source_file_name, OBJECT_CONSTRUCT(*), _load_ts
        FROM RAW.RAW_TOWERS WHERE tower_id IS NULL;
    END IF;
    CALL ERROR_SCHEMA.SP_LOG_VALIDATION_RESULT(:v_run_id, :v_job_name, 'towers', 'RAW.RAW_TOWERS',
        'NOT_NULL', 'tower_id', :v_total_rows, :v_failed);
    v_total_failed := v_total_failed + v_failed;

    -- ACCEPTED VALUES: region, tower_status
    SELECT COUNT(*) INTO :v_failed FROM RAW.RAW_TOWERS
    WHERE region IS NOT NULL AND region NOT IN ('NORTH','SOUTH','EAST','WEST');
    IF (v_failed > 0) THEN
        INSERT INTO ERROR_SCHEMA.VALIDATION_ERROR_LOG
            (run_id, job_name, feed_name, table_name, rule_type, column_name, record_key,
             failed_value, error_reason, source_file_name, raw_record, load_ts)
        SELECT :v_run_id, :v_job_name, 'towers', 'RAW.RAW_TOWERS', 'ACCEPTED_VALUES', 'region',
               tower_id, region, 'region not in (NORTH, SOUTH, EAST, WEST)',
               source_file_name, OBJECT_CONSTRUCT(*), _load_ts
        FROM RAW.RAW_TOWERS WHERE region IS NOT NULL AND region NOT IN ('NORTH','SOUTH','EAST','WEST');
    END IF;
    CALL ERROR_SCHEMA.SP_LOG_VALIDATION_RESULT(:v_run_id, :v_job_name, 'towers', 'RAW.RAW_TOWERS',
        'ACCEPTED_VALUES', 'region', :v_total_rows, :v_failed);
    v_total_failed := v_total_failed + v_failed;

    SELECT COUNT(*) INTO :v_failed FROM RAW.RAW_TOWERS
    WHERE tower_status IS NOT NULL AND tower_status NOT IN ('ACTIVE','MAINTENANCE','INACTIVE');
    IF (v_failed > 0) THEN
        INSERT INTO ERROR_SCHEMA.VALIDATION_ERROR_LOG
            (run_id, job_name, feed_name, table_name, rule_type, column_name, record_key,
             failed_value, error_reason, source_file_name, raw_record, load_ts)
        SELECT :v_run_id, :v_job_name, 'towers', 'RAW.RAW_TOWERS', 'ACCEPTED_VALUES', 'tower_status',
               tower_id, tower_status, 'tower_status not in (ACTIVE, MAINTENANCE, INACTIVE)',
               source_file_name, OBJECT_CONSTRUCT(*), _load_ts
        FROM RAW.RAW_TOWERS WHERE tower_status IS NOT NULL AND tower_status NOT IN ('ACTIVE','MAINTENANCE','INACTIVE');
    END IF;
    CALL ERROR_SCHEMA.SP_LOG_VALIDATION_RESULT(:v_run_id, :v_job_name, 'towers', 'RAW.RAW_TOWERS',
        'ACCEPTED_VALUES', 'tower_status', :v_total_rows, :v_failed);
    v_total_failed := v_total_failed + v_failed;

    CALL AUDIT_CTL.SP_AUDIT_END(:v_run_id, :v_total_rows, :v_total_rows, 0, 0, :v_total_failed,
        'RAW_TOWERS validation complete: ' || v_total_failed || ' rule violation(s) across ' || v_total_rows || ' row(s)');
    RETURN 'SUCCESS run_id=' || v_run_id || ' rows_checked=' || v_total_rows || ' violations=' || v_total_failed;
EXCEPTION
    WHEN OTHER THEN
        CALL AUDIT_CTL.SP_AUDIT_FAIL(:v_run_id, 'SQL_ERROR', :sqlcode, :sqlerrm,
            OBJECT_CONSTRUCT('procedure', 'SP_VALIDATE_RAW_TOWERS'));
        RAISE;
END;
$$;


/* ==========================================================================
   8. SUPPORT_TICKETS
   ========================================================================== */
CREATE OR REPLACE PROCEDURE ERROR_SCHEMA.SP_VALIDATE_RAW_SUPPORT_TICKETS()
RETURNS STRING
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_run_id       NUMBER;
    v_job_name     STRING DEFAULT 'VALIDATE_RAW_SUPPORT_TICKETS';
    v_total_rows   NUMBER DEFAULT 0;
    v_total_failed NUMBER DEFAULT 0;
    v_failed       NUMBER DEFAULT 0;
    v_file         STRING;
    v_safe_file    STRING;
    v_stmt         STRING;
    v_src_count    NUMBER;
    v_tgt_count    NUMBER;
    file_cursor CURSOR FOR
        SELECT DISTINCT source_file_name AS fname FROM RAW.RAW_SUPPORT_TICKETS WHERE source_file_name IS NOT NULL;
BEGIN
    v_run_id := (CALL AUDIT_CTL.SP_AUDIT_START(:v_job_name, 'TASK'));
    SELECT COUNT(*) INTO :v_total_rows FROM RAW.RAW_SUPPORT_TICKETS;

    FOR rec IN file_cursor DO
        v_file := rec.fname;
        v_safe_file := REPLACE(v_file, '''', '''''');
        SELECT COUNT(*) INTO :v_tgt_count FROM RAW.RAW_SUPPORT_TICKETS WHERE source_file_name = :v_file;
        BEGIN
            v_stmt := 'SELECT COUNT(*) AS CNT FROM @RAW.STG_SUPPORT_TICKETS/' || v_safe_file ||
                      ' (FILE_FORMAT => ''RAW.FF_CSV_STANDARD'')';
            EXECUTE IMMEDIATE :v_stmt;
            SELECT CNT INTO :v_src_count FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
        EXCEPTION
            WHEN OTHER THEN v_src_count := NULL;
        END;
        INSERT INTO ERROR_SCHEMA.SRC_TARGET_COUNT_LOG
            (run_id, feed_name, table_name, source_file_name, source_row_count, target_row_count,
             row_count_variance, check_status)
        VALUES
            (:v_run_id, 'support_tickets', 'RAW.RAW_SUPPORT_TICKETS', :v_file, :v_src_count, :v_tgt_count,
             IFF(:v_src_count IS NULL, NULL, :v_tgt_count - :v_src_count),
             CASE WHEN :v_src_count IS NULL THEN 'SKIPPED'
                  WHEN :v_src_count = :v_tgt_count THEN 'MATCH' ELSE 'MISMATCH' END);
    END FOR;

    -- NOT NULL: ticket_id
    SELECT COUNT(*) INTO :v_failed FROM RAW.RAW_SUPPORT_TICKETS WHERE ticket_id IS NULL;
    IF (v_failed > 0) THEN
        INSERT INTO ERROR_SCHEMA.VALIDATION_ERROR_LOG
            (run_id, job_name, feed_name, table_name, rule_type, column_name, record_key,
             failed_value, error_reason, source_file_name, raw_record, load_ts)
        SELECT :v_run_id, :v_job_name, 'support_tickets', 'RAW.RAW_SUPPORT_TICKETS', 'NOT_NULL', 'ticket_id',
               ticket_id, ticket_id, 'ticket_id is NULL', source_file_name, OBJECT_CONSTRUCT(*), _load_ts
        FROM RAW.RAW_SUPPORT_TICKETS WHERE ticket_id IS NULL;
    END IF;
    CALL ERROR_SCHEMA.SP_LOG_VALIDATION_RESULT(:v_run_id, :v_job_name, 'support_tickets', 'RAW.RAW_SUPPORT_TICKETS',
        'NOT_NULL', 'ticket_id', :v_total_rows, :v_failed);
    v_total_failed := v_total_failed + v_failed;

    -- DATE FORMAT: opened_at, closed_at (closed_at may legitimately be null for open tickets)
    SELECT COUNT(*) INTO :v_failed FROM RAW.RAW_SUPPORT_TICKETS
    WHERE opened_at IS NOT NULL AND TRY_TO_TIMESTAMP_NTZ(opened_at) IS NULL;
    IF (v_failed > 0) THEN
        INSERT INTO ERROR_SCHEMA.VALIDATION_ERROR_LOG
            (run_id, job_name, feed_name, table_name, rule_type, column_name, record_key,
             failed_value, error_reason, source_file_name, raw_record, load_ts)
        SELECT :v_run_id, :v_job_name, 'support_tickets', 'RAW.RAW_SUPPORT_TICKETS', 'DATE_FORMAT', 'opened_at',
               ticket_id, opened_at, 'opened_at is not a parseable timestamp',
               source_file_name, OBJECT_CONSTRUCT(*), _load_ts
        FROM RAW.RAW_SUPPORT_TICKETS WHERE opened_at IS NOT NULL AND TRY_TO_TIMESTAMP_NTZ(opened_at) IS NULL;
    END IF;
    CALL ERROR_SCHEMA.SP_LOG_VALIDATION_RESULT(:v_run_id, :v_job_name, 'support_tickets', 'RAW.RAW_SUPPORT_TICKETS',
        'DATE_FORMAT', 'opened_at', :v_total_rows, :v_failed);
    v_total_failed := v_total_failed + v_failed;

    SELECT COUNT(*) INTO :v_failed FROM RAW.RAW_SUPPORT_TICKETS
    WHERE closed_at IS NOT NULL AND TRY_TO_TIMESTAMP_NTZ(closed_at) IS NULL;
    IF (v_failed > 0) THEN
        INSERT INTO ERROR_SCHEMA.VALIDATION_ERROR_LOG
            (run_id, job_name, feed_name, table_name, rule_type, column_name, record_key,
             failed_value, error_reason, source_file_name, raw_record, load_ts)
        SELECT :v_run_id, :v_job_name, 'support_tickets', 'RAW.RAW_SUPPORT_TICKETS', 'DATE_FORMAT', 'closed_at',
               ticket_id, closed_at, 'closed_at is not a parseable timestamp',
               source_file_name, OBJECT_CONSTRUCT(*), _load_ts
        FROM RAW.RAW_SUPPORT_TICKETS WHERE closed_at IS NOT NULL AND TRY_TO_TIMESTAMP_NTZ(closed_at) IS NULL;
    END IF;
    CALL ERROR_SCHEMA.SP_LOG_VALIDATION_RESULT(:v_run_id, :v_job_name, 'support_tickets', 'RAW.RAW_SUPPORT_TICKETS',
        'DATE_FORMAT', 'closed_at', :v_total_rows, :v_failed);
    v_total_failed := v_total_failed + v_failed;

    -- ACCEPTED VALUES: category, priority, ticket_status, channel
    SELECT COUNT(*) INTO :v_failed FROM RAW.RAW_SUPPORT_TICKETS
    WHERE category IS NOT NULL AND category NOT IN ('BILLING','NETWORK','DEVICE','PLAN_CHANGE','OTHER');
    IF (v_failed > 0) THEN
        INSERT INTO ERROR_SCHEMA.VALIDATION_ERROR_LOG
            (run_id, job_name, feed_name, table_name, rule_type, column_name, record_key,
             failed_value, error_reason, source_file_name, raw_record, load_ts)
        SELECT :v_run_id, :v_job_name, 'support_tickets', 'RAW.RAW_SUPPORT_TICKETS', 'ACCEPTED_VALUES', 'category',
               ticket_id, category, 'category not in (BILLING, NETWORK, DEVICE, PLAN_CHANGE, OTHER)',
               source_file_name, OBJECT_CONSTRUCT(*), _load_ts
        FROM RAW.RAW_SUPPORT_TICKETS
        WHERE category IS NOT NULL AND category NOT IN ('BILLING','NETWORK','DEVICE','PLAN_CHANGE','OTHER');
    END IF;
    CALL ERROR_SCHEMA.SP_LOG_VALIDATION_RESULT(:v_run_id, :v_job_name, 'support_tickets', 'RAW.RAW_SUPPORT_TICKETS',
        'ACCEPTED_VALUES', 'category', :v_total_rows, :v_failed);
    v_total_failed := v_total_failed + v_failed;

    SELECT COUNT(*) INTO :v_failed FROM RAW.RAW_SUPPORT_TICKETS
    WHERE priority IS NOT NULL AND priority NOT IN ('LOW','MEDIUM','HIGH','URGENT');
    IF (v_failed > 0) THEN
        INSERT INTO ERROR_SCHEMA.VALIDATION_ERROR_LOG
            (run_id, job_name, feed_name, table_name, rule_type, column_name, record_key,
             failed_value, error_reason, source_file_name, raw_record, load_ts)
        SELECT :v_run_id, :v_job_name, 'support_tickets', 'RAW.RAW_SUPPORT_TICKETS', 'ACCEPTED_VALUES', 'priority',
               ticket_id, priority, 'priority not in (LOW, MEDIUM, HIGH, URGENT)',
               source_file_name, OBJECT_CONSTRUCT(*), _load_ts
        FROM RAW.RAW_SUPPORT_TICKETS
        WHERE priority IS NOT NULL AND priority NOT IN ('LOW','MEDIUM','HIGH','URGENT');
    END IF;
    CALL ERROR_SCHEMA.SP_LOG_VALIDATION_RESULT(:v_run_id, :v_job_name, 'support_tickets', 'RAW.RAW_SUPPORT_TICKETS',
        'ACCEPTED_VALUES', 'priority', :v_total_rows, :v_failed);
    v_total_failed := v_total_failed + v_failed;

    SELECT COUNT(*) INTO :v_failed FROM RAW.RAW_SUPPORT_TICKETS
    WHERE ticket_status IS NOT NULL AND ticket_status NOT IN ('OPEN','CLOSED','IN_PROGRESS','ESCALATED');
    IF (v_failed > 0) THEN
        INSERT INTO ERROR_SCHEMA.VALIDATION_ERROR_LOG
            (run_id, job_name, feed_name, table_name, rule_type, column_name, record_key,
             failed_value, error_reason, source_file_name, raw_record, load_ts)
        SELECT :v_run_id, :v_job_name, 'support_tickets', 'RAW.RAW_SUPPORT_TICKETS', 'ACCEPTED_VALUES', 'ticket_status',
               ticket_id, ticket_status, 'ticket_status not in (OPEN, CLOSED, IN_PROGRESS, ESCALATED)',
               source_file_name, OBJECT_CONSTRUCT(*), _load_ts
        FROM RAW.RAW_SUPPORT_TICKETS
        WHERE ticket_status IS NOT NULL AND ticket_status NOT IN ('OPEN','CLOSED','IN_PROGRESS','ESCALATED');
    END IF;
    CALL ERROR_SCHEMA.SP_LOG_VALIDATION_RESULT(:v_run_id, :v_job_name, 'support_tickets', 'RAW.RAW_SUPPORT_TICKETS',
        'ACCEPTED_VALUES', 'ticket_status', :v_total_rows, :v_failed);
    v_total_failed := v_total_failed + v_failed;

    SELECT COUNT(*) INTO :v_failed FROM RAW.RAW_SUPPORT_TICKETS
    WHERE channel IS NOT NULL AND channel NOT IN ('CALL','CHAT','EMAIL','APP');
    IF (v_failed > 0) THEN
        INSERT INTO ERROR_SCHEMA.VALIDATION_ERROR_LOG
            (run_id, job_name, feed_name, table_name, rule_type, column_name, record_key,
             failed_value, error_reason, source_file_name, raw_record, load_ts)
        SELECT :v_run_id, :v_job_name, 'support_tickets', 'RAW.RAW_SUPPORT_TICKETS', 'ACCEPTED_VALUES', 'channel',
               ticket_id, channel, 'channel not in (CALL, CHAT, EMAIL, APP)',
               source_file_name, OBJECT_CONSTRUCT(*), _load_ts
        FROM RAW.RAW_SUPPORT_TICKETS
        WHERE channel IS NOT NULL AND channel NOT IN ('CALL','CHAT','EMAIL','APP');
    END IF;
    CALL ERROR_SCHEMA.SP_LOG_VALIDATION_RESULT(:v_run_id, :v_job_name, 'support_tickets', 'RAW.RAW_SUPPORT_TICKETS',
        'ACCEPTED_VALUES', 'channel', :v_total_rows, :v_failed);
    v_total_failed := v_total_failed + v_failed;

    CALL AUDIT_CTL.SP_AUDIT_END(:v_run_id, :v_total_rows, :v_total_rows, 0, 0, :v_total_failed,
        'RAW_SUPPORT_TICKETS validation complete: ' || v_total_failed || ' rule violation(s) across ' || v_total_rows || ' row(s)');
    RETURN 'SUCCESS run_id=' || v_run_id || ' rows_checked=' || v_total_rows || ' violations=' || v_total_failed;
EXCEPTION
    WHEN OTHER THEN
        CALL AUDIT_CTL.SP_AUDIT_FAIL(:v_run_id, 'SQL_ERROR', :sqlcode, :sqlerrm,
            OBJECT_CONSTRUCT('procedure', 'SP_VALIDATE_RAW_SUPPORT_TICKETS'));
        RAISE;
END;
$$;
