#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib/common.sh"
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
  echo "Example: HTTPS_CERT_FILE=/path/cert.pem HTTPS_KEY_FILE=/path/key.pem $(basename "$0") prod beeblebox 20260315-1545-a1b2c3d"
  exit 1
fi

common::validate_environment "$ENVIRONMENT" "rollback"

# For dev/test allow: rollback-release.sh test <release-id>
if [[ -n "$TARGET" && -z "$RELEASE_ID" && ( "$ENVIRONMENT" == "dev" || "$ENVIRONMENT" == "test" ) ]]; then
  RELEASE_ID="$TARGET"
  TARGET="local"
fi

if [[ -z "$TARGET" ]]; then
  TARGET="$(common::resolve_target "$ENVIRONMENT" "$TARGET" "rollback")"
fi

if [[ -z "$RELEASE_ID" ]]; then
  echo "[rollback] ERROR: release-id is required"
  exit 1
fi

RELEASE_DIR="$DIST_DIR/$RELEASE_ID"
[[ -d "$RELEASE_DIR" ]] || { echo "[rollback] ERROR: release not found: $RELEASE_DIR"; exit 1; }
ARCHIVE="$DIST_DIR/$RELEASE_ID.tar.gz"
if [[ -f "$ARCHIVE" ]]; then
  common::verify_release_checksum "$ARCHIVE" "rollback"
fi

AUDIT_LOG="$DIST_DIR/AUDIT.log"
{
  echo "$(date -Iseconds) rollback env=$ENVIRONMENT target=$TARGET release=$RELEASE_ID reason=${ROLLBACK_REASON:-unspecified}"
} >> "$AUDIT_LOG"
echo "[rollback] Audit: $AUDIT_LOG"

common::require_prod_tls "$ENVIRONMENT" "$HTTPS_CERT_FILE" "$HTTPS_KEY_FILE" "rollback"

echo "[rollback] Target: $TARGET"
echo "[rollback] Environment: $ENVIRONMENT"
echo "[rollback] Release: $RELEASE_ID"

if [[ -x "$LOCALSERVER_CONFIG_PATH/scripts/deploy-to-server.sh" ]]; then
  DEPLOY_ENV="$(common::map_infra_environment "$ENVIRONMENT")"
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
SMOKE_REQUIRED="$(common::webhook_smoke_required "$ENVIRONMENT")"
if ! "$ROOT/scripts/smoke-test-webhook.sh" "$ENVIRONMENT" "$TARGET"; then
  if [[ "$SMOKE_REQUIRED" == "1" ]]; then
    echo "[rollback] ERROR: webhook smoke test failed"
    exit 1
  fi
  echo "[rollback] WARN: webhook smoke test failed; continuing (dev warn-only)."
fi

echo "[rollback] PASS"
