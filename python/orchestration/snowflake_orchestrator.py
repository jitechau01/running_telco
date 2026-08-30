"""
snowflake_orchestrator.py

The Python half of the Audit & Control framework. This orchestrator drives
the pipeline through THREE INDEPENDENT LAYERS - raw, staging, curated - each
its own invocation via --layer, matching how the Snowflake TASK DAG (see
sql/05_tasks) separates them. Nothing auto-chains between layers: you decide
when RAW moves to STAGING and when STAGING moves to CURATED, by running the
script again with a different --layer. This is what lets each layer be
scheduled independently (e.g. CDR raw+staging hourly via cron, curated left
entirely to the Snowflake TASKs, or all three as separate Airflow tasks -
see airflow/dags/running_telco_pipeline_dag.py).

  1. --layer raw     : COPY INTO for each feed's external stage -> RAW table.
                        Captures per-file load results (rows parsed, rows
                        loaded, errors) from Snowflake's own COPY INTO result
                        set into AUDIT_CTL.ETL_RUN_LOG / ETL_ERROR_LOG - so a
                        partially-bad file is visible immediately. The target
                        column list is built per-feed from FEED_REGISTRY in
                        config.py - each feed's RAW table has a different
                        width, so this is NOT a hardcoded $1..$16 guess.
  2. --layer staging : CALL STAGING.SP_LOAD_STG_<feed>() per feed (each one
                        does its own internal audit logging via
                        SP_AUDIT_START/END/FAIL - see sql/08_audit_control).
  3. --layer curated  : CALL CURATED.SP_MERGE_* for all 8 dims/facts (no
                        --feeds - always runs the full set).
  4. --layer all      : runs 1 -> 2 -> 3 in sequence, for local/manual testing
                        only. In production, prefer separate scheduled
                        invocations per layer over this.

Every step retries transient failures with exponential backoff, and a failed
feed/proc is logged to ETL_ERROR_LOG and does not block the rest. At the end,
prints a daily run summary pulled from AUDIT_CTL.VW_DAILY_RUN_STATS /
VW_OPEN_ERRORS.

Usage:
    python snowflake_orchestrator.py --layer raw --feeds customers,plans,billing
    python snowflake_orchestrator.py --layer staging --feeds all
    python snowflake_orchestrator.py --layer curated
    python snowflake_orchestrator.py --layer all --feeds all
"""
import argparse
import logging
import os
import sys
import time
from datetime import datetime

import snowflake.connector
from snowflake.connector import DictCursor

sys.path.append(os.path.join(os.path.dirname(__file__), "..", "config"))
from config import SnowflakeConfig, FEED_REGISTRY, CURATED_MERGE_PROCS  # noqa: E402

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)s | %(message)s",
    handlers=[logging.StreamHandler(), logging.FileHandler("orchestrator.log")],
)
log = logging.getLogger("orchestrator")

MAX_RETRIES = 3
BACKOFF_BASE_SECONDS = 5

STAGE_MAP = {
    "customers": "RAW.STG_CUSTOMERS",
    "plans": "RAW.STG_PLANS",
    "devices": "RAW.STG_DEVICES",
    "cdr": "RAW.STG_CDR",           # normally Snowpipe auto-ingest; COPY INTO here is the manual/backfill path
    "billing": "RAW.STG_BILLING",
    "payments": "RAW.STG_PAYMENTS",
    "towers": "RAW.STG_TOWERS",
    "support_tickets": "RAW.STG_SUPPORT_TICKETS",
}


