#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# MLOps Validation Test Suite
#
# Tests 3 layers:
#   1. ERROR HANDLING  — every bad-input path in the Lambda handler
#   2. MONITORING      — verify CloudWatch alarms + dashboard exist
#   3. LOAD TEST       — concurrent requests to check latency + scaling
#
# Usage:
#   chmod +x scripts/test_production.sh
#   ./scripts/test_production.sh <API_URL> <ENDPOINT_NAME> [REGION]
#
# Example:
#   ./scripts/test_production.sh \
#     "https://abc123.execute-api.us-east-1.amazonaws.com/dev/predict" \
#     "customer-churn-dev-endpoint" \
#     "us-east-1"
# ═══════════════════════════════════════════════════════════════
set -euo pipefail

API_URL="${1:?Usage: $0 <API_URL> <ENDPOINT_NAME> [REGION]}"
ENDPOINT_NAME="${2:?Usage: $0 <API_URL> <ENDPOINT_NAME> [REGION]}"
REGION="${3:-us-east-1}"
# Derive the name prefix from endpoint name (e.g. customer-churn-dev)
NAME_PREFIX="${ENDPOINT_NAME%-endpoint}"

PASS=0
FAIL=0
TOTAL=0

# ─── Helpers ─────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

check() {
    local test_name="$1"
    local expected_code="$2"
    local actual_code="$3"
    local response_body="$4"
    TOTAL=$((TOTAL + 1))

    if [ "$actual_code" = "$expected_code" ]; then
        echo -e "  ${GREEN}PASS${NC} $test_name (HTTP $actual_code)"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} $test_name — expected $expected_code, got $actual_code"
        echo "       Response: $(echo "$response_body" | head -c 200)"
        FAIL=$((FAIL + 1))
    fi
}

check_exists() {
    local test_name="$1"
    local result="$2"
    TOTAL=$((TOTAL + 1))

    if [ -n "$result" ] && [ "$result" != "None" ] && [ "$result" != "null" ]; then
        echo -e "  ${GREEN}PASS${NC} $test_name"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC} $test_name — not found"
        FAIL=$((FAIL + 1))
    fi
}

HEALTH_URL="${API_URL%predict}health"

echo ""
echo "═══════════════════════════════════════════════════════════"
echo " MLOps Validation Test Suite"
echo " Endpoint: $ENDPOINT_NAME"
echo " API URL:  $API_URL"
echo " Region:   $REGION"
echo "═══════════════════════════════════════════════════════════"

# ═══════════════════════════════════════════════════════════════
# LAYER 1: ERROR HANDLING
# Every bad-input path in the Lambda handler
# ═══════════════════════════════════════════════════════════════
echo ""
echo -e "${CYAN}━━━ Layer 1: Error handling (8 tests) ━━━${NC}"
echo ""

# Test 1: Health endpoint
RESP=$(curl -s -w "\n%{http_code}" "$HEALTH_URL")
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
check "GET /health returns 200" "200" "$CODE" "$BODY"

# Test 2: Valid prediction (baseline — should always work)
RESP=$(curl -s -w "\n%{http_code}" -X POST "$API_URL" \
    -H "Content-Type: application/json" \
    -d '{"instances":[[45,3,39,5,1,3,12691,777,11914,1.335,1144,42,1.625,0.061,0.16,0.16,0.15,0.14,0.17]]}')
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
check "Valid prediction returns 200" "200" "$CODE" "$BODY"

# Test 3: Missing 'instances' key
RESP=$(curl -s -w "\n%{http_code}" -X POST "$API_URL" \
    -H "Content-Type: application/json" \
    -d '{"data":[[1,2,3]]}')
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
check "Missing 'instances' key returns 400" "400" "$CODE" "$BODY"

# Test 4: Wrong number of features (3 instead of 19)
RESP=$(curl -s -w "\n%{http_code}" -X POST "$API_URL" \
    -H "Content-Type: application/json" \
    -d '{"instances":[[1,2,3]]}')
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
check "Wrong feature count (3) returns 400" "400" "$CODE" "$BODY"

# Test 5: Empty instances list
RESP=$(curl -s -w "\n%{http_code}" -X POST "$API_URL" \
    -H "Content-Type: application/json" \
    -d '{"instances":[]}')
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
check "Empty instances returns 400" "400" "$CODE" "$BODY"

# Test 6: Invalid JSON body
RESP=$(curl -s -w "\n%{http_code}" -X POST "$API_URL" \
    -H "Content-Type: application/json" \
    -d 'not-json-at-all')
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
check "Invalid JSON returns 400" "400" "$CODE" "$BODY"

