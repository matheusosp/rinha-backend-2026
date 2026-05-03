#!/usr/bin/env bash
set -euo pipefail

DATA_DIR="${DATA_DIR:-data}"
PORT="${PORT:-5000}"

echo "[start] checking data files..."
./scripts/fetch-data.sh "$DATA_DIR"

HNSW_M="${HNSW_M:-16}"
HNSW_EF_CONSTRUCTION="${HNSW_EF_CONSTRUCTION:-200}"
INDEX_PATH="${DATA_DIR}/cache/hnsw_m${HNSW_M}_ec${HNSW_EF_CONSTRUCTION}.idx"
LABELS_PATH="${DATA_DIR}/cache/labels.bin"

if [ ! -f "$INDEX_PATH" ] || [ ! -f "$LABELS_PATH" ]; then
  echo "[start] cache not found — starting warmup server on :${PORT} while index builds..."
  PORT="$PORT" ruby scripts/warmup_server.rb &
  WARMUP_PID=$!

  echo "[start] building HNSW index (M=${HNSW_M}, ef_construction=${HNSW_EF_CONSTRUCTION}, 3M vectors)..."
  HNSW_M="$HNSW_M" HNSW_EF_CONSTRUCTION="$HNSW_EF_CONSTRUCTION" \
    bundle exec ruby --yjit -I lib scripts/build_cache.rb

  echo "[start] killing warmup server (pid=${WARMUP_PID})..."
  kill "$WARMUP_PID" 2>/dev/null || true
  wait "$WARMUP_PID" 2>/dev/null || true
else
  echo "[start] cache ok — skipping build."
fi

echo "[start] launching puma with YJIT..."
exec env RUBYOPT="--yjit" bundle exec puma -C puma.rb config.ru
