#!/usr/bin/env bash
# Fetches reference dataset from the Rinha 2026 repository into ./data.
set -euo pipefail

BASE="https://raw.githubusercontent.com/zanfranceschi/rinha-de-backend-2026/main/resources"
DEST="${1:-data}"

mkdir -p "$DEST"
for f in references.json.gz mcc_risk.json normalization.json; do
  if [ ! -f "$DEST/$f" ]; then
    echo "fetching $f..."
    curl -fsSL "$BASE/$f" -o "$DEST/$f"
  fi
done
echo "done."
