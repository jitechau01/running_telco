#!/usr/bin/env bash
# ==============================================================================
# ci/lint_checks.sh
#
# Static checks that run on every pull request, BEFORE anything ever touches
# Snowflake. Every single check here exists because we actually hit that exact
# bug during this project's development - this file is the "never again" list.
# Fast (no Snowflake connection needed), so it runs on every PR without
# spending warehouse credits or requiring credentials.
# ==============================================================================
set -uo pipefail

FAIL=0

fail() {
  echo "FAIL: $1"
  FAIL=1
}

pass() {
  echo "PASS: $1"
}

echo "=============================================================="
echo "1. Python files compile cleanly"
echo "=============================================================="
if python3 -m py_compile python/config/config.py python/ingestion/*.py python/orchestration/*.py airflow/dags/*.py; then
  pass "all Python files compile"
else
  fail "one or more Python files failed to compile"
fi

echo ""
echo "=============================================================="
echo "2. No multi-role GRANT statements (GRANT ... TO ROLE A, B, C)"
echo "   Snowflake's GRANT ... TO ROLE clause takes exactly ONE role -"
echo "   a comma-separated role list is a silent-until-runtime SQL"
echo "   compilation error. Every grant must be one role per statement."
echo "=============================================================="
if grep -rnE "TO ROLE [A-Z_]+\s*,\s*[A-Z_]+" sql/ 2>/dev/null | grep -v "^\s*--"; then
  fail "found a multi-role TO ROLE grant above - split into one GRANT per role"
else
  pass "no multi-role grants found"
fi

echo ""
echo "=============================================================="
echo "3. CREATE PIPE only appears in 01_raw_layer/02_snowpipe.sql"
echo "   A pipe's COPY INTO target table must already exist at CREATE"
echo "   PIPE time - this file position guarantees deploy.sh runs it"
echo "   after the RAW tables are created, not before."
echo "=============================================================="
PIPE_FILES=$(grep -rl "^CREATE PIPE" sql/ 2>/dev/null)
if [ "$PIPE_FILES" != "sql/01_raw_layer/02_snowpipe.sql" ]; then
  fail "CREATE PIPE found outside sql/01_raw_layer/02_snowpipe.sql: $PIPE_FILES"
else
  pass "CREATE PIPE correctly isolated to 02_snowpipe.sql"
fi

echo ""
echo "=============================================================="
echo "4. Every CREATE TASK lives in the ORCHESTRATION schema"
echo "   Snowflake requires every task chained via AFTER in one DAG"
echo "   to share a single schema - splitting root/merge tasks across"
echo "   STAGING/CURATED fails with 'Cannot have predecessor from a"
echo "   different schema.'"
echo "=============================================================="
BAD_TASKS=$(grep -rn "^CREATE TASK IF NOT EXISTS" sql/ 2>/dev/null | grep -v "ORCHESTRATION\.")
if [ -n "$BAD_TASKS" ]; then
  fail "found a CREATE TASK not qualified with ORCHESTRATION.: $BAD_TASKS"
else
  pass "all tasks correctly qualified with ORCHESTRATION."
fi

echo ""
echo "=============================================================="
echo "5. No bare procedure-parameter references inside AUDIT_CTL bodies"
echo "   Snowflake Scripting requires a ':' prefix for any parameter or"
echo "   variable referenced inside an embedded SQL statement (SELECT/"
echo "   UPDATE/INSERT) - a bare reference compiles at CREATE time but"
echo "   fails at CALL time with 'invalid identifier'."
echo "=============================================================="
# Heuristic: look for P_ parameters used bare (no leading colon) anywhere
# other than the CREATE PROCEDURE(...) parameter declaration itself.
BARE_REFS=$(grep -noP '(?<!:)\bP_[A-Z_]+\b' sql/08_audit_control/02_audit_procedures.sql 2>/dev/null \
  | awk -F: '{print $1}' | sort -u)
DECL_LINES=$(grep -noE '^\s*P_[A-Z_]+ (NUMBER|STRING|VARIANT)' sql/08_audit_control/02_audit_procedures.sql 2>/dev/null \
  | cut -d: -f1 | sort -u)
STRAY=$(comm -23 <(echo "$BARE_REFS") <(echo "$DECL_LINES"))
if [ -n "$STRAY" ]; then
  fail "possible bare (non-colon-prefixed) parameter reference on line(s): $STRAY - verify manually"
else
  pass "no bare parameter references found outside declarations"
fi

echo ""
echo "=============================================================="
echo "6. Orchestrator COPY INTO uses per-feed column lists, not a"
echo "   hardcoded \$1..\$16 that only fits the widest table"
echo "=============================================================="
if grep -q '\$1, \$2, \$3, \$4, \$5, \$6, \$7, \$8, \$9, \$10' python/orchestration/snowflake_orchestrator.py 2>/dev/null; then
  fail "found a hardcoded \$1..\$16 SELECT list - COPY INTO column count must be built per-feed from FEED_REGISTRY"
else
  pass "no hardcoded column-position list found"
fi

echo ""
echo "=============================================================="
if [ "$FAIL" -eq 0 ]; then
  echo "ALL CHECKS PASSED"
else
  echo "ONE OR MORE CHECKS FAILED - see FAIL lines above"
fi
echo "=============================================================="
exit $FAIL
