
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

