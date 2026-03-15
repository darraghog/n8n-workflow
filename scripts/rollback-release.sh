#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT/dist/releases"
LOCALSERVER_CONFIG_PATH="${LOCALSERVER_CONFIG_PATH:-/home/darraghog/dev/localserver-config}"
HTTPS_CERT_FILE="${HTTPS_CERT_FILE:-}"
HTTPS_KEY_FILE="${HTTPS_KEY_FILE:-}"

ENVIRONMENT="${1:-}"
TARGET="${2:-}"
RELEASE_ID="${3:-}"

if [[ -z "$ENVIRONMENT" ]]; then
  echo "Usage: $(basename "$0") <environment: dev|test|prod> [target] <release-id>"
  echo "Example: $(basename "$0") test local 20260315-1545-a1b2c3d"
  echo "Example: $(basename "$0") test 20260315-1545-a1b2c3d"
  echo "Example: HTTPS_CERT_FILE=/path/cert.pem HTTPS_KEY_FILE=/path/key.pem $(basename "$0") prod darragh-pc 20260315-1545-a1b2c3d"
  exit 1
fi

case "$ENVIRONMENT" in
  dev|test|prod) ;;
  *) echo "[rollback] ERROR: environment must be one of: dev, test, prod"; exit 1 ;;
esac

# For dev/test allow: rollback-release.sh test <release-id>
if [[ -n "$TARGET" && -z "$RELEASE_ID" && ( "$ENVIRONMENT" == "dev" || "$ENVIRONMENT" == "test" ) ]]; then
  RELEASE_ID="$TARGET"
  TARGET="local"
fi

if [[ -z "$TARGET" ]]; then
  [[ "$ENVIRONMENT" == "dev" || "$ENVIRONMENT" == "test" ]] && TARGET="local"
fi

if [[ -z "$RELEASE_ID" ]]; then
  echo "[rollback] ERROR: release-id is required"
  exit 1
fi

if [[ "$ENVIRONMENT" == "prod" && -z "$TARGET" ]]; then
  echo "[rollback] ERROR: target is required for prod"
  exit 1
fi

RELEASE_DIR="$DIST_DIR/$RELEASE_ID"
[[ -d "$RELEASE_DIR" ]] || { echo "[rollback] ERROR: release not found: $RELEASE_DIR"; exit 1; }

if [[ "$ENVIRONMENT" == "prod" ]]; then
  [[ -n "$HTTPS_CERT_FILE" && -n "$HTTPS_KEY_FILE" ]] || {
    echo "[rollback] ERROR: prod requires HTTPS_CERT_FILE and HTTPS_KEY_FILE";
    exit 1;
  }
  [[ -r "$HTTPS_CERT_FILE" && -r "$HTTPS_KEY_FILE" ]] || {
    echo "[rollback] ERROR: cannot read HTTPS cert/key files";
    exit 1;
  }
fi

echo "[rollback] Target: $TARGET"
echo "[rollback] Environment: $ENVIRONMENT"
echo "[rollback] Release: $RELEASE_ID"

if [[ -x "$LOCALSERVER_CONFIG_PATH/scripts/deploy-to-server.sh" ]]; then
  DEPLOY_ENV="$ENVIRONMENT"
  if [[ "$ENVIRONMENT" == "dev" || "$ENVIRONMENT" == "test" ]]; then
    DEPLOY_ENV="local"
  fi
  echo "[rollback] Re-applying infra baseline on target..."
  "$LOCALSERVER_CONFIG_PATH/scripts/deploy-to-server.sh" "$DEPLOY_ENV" "$TARGET"
fi

if [[ "$TARGET" != "local" ]]; then
  echo "[rollback] Syncing rollback artifact to remote host..."
  ssh "$TARGET" "mkdir -p ~/n8n-releases/$RELEASE_ID"
  rsync -avz "$RELEASE_DIR/" "$TARGET:~/n8n-releases/$RELEASE_ID/"
fi

echo "[rollback] Importing and activating workflows from rollback release..."
"$ROOT/scripts/import-release.sh" "$ENVIRONMENT" "$TARGET" "$RELEASE_ID"

echo "[rollback] Running smoke tests after rollback..."
"$ROOT/scripts/smoke-test.sh" "$ENVIRONMENT" "$TARGET"
if ! "$ROOT/scripts/smoke-test-webhook.sh" "$ENVIRONMENT" "$TARGET"; then
  if [[ "${REQUIRE_WEBHOOK_SMOKE_PASS:-0}" == "1" ]]; then
    echo "[rollback] ERROR: webhook smoke test failed and REQUIRE_WEBHOOK_SMOKE_PASS=1"
    exit 1
  fi
  echo "[rollback] WARN: webhook smoke test failed; continuing (set REQUIRE_WEBHOOK_SMOKE_PASS=1 to make rollback fail)."
fi

echo "[rollback] PASS"
