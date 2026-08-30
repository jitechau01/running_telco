
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