class SnowflakeOrchestrator:
    def __init__(self, cfg: SnowflakeConfig):
        self.cfg = cfg
        self.conn = None

    def connect(self):
        connect_kwargs = dict(
            account=self.cfg.account,
            user=self.cfg.user,
            role=self.cfg.role,
            warehouse=self.cfg.warehouse,
            database=self.cfg.database,
            schema=self.cfg.schema,
        )
        if self.cfg.private_key_path:
            connect_kwargs["private_key_file"] = self.cfg.private_key_path
        else:
            connect_kwargs["password"] = self.cfg.password

        self.conn = snowflake.connector.connect(**connect_kwargs)
        log.info(f"Connected to Snowflake account={self.cfg.account} role={self.cfg.role} wh={self.cfg.warehouse}")

    def close(self):
        if self.conn:
            self.conn.close()

    # ------------------------------------------------------------------ #
    # Generic retry wrapper - transient network/warehouse-provisioning
    # errors are retried with exponential backoff; anything else raises
    # immediately so the caller can log it as a real failure.
    # ------------------------------------------------------------------ #
    def _execute_with_retry(self, sql: str, params=None):
        last_exc = None
        for attempt in range(1, MAX_RETRIES + 1):
            try:
                cur = self.conn.cursor(DictCursor)
                cur.execute(sql, params or {})
                return cur
            except snowflake.connector.errors.OperationalError as e:
                last_exc = e
                wait = BACKOFF_BASE_SECONDS * (2 ** (attempt - 1))
                log.warning(f"Transient error on attempt {attempt}/{MAX_RETRIES}: {e}. Retrying in {wait}s.")
                time.sleep(wait)
            except Exception:
                # Non-transient (SQL compile error, permission error, etc) - don't retry
                raise
        raise last_exc

    # ------------------------------------------------------------------ #
    # COPY INTO RAW.<table>, with an explicit per-feed target column list
    # (built from FEED_REGISTRY) and per-file results captured to the audit
    # tables directly from Python (COPY INTO's own result set).
    # ------------------------------------------------------------------ #
    def load_raw_feed(self, feed: str) -> dict:
        meta = FEED_REGISTRY[feed]
        stage = STAGE_MAP[feed]
        raw_table = meta["raw_table"]
        columns = meta["columns"]
        job_name = meta["job_name"].replace("RAW_TO_STAGING", "S3_TO_RAW")

        run_id = self._audit_start(job_name, "PYTHON_ORCHESTRATOR")
        try:
            # Explicit target column list (data columns + source_file_name),
            # deliberately excluding _load_ts so it keeps its table DEFAULT
            # CURRENT_TIMESTAMP(). Without an explicit column list, COPY INTO
            # positionally maps against ALL columns of the target table
            # (including _load_ts), which fails since the column count
            # differs per feed (16 for customers, 6 for towers, etc).
            target_cols = ", ".join(columns + ["source_file_name"])
            select_list = ", ".join(f"${i}" for i in range(1, len(columns) + 1))
            select_list += ", METADATA$FILENAME"

            copy_sql = f"""
                COPY INTO {raw_table} ({target_cols})
                FROM (
                    SELECT {select_list}
                    FROM @{stage}
                )
                FILE_FORMAT = (FORMAT_NAME = 'RAW.FF_CSV_STANDARD')
                ON_ERROR = 'CONTINUE'
                PURGE = FALSE
            """
            cur = self._execute_with_retry(copy_sql)
            results = cur.fetchall()

            rows_parsed = sum(r.get("rows_parsed", 0) or 0 for r in results)
            rows_loaded = sum(r.get("rows_loaded", 0) or 0 for r in results)
            errors_seen = sum(r.get("errors_seen", 0) or 0 for r in results)

            for r in results:
                if (r.get("errors_seen") or 0) > 0:
                    self._log_error(
                        run_id, job_name, "FILE_FORMAT",
                        f"File {r.get('file')} had {r.get('errors_seen')} row errors: {r.get('first_error')}",
                        {"file": r.get("file"), "error_limit": r.get("error_limit")},
                        severity="WARNING",
                    )

            self._audit_end(run_id, rows_parsed, rows_loaded, 0, 0, errors_seen,
                             f"COPY INTO {raw_table} complete: {len(results)} file(s)")
            log.info(f"[{feed}] COPY INTO {raw_table}: parsed={rows_parsed} loaded={rows_loaded} errors={errors_seen}")
            return {"feed": feed, "status": "SUCCESS", "rows_loaded": rows_loaded, "errors": errors_seen}

        except Exception as e:
            self._audit_fail(run_id, "SQL_ERROR", str(e), {"feed": feed, "stage": stage})
            log.error(f"[{feed}] COPY INTO FAILED: {e}")
            return {"feed": feed, "status": "FAILED", "error": str(e)}

    def call_staging_procedure(self, feed: str) -> dict:
        meta = FEED_REGISTRY[feed]
        try:
            cur = self._execute_with_retry(f"CALL {meta['proc']}()")
            result = cur.fetchone()
            log.info(f"[{feed}] {meta['proc']} -> {result}")
            return {"feed": feed, "status": "SUCCESS", "result": str(result)}
        except Exception as e:
            # The procedure logs its own failure via SP_AUDIT_FAIL internally;
            # we still surface it here so the orchestrator's own summary is complete.
            log.error(f"[{feed}] {meta['proc']} FAILED: {e}")
            return {"feed": feed, "status": "FAILED", "error": str(e)}

    def call_curated_merges(self) -> list:
        outcomes = []
        for job_name, proc in CURATED_MERGE_PROCS:
            try:
                cur = self._execute_with_retry(f"CALL {proc}()")
                result = cur.fetchone()
                log.info(f"[curated] {proc} -> {result}")
                outcomes.append({"job": job_name, "status": "SUCCESS"})
            except Exception as e:
                log.error(f"[curated] {proc} FAILED: {e}")
                outcomes.append({"job": job_name, "status": "FAILED", "error": str(e)})
        return outcomes

    # ------------------------------------------------------------------ #
    # Thin wrappers around the SQL audit procedures so Python-driven steps
    # (the COPY INTO step specifically) are logged the same way SQL-driven
    # steps are - one unified audit trail regardless of which side triggered it.
    # ------------------------------------------------------------------ #
    def _audit_start(self, job_name: str, triggered_by: str) -> int:
        cur = self._execute_with_retry(
            "CALL AUDIT_CTL.SP_AUDIT_START(%(job_name)s, %(triggered_by)s)",
            {"job_name": job_name, "triggered_by": triggered_by},
        )
        return list(cur.fetchone().values())[0]

    def _audit_end(self, run_id, rows_read, rows_inserted, rows_updated, rows_deleted, rows_rejected, comments):
        self._execute_with_retry(
            """CALL AUDIT_CTL.SP_AUDIT_END(%(run_id)s, %(rr)s, %(ri)s, %(ru)s, %(rd)s, %(rj)s, %(c)s)""",
            {"run_id": run_id, "rr": rows_read, "ri": rows_inserted, "ru": rows_updated,
             "rd": rows_deleted, "rj": rows_rejected, "c": comments},
        )

    def _audit_fail(self, run_id, error_type, error_msg, context: dict):
        import json
        self._execute_with_retry(
            """CALL AUDIT_CTL.SP_AUDIT_FAIL(%(run_id)s, %(et)s, %(code)s, %(msg)s, PARSE_JSON(%(ctx)s))""",
            {"run_id": run_id, "et": error_type, "code": "N/A", "msg": error_msg[:4000],
             "ctx": json.dumps(context)},
        )

    def _log_error(self, run_id, job_name, error_type, msg, context: dict, severity="ERROR"):
        import json
        self._execute_with_retry(
            """INSERT INTO AUDIT_CTL.ETL_ERROR_LOG
               (run_id, job_name, error_type, error_message, error_context, severity)
               SELECT %(run_id)s, %(job)s, %(et)s, %(msg)s, PARSE_JSON(%(ctx)s), %(sev)s""",
            {"run_id": run_id, "job": job_name, "et": error_type, "msg": msg[:4000],
             "ctx": json.dumps(context), "sev": severity},
        )

    # ------------------------------------------------------------------ #
    # Daily summary - what a Slack/email alert would be built from
    # ------------------------------------------------------------------ #
    def print_daily_summary(self):
        cur = self._execute_with_retry(
            "SELECT * FROM AUDIT_CTL.VW_DAILY_RUN_STATS WHERE run_date = CURRENT_DATE()"
        )
        rows = cur.fetchall()
        log.info("=" * 100)
        log.info(f"DAILY RUN SUMMARY - {datetime.now().date()}")
        log.info("=" * 100)
        for r in rows:
            log.info(
                f"{r['JOB_NAME']:<40} runs={r['TOTAL_RUNS']:<3} "
                f"success={r['SUCCESSFUL_RUNS']:<3} failed={r['FAILED_RUNS']:<3} "
                f"rows_in={r['TOTAL_ROWS_READ']:<10} rows_out={r['TOTAL_ROWS_INSERTED']:<10} "
                f"rejected={r['TOTAL_ROWS_REJECTED']:<6} avg_sec={r['AVG_DURATION_SECONDS']}"
            )

        cur = self._execute_with_retry("SELECT * FROM AUDIT_CTL.VW_OPEN_ERRORS LIMIT 20")
        errors = cur.fetchall()
        if errors:
            log.warning(f"{len(errors)} OPEN ERROR(S):")
            for e in errors:
                log.warning(f"  [{e['SEVERITY']}] {e['JOB_NAME']} @ {e['ERROR_TIME']}: {e['ERROR_MESSAGE'][:200]}")
        else:
            log.info("No open errors.")