# Test 7: Flat list instead of nested (instances should be list of lists)
RESP=$(curl -s -w "\n%{http_code}" -X POST "$API_URL" \
    -H "Content-Type: application/json" \
    -d '{"instances":[45,3,39,5,1,3,12691,777,11914,1.335,1144,42,1.625,0.061,0.16,0.16,0.15,0.14,0.17]}')
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
check "Flat list (not nested) returns 400" "400" "$CODE" "$BODY"

# Test 8: Unknown route
RESP=$(curl -s -w "\n%{http_code}" -X GET "${API_URL%predict}nonexistent")
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
check "GET /nonexistent returns 403 or 404" "403" "$CODE" "$BODY"
# Note: API Gateway returns 403 for undefined routes (not 404)

# ═══════════════════════════════════════════════════════════════
# LAYER 2: MONITORING VERIFICATION
# Check that CloudWatch alarms, dashboard, and data capture exist
# ═══════════════════════════════════════════════════════════════
echo ""
echo -e "${CYAN}━━━ Layer 2: Monitoring verification (7 tests) ━━━${NC}"
echo ""

# Test 9-12: CloudWatch Alarms exist
for ALARM_SUFFIX in "endpoint-5xx" "endpoint-latency-p99" "no-invocations" "high-cpu"; do
    ALARM_NAME="${NAME_PREFIX}-${ALARM_SUFFIX}"
    RESULT=$(aws cloudwatch describe-alarms \
        --alarm-names "$ALARM_NAME" \
        --region "$REGION" \
        --query 'MetricAlarms[0].AlarmName' \
        --output text 2>/dev/null || echo "")
    check_exists "Alarm: $ALARM_NAME" "$RESULT"
done

# Test 13: CloudWatch Dashboard exists
DASHBOARD_NAME="${NAME_PREFIX}-dashboard"
RESULT=$(aws cloudwatch get-dashboard \
    --dashboard-name "$DASHBOARD_NAME" \
    --region "$REGION" \
    --query 'DashboardName' \
    --output text 2>/dev/null || echo "")
check_exists "Dashboard: $DASHBOARD_NAME" "$RESULT"

# Test 14: SNS Alert topic exists
ALERT_TOPIC=$(aws sns list-topics --region "$REGION" \
    --query "Topics[?contains(TopicArn, '${NAME_PREFIX}-alerts')].TopicArn | [0]" \
    --output text 2>/dev/null || echo "")
check_exists "SNS topic: ${NAME_PREFIX}-alerts" "$ALERT_TOPIC"

# Test 15: Data capture is enabled on the endpoint
DATA_CAPTURE=$(aws sagemaker describe-endpoint \
    --endpoint-name "$ENDPOINT_NAME" \
    --region "$REGION" \
    --query 'DataCaptureConfig.EnableCapture' \
    --output text 2>/dev/null || echo "")
TOTAL=$((TOTAL + 1))
if [ "$DATA_CAPTURE" = "True" ]; then
    echo -e "  ${GREEN}PASS${NC} Data capture enabled on $ENDPOINT_NAME"
    PASS=$((PASS + 1))
else
    echo -e "  ${RED}FAIL${NC} Data capture not enabled (got: $DATA_CAPTURE)"
    FAIL=$((FAIL + 1))
fi

# ═══════════════════════════════════════════════════════════════
# LAYER 3: LOAD TEST
# Concurrent requests to measure latency distribution and
# verify the endpoint handles parallel traffic
# ═══════════════════════════════════════════════════════════════
echo ""
echo -e "${CYAN}━━━ Layer 3: Load test ━━━${NC}"
echo ""

CONCURRENCY=20
REQUESTS_PER_WORKER=5
TOTAL_REQUESTS=$((CONCURRENCY * REQUESTS_PER_WORKER))

echo "  Config: $CONCURRENCY concurrent workers × $REQUESTS_PER_WORKER requests = $TOTAL_REQUESTS total"
echo ""

# Prepare test payload
PAYLOAD='{"instances":[[45,3,39,5,1,3,12691,777,11914,1.335,1144,42,1.625,0.061,0.16,0.16,0.15,0.14,0.17]]}'

# Create temp dir for results
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# Worker function: sends N requests and records latency + status
worker() {
    local worker_id=$1
    local count=$2
    local outfile="$TMPDIR/worker_${worker_id}.txt"

    for i in $(seq 1 "$count"); do
        START=$(date +%s%N)
        CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API_URL" \
            -H "Content-Type: application/json" \
            -d "$PAYLOAD" --max-time 30)
        END=$(date +%s%N)
        LATENCY_MS=$(( (END - START) / 1000000 ))
        echo "$CODE $LATENCY_MS" >> "$outfile"
    done
}

echo "  Firing $TOTAL_REQUESTS requests..."
START_TIME=$(date +%s)

# Launch workers in parallel
for w in $(seq 1 "$CONCURRENCY"); do
    worker "$w" "$REQUESTS_PER_WORKER" &
done
wait

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

