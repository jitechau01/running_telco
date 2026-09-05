
USE DATABASE RUNNING_TELCO;
USE SCHEMA RAW;

CREATE TABLE IF NOT EXISTS RAW.RAW_CUSTOMERS (
    customer_id        VARCHAR(20),
    first_name         VARCHAR(100),
    last_name          VARCHAR(100),
    date_of_birth      VARCHAR(20),
    national_id        VARCHAR(30),
    email               VARCHAR(200),
    phone_number        VARCHAR(30),
    address_line1       VARCHAR(200),
    city                VARCHAR(100),
    region              VARCHAR(50),
    postal_code         VARCHAR(20),
    plan_id             VARCHAR(20),
    activation_date     VARCHAR(20),
    account_status      VARCHAR(20),
    customer_segment    VARCHAR(30),
    credit_score        VARCHAR(10),
    source_file_name    VARCHAR(500),
    _load_ts            TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS RAW.RAW_PLANS (
    plan_id             VARCHAR(20),
    plan_name           VARCHAR(100),
    plan_type           VARCHAR(20),
    monthly_fee         VARCHAR(20),
    data_limit_gb       VARCHAR(20),
    voice_minutes       VARCHAR(20),
    sms_count           VARCHAR(20),
    currency            VARCHAR(10),
    effective_date      VARCHAR(20),
    source_file_name    VARCHAR(500),
    _load_ts            TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS RAW.RAW_DEVICES (
    device_id           VARCHAR(20),
    imei                VARCHAR(30),
    customer_id         VARCHAR(20),
    device_model        VARCHAR(100),
    device_os           VARCHAR(50),
    activation_date     VARCHAR(20),
    device_status       VARCHAR(20),
    source_file_name    VARCHAR(500),
    _load_ts            TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS RAW.RAW_CDR (
    cdr_id               VARCHAR(40),
    customer_id          VARCHAR(20),
    call_type            VARCHAR(10),
    origin_number        VARCHAR(30),
    destination_number   VARCHAR(30),
    cell_tower_id        VARCHAR(20),
    call_start_ts        VARCHAR(30),
    call_end_ts          VARCHAR(30),
    duration_seconds     VARCHAR(20),
    data_volume_mb       VARCHAR(20),
    roaming_flag         VARCHAR(5),
    region               VARCHAR(50),
    source_file_name     VARCHAR(500),
    _load_ts             TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS RAW.RAW_BILLING (
    invoice_id          VARCHAR(20),
    customer_id         VARCHAR(20),
    billing_period      VARCHAR(10),
    plan_id             VARCHAR(20),
    usage_charges       VARCHAR(20),
    tax_amount          VARCHAR(20),
    total_amount        VARCHAR(20),
    invoice_date        VARCHAR(20),
    due_date            VARCHAR(20),
    invoice_status      VARCHAR(20),
    source_file_name    VARCHAR(500),
    _load_ts            TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS RAW.RAW_PAYMENTS (
    payment_id          VARCHAR(20),
    invoice_id          VARCHAR(20),
    customer_id         VARCHAR(20),
    payment_date        VARCHAR(20),
    amount              VARCHAR(20),
    payment_method      VARCHAR(30),
    card_last4          VARCHAR(10),
    payment_status      VARCHAR(20),
    source_file_name    VARCHAR(500),
    _load_ts            TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS RAW.RAW_TOWERS (
    tower_id            VARCHAR(20),
    region              VARCHAR(50),
    latitude            VARCHAR(20),
    longitude           VARCHAR(20),
    capacity_mbps       VARCHAR(20),
    tower_status        VARCHAR(20),
    source_file_name    VARCHAR(500),
    _load_ts            TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS RAW.RAW_SUPPORT_TICKETS (
    ticket_id           VARCHAR(20),
    customer_id         VARCHAR(20),
    opened_at           VARCHAR(30),
    closed_at           VARCHAR(30),
    category            VARCHAR(50),
    priority             VARCHAR(10),
    ticket_status         VARCHAR(20),
    channel               VARCHAR(20),
    source_file_name    VARCHAR(500),
    _load_ts            TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

