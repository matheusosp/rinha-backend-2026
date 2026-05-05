#!/usr/bin/env bash
set -euo pipefail

DATA_DIR="${DATA_DIR:-data}"

echo "[start] checking data files..."
./scripts/fetch-data.sh "$DATA_DIR"

INDEX_PATH="${DATA_DIR}/cache/border_index.bin"
if [ ! -f "$INDEX_PATH" ]; then
  echo "[start] border index not found - building with Ruby..."
  DATA_DIR="$DATA_DIR" bundle exec ruby scripts/build_border_index.rb
else
  echo "[start] border index found - skipping build."
fi

echo "[start] launching puma with YJIT..."
exec env RUBYOPT="--yjit" bundle exec puma -C puma.rb config.ru
