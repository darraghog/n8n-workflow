#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib/common.sh"
DIST_DIR="$ROOT/dist/releases"
LOCALSERVER_CONFIG_PATH="${LOCALSERVER_CONFIG_PATH:-/home/darraghog/dev/localserver-config}"
HTTPS_CERT_FILE="${HTTPS_CERT_FILE:-}"
HTTPS_KEY_FILE="${HTTPS_KEY_FILE:-}"

common::load_project_env "$ROOT"

ENVIRONMENT="${1:-}"
TARGET="${2:-}"
RELEASE_ID="${3:-}"

if [[ -z "$ENVIRONMENT" ]]; then
  echo "Usage: $(basename "$0") <environment: dev|test|prod> [target] [release-id]"
  echo "Example: $(basename "$0") test local"
  echo "Example: HTTPS_CERT_FILE=/path/cert.pem HTTPS_KEY_FILE=/path/key.pem $(basename "$0") prod darragh-pc 20260315-1545-a1b2c3d"
  exit 1
fi

common::validate_environment "$ENVIRONMENT" "deploy"
TARGET="$(common::resolve_target "$ENVIRONMENT" "$TARGET" "deploy")"

if [[ -z "$RELEASE_ID" ]]; then
  if [[ -f "$DIST_DIR/LATEST" ]]; then
    RELEASE_ID="$(tr -d '\n' < "$DIST_DIR/LATEST")"
  else
    echo "[deploy] No latest release found. Packaging now..."
    "$ROOT/scripts/package-release.sh" "$ENVIRONMENT"
    RELEASE_ID="$(tr -d '\n' < "$DIST_DIR/LATEST")"
  fi
fi

RELEASE_DIR="$DIST_DIR/$RELEASE_ID"
[[ -d "$RELEASE_DIR" ]] || { echo "[deploy] ERROR: missing release dir $RELEASE_DIR"; exit 1; }
[[ -x "$LOCALSERVER_CONFIG_PATH/scripts/deploy-to-server.sh" ]] || {
  echo "[deploy] ERROR: deploy script not found at $LOCALSERVER_CONFIG_PATH/scripts/deploy-to-server.sh"
  exit 1
}

echo "[deploy] Release: $RELEASE_ID"
echo "[deploy] Environment: $ENVIRONMENT"
echo "[deploy] Target: $TARGET"

common::require_prod_tls "$ENVIRONMENT" "$HTTPS_CERT_FILE" "$HTTPS_KEY_FILE" "deploy"

DEPLOY_ENV="$(common::map_infra_environment "$ENVIRONMENT")"

echo "[deploy] Infra deploy via localserver-config..."
"$LOCALSERVER_CONFIG_PATH/scripts/deploy-to-server.sh" "$DEPLOY_ENV" "$TARGET"

if [[ "$TARGET" != "local" ]]; then
  echo "[deploy] Syncing release bundle to remote host..."
  ssh "$TARGET" "mkdir -p ~/n8n-releases/$RELEASE_ID"
  rsync -avz "$RELEASE_DIR/" "$TARGET:~/n8n-releases/$RELEASE_ID/"
  echo "[deploy] Remote bundle: ~/n8n-releases/$RELEASE_ID"
fi

echo "[deploy] Post-deploy smoke checks..."
"$ROOT/scripts/smoke-test.sh" "$ENVIRONMENT" "$TARGET"

echo "[deploy] Importing and activating workflows in n8n..."
"$ROOT/scripts/import-release.sh" "$ENVIRONMENT" "$TARGET" "$RELEASE_ID"

if [[ -n "${SMOKE_WEBHOOK_URL:-}" ]]; then
  echo "[deploy] Running webhook smoke test..."
  if ! "$ROOT/scripts/smoke-test-webhook.sh" "$ENVIRONMENT" "$TARGET" "$SMOKE_WEBHOOK_URL"; then
    if [[ "${REQUIRE_WEBHOOK_SMOKE_PASS:-0}" == "1" ]]; then
      echo "[deploy] ERROR: webhook smoke test failed and REQUIRE_WEBHOOK_SMOKE_PASS=1"
      exit 1
    fi
    echo "[deploy] WARN: webhook smoke test failed; continuing (set REQUIRE_WEBHOOK_SMOKE_PASS=1 to fail deployment)."
  fi
else
  echo "[deploy] Running webhook smoke test with URL discovery..."
  if ! "$ROOT/scripts/smoke-test-webhook.sh" "$ENVIRONMENT" "$TARGET"; then
    if [[ "${REQUIRE_WEBHOOK_SMOKE_PASS:-0}" == "1" ]]; then
      echo "[deploy] ERROR: webhook smoke test failed and REQUIRE_WEBHOOK_SMOKE_PASS=1"
      exit 1
    fi
    echo "[deploy] WARN: webhook smoke test failed; continuing (set REQUIRE_WEBHOOK_SMOKE_PASS=1 to fail deployment)."
  fi
fi

echo ""
echo "[deploy] Deployment completed with automated import+activation."
if [[ "$TARGET" == "local" ]]; then
  echo "  URL: https://localhost:8444 (or your host mapping)"
else
  echo "  URL: https://$TARGET:8444"
fi
echo "  Artifact: $RELEASE_DIR/workflows/*.json"