def main():
    ap = argparse.ArgumentParser(
        description="Running Telco pipeline orchestrator. The three layers are "
                     "independent - each is its own invocation, matching how the "
                     "Snowflake TASK DAG separates them (see sql/05_tasks). Nothing "
                     "auto-chains: running --layer raw does NOT also run staging."
    )
    ap.add_argument(
        "--layer", required=True, choices=["raw", "staging", "curated", "all"],
        help="Which layer to run: "
             "'raw' = S3 -> RAW (COPY INTO per feed's stage), "
             "'staging' = RAW -> STAGING (CALL SP_LOAD_STG_* per feed), "
             "'curated' = STAGING -> CURATED (CALL SP_MERGE_* - no --feeds, runs all 8), "
             "'all' = run raw, then staging, then curated in sequence (convenience "
             "for local testing only - in production these should be separate "
             "scheduled invocations, e.g. separate Airflow tasks/cron entries)."
    )
    ap.add_argument("--feeds", default="all",
                     help="comma separated feed names or 'all' - applies to --layer raw|staging, ignored for curated")
    args = ap.parse_args()

    feeds = list(FEED_REGISTRY.keys()) if args.feeds == "all" else args.feeds.split(",")

    orch = SnowflakeOrchestrator(SnowflakeConfig())
    orch.connect()

    outcomes = []
    try:
        if args.layer in ("raw", "all"):
            log.info(f"=== LAYER: raw (S3 -> RAW) - feeds: {', '.join(feeds)} ===")
            for feed in feeds:
                log.info(f"--- Processing feed: {feed} ---")
                outcomes.append(orch.load_raw_feed(feed))

        if args.layer in ("staging", "all"):
            log.info(f"=== LAYER: staging (RAW -> STAGING) - feeds: {', '.join(feeds)} ===")
            for feed in feeds:
                log.info(f"--- Processing feed: {feed} ---")
                outcomes.append(orch.call_staging_procedure(feed))

        if args.layer in ("curated", "all"):
            log.info("=== LAYER: curated (STAGING -> CURATED) ===")
            outcomes.extend(orch.call_curated_merges())

        orch.print_daily_summary()

    finally:
        orch.close()

    failed = [o for o in outcomes if o.get("status") == "FAILED"]
    if failed:
        log.error(f"Pipeline run completed with {len(failed)} failure(s).")
        sys.exit(1)
    log.info("Pipeline run completed successfully.")


if __name__ == "__main__":
    main()
