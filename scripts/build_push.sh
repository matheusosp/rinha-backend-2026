#!/usr/bin/env bash
# Build the Docker image for linux/amd64 (Rinha test environment) and push to ghcr.io.
#
# Usage:
#   ./scripts/build_push.sh                 # build + push :latest
#   ./scripts/build_push.sh --no-push       # build only (local test)
#
# Requirements: docker buildx with linux/amd64 emulation (or native amd64)
#
# The build will:
#   1. Install Python + scikit-learn in the build stage
#   2. Download the 3M reference vectors (~50MB)
#   3. Train the Random Forest (200 trees, ~2 min)
#   4. Bake rf_model.json into the final ruby:slim image (~120MB)
# Total build time: ~5-10 min. Final image: ~120 MB.

set -euo pipefail

IMAGE="ghcr.io/matheusosp/rinha-backend-2026:latest"
PLATFORM="linux/amd64"
PUSH=true

for arg in "$@"; do
  [[ "$arg" == "--no-push" ]] && PUSH=false
done

echo "[build] Building $IMAGE for $PLATFORM..."
docker buildx build \
  --platform "$PLATFORM" \
  --tag "$IMAGE" \
  --file Dockerfile \
  --load \
  .

if $PUSH; then
  echo "[push] Pushing $IMAGE..."
  docker push "$IMAGE"
  echo "[push] Done!"
else
  echo "[build] Done (skipped push). Run: docker push $IMAGE"
fi

echo ""
echo "To test locally:"
echo "  docker compose -f docker-compose.local.yml up --build"
echo "  curl http://localhost:9999/ready"
echo "  curl -s -X POST http://localhost:9999/fraud-score -H 'content-type: application/json' \\"
echo "    -d '{\"transaction\":{\"amount\":9505.97,\"installments\":10,\"requested_at\":\"2026-03-14T05:15:12Z\"},\"customer\":{\"avg_amount\":81.28,\"tx_count_24h\":20,\"known_merchants\":[]},\"merchant\":{\"id\":\"MERC-068\",\"mcc\":\"7802\",\"avg_amount\":54.86},\"terminal\":{\"is_online\":false,\"card_present\":true,\"km_from_home\":952.27},\"last_transaction\":null}'"
