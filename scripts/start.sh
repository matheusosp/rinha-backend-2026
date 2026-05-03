#!/usr/bin/env bash
set -euo pipefail

DATA_DIR="${DATA_DIR:-data}"
PORT="${PORT:-5000}"

echo "[start] checking data files..."
./scripts/fetch-data.sh "$DATA_DIR"

MODEL_PATH="${DATA_DIR}/cache/rf_model.json"

if [ ! -f "$MODEL_PATH" ]; then
  echo "[start] RF model not found — starting warmup server on :${PORT} while training..."
  PORT="$PORT" ruby scripts/warmup_server.rb &
  WARMUP_PID=$!

  echo "[start] training Random Forest model (~5-10 min, 3M vectors)..."
  DATA_DIR="$DATA_DIR" python3 scripts/train_model.py

  echo "[start] killing warmup server (pid=${WARMUP_PID})..."
  kill "$WARMUP_PID" 2>/dev/null || true
  wait "$WARMUP_PID" 2>/dev/null || true
else
  echo "[start] RF model found — skipping training."
fi

echo "[start] launching puma with YJIT..."
exec env RUBYOPT="--yjit" bundle exec puma -C puma.rb config.ru
