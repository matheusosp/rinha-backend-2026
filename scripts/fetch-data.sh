#!/usr/bin/env bash
# Fetches reference dataset and test data from the Rinha 2026 repository.
set -euo pipefail

BASE="https://raw.githubusercontent.com/zanfranceschi/rinha-de-backend-2026/main"
DEST="${1:-data}"

mkdir -p "$DEST"
for f in references.json.gz mcc_risk.json normalization.json; do
  if [ ! -f "$DEST/$f" ]; then
    echo "fetching $f..."
    curl -fsSL "$BASE/resources/$f" -o "$DEST/$f"
  fi
done

mkdir -p test
if [ ! -f "test/test-data.json" ] || [ "$(wc -c < test/test-data.json)" -lt 26000000 ]; then
  echo "fetching test/test-data.json (official, ~26MB)..."
  curl -fsSL "$BASE/test/test-data.json" -o test/test-data.json
fi

echo "done."
