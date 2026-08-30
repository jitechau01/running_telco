
USE DATABASE RUNNING_TELCO;
USE SCHEMA SHARE_OUT;
USE ROLE R_TELECOM_ADMIN;

CREATE OR REPLACE SECURE VIEW SHARE_OUT.VW_SHARE_REGIONAL_USAGE_DAILY AS
SELECT
    usage_date,
    region,
    call_type,
    COUNT(*)                          AS session_count,
    SUM(duration_seconds)             AS total_duration_seconds,
    SUM(data_volume_mb)               AS total_data_mb,
    COUNT(DISTINCT customer_id)       AS distinct_customers
FROM CURATED.FACT_CDR_USAGE
GROUP BY usage_date, region, call_type;

CREATE OR REPLACE SECURE VIEW SHARE_OUT.VW_SHARE_REGIONAL_REVENUE_MONTHLY AS
SELECT
    b.billing_period,
    c.region,
    c.customer_segment,
    COUNT(DISTINCT b.customer_id)     AS billed_customers,
    SUM(b.total_amount)               AS total_billed,
    SUM(p.paid_amount)                AS total_collected
FROM CURATED.FACT_BILLING b
JOIN CURATED.VW_CUSTOMER_CURRENT c ON c.customer_id = b.customer_id
LEFT JOIN (
    SELECT invoice_id, SUM(amount) AS paid_amount
    FROM CURATED.FACT_PAYMENTS
    WHERE payment_status = 'SUCCESS'
    GROUP BY invoice_id
) p ON p.invoice_id = b.invoice_id
GROUP BY b.billing_period, c.region, c.customer_segment;

CREATE OR REPLACE SECURE VIEW SHARE_OUT.VW_SHARE_TOWER_STATUS AS
SELECT tower_id, region, capacity_mbps, tower_status
FROM CURATED.DIM_TOWER;

GRANT SELECT ON SHARE_OUT.VW_SHARE_REGIONAL_USAGE_DAILY     TO ROLE R_DATA_ENGINEER;
GRANT SELECT ON SHARE_OUT.VW_SHARE_REGIONAL_REVENUE_MONTHLY TO ROLE R_DATA_ENGINEER;
GRANT SELECT ON SHARE_OUT.VW_SHARE_TOWER_STATUS              TO ROLE R_DATA_ENGINEER;

/* ==========================================================================
   OUTBOUND SHARE - to a named consumer account (roaming partner / regulator)
   Only the SHARE_OUT schema and its secure views are exposed - nothing else
   in RUNNING_TELCO is reachable through the share. Requires R_TELECOM_ADMIN
   to hold CREATE SHARE (granted in 02_warehouses_roles.sql, which itself
   requires ACCOUNTADMIN to run once - see README "Deploying without
   ACCOUNTADMIN access" if that's not available in your environment).
   ========================================================================== */
CREATE SHARE IF NOT EXISTS SHR_RUNNINGTELCO_PARTNER_ANALYTICS
  COMMENT = 'Outbound share: aggregated regional usage/revenue/network KPIs for external partner';

GRANT USAGE ON DATABASE RUNNING_TELCO         TO SHARE SHR_RUNNINGTELCO_PARTNER_ANALYTICS;
GRANT USAGE ON SCHEMA RUNNING_TELCO.SHARE_OUT TO SHARE SHR_RUNNINGTELCO_PARTNER_ANALYTICS;
GRANT SELECT ON SHARE_OUT.VW_SHARE_REGIONAL_USAGE_DAILY     TO SHARE SHR_RUNNINGTELCO_PARTNER_ANALYTICS;
GRANT SELECT ON SHARE_OUT.VW_SHARE_REGIONAL_REVENUE_MONTHLY TO SHARE SHR_RUNNINGTELCO_PARTNER_ANALYTICS;
GRANT SELECT ON SHARE_OUT.VW_SHARE_TOWER_STATUS              TO SHARE SHR_RUNNINGTELCO_PARTNER_ANALYTICS;

-- Add the consumer Snowflake account (replace with the partner's account locator)
-- ALTER SHARE SHR_RUNNINGTELCO_PARTNER_ANALYTICS ADD ACCOUNTS = ('PARTNER_ACCOUNT_LOCATOR');

-- For consumers WITHOUT a Snowflake account, publish via Snowflake Marketplace
-- as a private listing instead of ADD ACCOUNTS, or provision a Reader Account:
-- CREATE MANAGED ACCOUNT partner_reader_acct
--   ADMIN_NAME = 'partner_admin', ADMIN_PASSWORD = '<set-strong-password>',
--   TYPE = READER;

-- Consumer-side (run in the partner's Snowflake account once share is accepted):
-- CREATE DATABASE RUNNINGTELCO_SHARED_DATA FROM SHARE <provider_account>.SHR_RUNNINGTELCO_PARTNER_ANALYTICS;
-- GRANT IMPORTED PRIVILEGES ON DATABASE RUNNINGTELCO_SHARED_DATA TO ROLE PARTNER_ANALYST_ROLE;

