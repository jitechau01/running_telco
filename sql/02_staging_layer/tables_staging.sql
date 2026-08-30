
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

