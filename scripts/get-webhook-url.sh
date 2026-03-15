#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib/common.sh"
ENVIRONMENT="${1:-}"
TARGET="${2:-}"
WORKFLOW_NAME="${3:-${WORKFLOW_NAME:-Shakespeare Play Explorer}}"
N8N_API_KEY="${N8N_API_KEY:-}"
N8N_API_URL="${N8N_API_URL:-}"
HTTPS_CERT_FILE="${HTTPS_CERT_FILE:-}"
HTTPS_KEY_FILE="${HTTPS_KEY_FILE:-}"
REQUIRE_ACTIVE_WORKFLOW="${REQUIRE_ACTIVE_WORKFLOW:-1}"

if [[ -z "$N8N_API_KEY" ]]; then
  common::load_project_env "$ROOT"
  N8N_API_KEY="${N8N_API_KEY:-}"
fi

if [[ -z "$ENVIRONMENT" ]]; then
  echo "Usage: $(basename "$0") <environment: dev|test|prod> [target] [workflow-name]" >&2
  exit 1
fi

common::validate_environment "$ENVIRONMENT" "webhook-discovery"
TARGET="$(common::resolve_target "$ENVIRONMENT" "$TARGET" "webhook-discovery")"

if [[ -z "$N8N_API_KEY" ]]; then
  echo "[webhook-discovery] ERROR: N8N_API_KEY is required" >&2
  exit 1
fi

N8N_API_URL="$(common::resolve_n8n_api_url "$TARGET" "$N8N_API_URL")"

curl_args=(-sS -H "X-N8N-API-KEY: $N8N_API_KEY")
tls_args=()
common::build_tls_curl_args "$ENVIRONMENT" "$HTTPS_CERT_FILE" "$HTTPS_KEY_FILE" "webhook-discovery" tls_args
curl_args+=("${tls_args[@]}")

resp_file="$(mktemp)"
trap 'rm -f "$resp_file"' EXIT
common::fetch_paginated_collection "$N8N_API_URL/workflows" 250 "$resp_file" curl_args "webhook-discovery"

python3 - "$resp_file" "$WORKFLOW_NAME" "$TARGET" "$REQUIRE_ACTIVE_WORKFLOW" <<'PY'
import json
import sys

resp_path, workflow_name, target, require_active = sys.argv[1:5]
require_active = str(require_active).strip().lower() not in {"0", "false", "no"}

with open(resp_path, "r", encoding="utf-8") as f:
    payload = json.load(f)

if isinstance(payload, dict) and isinstance(payload.get("data"), list):
    workflows = payload["data"]
elif isinstance(payload, list):
    workflows = payload
else:
    raise SystemExit("[webhook-discovery] ERROR: unexpected workflow API response shape")

name_matches = [w for w in workflows if w.get("name") == workflow_name and not bool(w.get("isArchived"))]
if not name_matches:
    raise SystemExit(f"[webhook-discovery] ERROR: workflow not found: {workflow_name}")

# Prefer active workflow, fallback to newest by id if needed.
active_matches = [w for w in name_matches if bool(w.get("active"))]
if active_matches:
    workflow = active_matches[0]
else:
    workflow = name_matches[0]
    if require_active:
        raise SystemExit(
            f"[webhook-discovery] ERROR: workflow '{workflow_name}' is not active; "
            "import/activate it first before webhook smoke testing"
        )

nodes = workflow.get("nodes", [])
form_node = next((n for n in nodes if n.get("type") == "n8n-nodes-base.formTrigger"), None)
if form_node is None:
    raise SystemExit("[webhook-discovery] ERROR: no formTrigger node found in workflow")

params = form_node.get("parameters", {})
options = params.get("options", {}) if isinstance(params.get("options"), dict) else {}

path = (
    params.get("path")
    or options.get("path")
    or form_node.get("webhookId")
)
if not path:
    raise SystemExit("[webhook-discovery] ERROR: could not determine form path/webhookId")

if target == "local":
    base = "https://127.0.0.1:8444"
else:
    base = f"https://{target}:8444"

path = str(path).lstrip("/")
print(f"{base}/form/{path}")
PY
