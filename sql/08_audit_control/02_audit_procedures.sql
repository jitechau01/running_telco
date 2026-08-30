
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

