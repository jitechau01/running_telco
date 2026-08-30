
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