# Aggregate results
cat "$TMPDIR"/worker_*.txt > "$TMPDIR/all.txt"
TOTAL_SENT=$(wc -l < "$TMPDIR/all.txt")
SUCCESS=$(grep -c "^200 " "$TMPDIR/all.txt" || echo 0)
ERRORS=$((TOTAL_SENT - SUCCESS))
ERROR_RATE=$(echo "scale=2; $ERRORS * 100 / $TOTAL_SENT" | bc)

# Calculate latency percentiles
LATENCIES=$(awk '{print $2}' "$TMPDIR/all.txt" | sort -n)
P50=$(echo "$LATENCIES" | awk "NR==$(( (TOTAL_SENT * 50 + 99) / 100 ))")
P90=$(echo "$LATENCIES" | awk "NR==$(( (TOTAL_SENT * 90 + 99) / 100 ))")
P99=$(echo "$LATENCIES" | awk "NR==$(( (TOTAL_SENT * 99 + 99) / 100 ))")
MIN_LAT=$(echo "$LATENCIES" | head -1)
MAX_LAT=$(echo "$LATENCIES" | tail -1)
AVG_LAT=$(echo "$LATENCIES" | awk '{sum+=$1} END {printf "%.0f", sum/NR}')
RPS=$(echo "scale=1; $TOTAL_SENT / $ELAPSED" | bc)

echo ""
echo "  ┌─────────────────────────────────────────┐"
echo "  │          Load Test Results               │"
echo "  ├─────────────────────────────────────────┤"
echo "  │ Total requests:    $TOTAL_SENT"
echo "  │ Successful (200):  $SUCCESS"
echo "  │ Errors:            $ERRORS ($ERROR_RATE%)"
echo "  │ Duration:          ${ELAPSED}s"
echo "  │ Throughput:        ${RPS} req/s"
echo "  │                                         │"
echo "  │ Latency (ms):                           │"
echo "  │   Min:     ${MIN_LAT}ms"
echo "  │   p50:     ${P50}ms"
echo "  │   p90:     ${P90}ms"
echo "  │   p99:     ${P99}ms"
echo "  │   Max:     ${MAX_LAT}ms"
echo "  │   Avg:     ${AVG_LAT}ms"
echo "  └─────────────────────────────────────────┘"
echo ""

# Evaluate load test results
TOTAL=$((TOTAL + 3))

if [ "$ERROR_RATE" = "0.00" ] || [ "$ERROR_RATE" = "0" ]; then
    echo -e "  ${GREEN}PASS${NC} Zero errors under load ($TOTAL_SENT requests)"
    PASS=$((PASS + 1))
else
    echo -e "  ${RED}FAIL${NC} Error rate: ${ERROR_RATE}% ($ERRORS/$TOTAL_SENT failed)"
    FAIL=$((FAIL + 1))
fi

if [ "$P99" -lt 5000 ]; then
    echo -e "  ${GREEN}PASS${NC} p99 latency ${P99}ms < 5000ms SLA"
    PASS=$((PASS + 1))
else
    echo -e "  ${RED}FAIL${NC} p99 latency ${P99}ms exceeds 5000ms SLA"
    FAIL=$((FAIL + 1))
fi

if [ "$P50" -lt 3000 ]; then
    echo -e "  ${GREEN}PASS${NC} p50 latency ${P50}ms < 3000ms target"
    PASS=$((PASS + 1))
else
    echo -e "  ${YELLOW}WARN${NC} p50 latency ${P50}ms exceeds 3000ms target"
    FAIL=$((FAIL + 1))
fi

# ═══════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════════"
echo -e " RESULTS: ${GREEN}$PASS passed${NC} / ${RED}$FAIL failed${NC} / $TOTAL total"
echo "═══════════════════════════════════════════════════════════"
echo ""

if [ "$FAIL" -eq 0 ]; then
    echo -e " ${GREEN}ALL TESTS PASSED${NC} — Your MLOps stack is production-ready."
else
    echo -e " ${YELLOW}$FAIL test(s) need attention.${NC} Review the failures above."
fi

echo ""
echo " Next steps:"
echo "   • Open CloudWatch dashboard: https://${REGION}.console.aws.amazon.com/cloudwatch/home?region=${REGION}#dashboards:name=${DASHBOARD_NAME}"
echo "   • Check data capture in S3:  aws s3 ls s3://${NAME_PREFIX}-monitoring/data-capture/ --recursive | tail -5"
echo "   • View endpoint metrics:     aws cloudwatch get-metric-statistics --namespace AWS/SageMaker --metric-name Invocations --dimensions Name=EndpointName,Value=${ENDPOINT_NAME} --start-time \$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) --end-time \$(date -u +%Y-%m-%dT%H:%M:%S) --period 300 --statistics Sum"
echo ""

exit $FAIL