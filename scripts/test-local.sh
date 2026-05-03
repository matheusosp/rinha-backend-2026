#!/usr/bin/env bash
# Run k6 tests against the local dev server (port 5000).
# In Docker/production, the server listens on 9999 via nginx.
set -euo pipefail

export K6_NO_USAGE_REPORT=true
TARGET="${TARGET_URL:-http://localhost:5000}"
MODE="${1:-smoke}"

case "$MODE" in
  smoke)
    echo "Running smoke test against $TARGET..."
    k6 run --env TARGET_URL="$TARGET" test/smoke.js
    ;;
  load)
    echo "Running full load test against $TARGET (120s, ramp to 900 req/s)..."
    echo "NOTE: Full score test is designed for Docker. Local results will differ."
    K6_NO_USAGE_REPORT=true k6 run \
      --env TARGET_URL="$TARGET" \
      --env K6_RESULT_FILE=test/results.json \
      test/test.js
    echo ""
    echo "=== Results ==="
    cat test/results.json | python3 -m json.tool 2>/dev/null || cat test/results.json
    ;;
  *)
    echo "Usage: $0 [smoke|load]"
    echo "  smoke  - Quick 5-request smoke test (default)"
    echo "  load   - Full 120s load test (ramps to 900 req/s)"
    exit 1
    ;;
esac
