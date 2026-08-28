#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib/common.sh"
WORKFLOWS_DIR="$ROOT/workflows"
ENVIRONMENT="${1:-dev}"

common::validate_environment "$ENVIRONMENT" "preflight"

echo "[preflight] Root: $ROOT"
echo "[preflight] Environment: $ENVIRONMENT"

[[ -d "$WORKFLOWS_DIR" ]] || { echo "[preflight] ERROR: missing workflows dir"; exit 1; }
[[ -f "$ROOT/tests/workflow-harness.mjs" ]] || { echo "[preflight] ERROR: missing tests/workflow-harness.mjs"; exit 1; }
[[ -f "$ROOT/docs/workflow-fields.md" ]] || { echo "[preflight] ERROR: missing docs/workflow-fields.md"; exit 1; }
[[ -f "$ROOT/docs/credentials.md" ]] || { echo "[preflight] ERROR: missing docs/credentials.md"; exit 1; }
[[ -f "$ROOT/docs/production-deployment-standard.md" ]] || { echo "[preflight] ERROR: missing docs/production-deployment-standard.md"; exit 1; }
[[ -f "$ROOT/workflows/shakespeare-play-explorer-error.json" ]] || { echo "[preflight] ERROR: missing operator error workflow"; exit 1; }
[[ -f "$ROOT/workflows/shakespeare-play-explorer-core.json" ]] || { echo "[preflight] ERROR: missing core workflow"; exit 1; }

echo "[preflight] Running workflow harness..."
python3 "$ROOT/scripts/generate-main-workflow.py" >/dev/null
node "$ROOT/tests/workflow-harness.mjs"

echo "[preflight] Validating workflow JSON syntax..."
shopt -s nullglob
json_files=("$WORKFLOWS_DIR"/*.json)
(( ${#json_files[@]} > 0 )) || { echo "[preflight] ERROR: no workflow JSON files found"; exit 1; }
for f in "${json_files[@]}"; do
  python3 -m json.tool "$f" >/dev/null
  echo "[preflight] OK $(basename "$f")"
done

echo "[preflight] Running secret scan..."
bash "$ROOT/scripts/secret-scan.sh"

echo "[preflight] Validating eval cases..."
[[ -f "$ROOT/evals/cases.json" ]] || { echo "[preflight] ERROR: missing evals/cases.json"; exit 1; }
python3 -m json.tool "$ROOT/evals/cases.json" >/dev/null

echo "[preflight] PASS"
