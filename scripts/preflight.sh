#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOWS_DIR="$ROOT/workflows"
ENVIRONMENT="${1:-dev}"

case "$ENVIRONMENT" in
  dev|test|prod) ;;
  *) echo "[preflight] ERROR: environment must be one of: dev, test, prod"; exit 1 ;;
esac

echo "[preflight] Root: $ROOT"
echo "[preflight] Environment: $ENVIRONMENT"

[[ -d "$WORKFLOWS_DIR" ]] || { echo "[preflight] ERROR: missing workflows dir"; exit 1; }
[[ -f "$ROOT/tests/workflow-harness.mjs" ]] || { echo "[preflight] ERROR: missing tests/workflow-harness.mjs"; exit 1; }
[[ -f "$ROOT/docs/workflow-fields.md" ]] || { echo "[preflight] ERROR: missing docs/workflow-fields.md"; exit 1; }
[[ -f "$ROOT/docs/credentials.md" ]] || { echo "[preflight] ERROR: missing docs/credentials.md"; exit 1; }
[[ -f "$ROOT/docs/production-deployment-standard.md" ]] || { echo "[preflight] ERROR: missing docs/production-deployment-standard.md"; exit 1; }

echo "[preflight] Running workflow harness..."
node "$ROOT/tests/workflow-harness.mjs"

echo "[preflight] Validating workflow JSON syntax..."
shopt -s nullglob
json_files=("$WORKFLOWS_DIR"/*.json)
(( ${#json_files[@]} > 0 )) || { echo "[preflight] ERROR: no workflow JSON files found"; exit 1; }
for f in "${json_files[@]}"; do
  python3 -m json.tool "$f" >/dev/null
  echo "[preflight] OK $(basename "$f")"
done

echo "[preflight] PASS"
