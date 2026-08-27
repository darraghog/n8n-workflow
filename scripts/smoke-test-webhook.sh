#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib/common.sh"

ENVIRONMENT="${1:-}"
TARGET="${2:-}"
WEBHOOK_URL="${3:-${SMOKE_WEBHOOK_URL:-}}"
HTTPS_CERT_FILE="${HTTPS_CERT_FILE:-}"
HTTPS_KEY_FILE="${HTTPS_KEY_FILE:-}"
WORKFLOW_NAME="${WORKFLOW_NAME:-Shakespeare Play Explorer Eval}"
SMOKE_EXPECTED_KEYS="${SMOKE_EXPECTED_KEYS:-request_id,status,play_name,result}"
SMOKE_PAYLOAD="${SMOKE_PAYLOAD:-{\"play_name\":\"Hamlet\",\"output_type\":\"Key Characters\",\"email\":\"smoke@example.com\"}}"
SMOKE_METHOD="${SMOKE_METHOD:-POST}"
SMOKE_CONTENT_TYPE="${SMOKE_CONTENT_TYPE:-application/json}"
discovery_err_file=""
out_file=""

cleanup() {
  [[ -n "$discovery_err_file" ]] && rm -f "$discovery_err_file"
  [[ -n "$out_file" ]] && rm -f "$out_file"
}
trap cleanup EXIT

common::load_project_env "$ROOT"

if [[ -z "$ENVIRONMENT" ]]; then
  echo "Usage: $(basename "$0") <environment: dev|test|prod> [target] [webhook-url]"
  echo "Env vars: N8N_API_KEY, EVAL_WEBHOOK_TOKEN, WORKFLOW_NAME, SMOKE_WEBHOOK_URL, SMOKE_EXPECTED_KEYS, SMOKE_PAYLOAD"
  exit 1
fi

common::validate_environment "$ENVIRONMENT" "webhook-smoke"
TARGET="$(common::resolve_target "$ENVIRONMENT" "$TARGET" "webhook-smoke")"

[[ -n "$WEBHOOK_URL" ]] || {
  discovery_err_file="$(mktemp)"
  if WEBHOOK_URL="$("$ROOT/scripts/get-webhook-url.sh" "$ENVIRONMENT" "$TARGET" "$WORKFLOW_NAME" webhook 2>"$discovery_err_file")"; then
    echo "[webhook-smoke] Discovered test webhook URL: $WEBHOOK_URL"
  else
    echo "[webhook-smoke] ERROR: failed to discover test webhook URL" >&2
    python3 - "$discovery_err_file" <<'PY' >&2 || true
import sys
txt = open(sys.argv[1], "r", encoding="utf-8", errors="replace").read()
print(txt[:1200])
PY
    exit 1
  fi
}

if [[ -n "${EVAL_WEBHOOK_TOKEN:-}" ]]; then
  SMOKE_PAYLOAD="$(EVAL_WEBHOOK_TOKEN="$EVAL_WEBHOOK_TOKEN" python3 - "$SMOKE_PAYLOAD" <<'PY'
import json, os, sys
payload = json.loads(sys.argv[1])
payload["eval_token"] = os.environ["EVAL_WEBHOOK_TOKEN"]
print(json.dumps(payload))
PY
)"
fi

tls_args=()
common::build_tls_curl_args "$ENVIRONMENT" "$HTTPS_CERT_FILE" "$HTTPS_KEY_FILE" "webhook-smoke" tls_args
out_file="$(mktemp)"
curl_args=(-sS -o "$out_file" -w "%{http_code}" -X "$SMOKE_METHOD" -H "Content-Type: $SMOKE_CONTENT_TYPE" --data "$SMOKE_PAYLOAD" "${tls_args[@]}")

if [[ -n "${EVAL_WEBHOOK_TOKEN:-}" ]]; then
  curl_args+=(-H "X-Eval-Token: $EVAL_WEBHOOK_TOKEN")
fi

echo "[webhook-smoke] Invoking test webhook: $WEBHOOK_URL"
HTTP_CODE="$(curl "${curl_args[@]}" "$WEBHOOK_URL" || true)"

if [[ ! "$HTTP_CODE" =~ ^2 ]]; then
  echo "[webhook-smoke] FAIL (HTTP $HTTP_CODE)"
  python3 - "$out_file" <<'PY' || true
import sys
txt = open(sys.argv[1], "r", encoding="utf-8", errors="replace").read()
print(txt[:2000])
PY
  exit 1
fi

echo "[webhook-smoke] HTTP PASS (HTTP $HTTP_CODE)"
echo "[webhook-smoke] Validating JSON schema keys..."

python3 - "$SMOKE_EXPECTED_KEYS" "$out_file" <<'PY'
import json
import sys
from pathlib import Path

expected = [k.strip() for k in sys.argv[1].split(",") if k.strip()]
body = Path(sys.argv[2]).read_text(encoding="utf-8").strip()
payload = json.loads(body)
if isinstance(payload, str):
    payload = json.loads(payload)

missing = [k for k in expected if k not in payload]
if missing:
    print(f"[webhook-smoke] FAIL: missing expected keys: {', '.join(missing)}")
    print("[webhook-smoke] Response keys:", ", ".join(sorted(payload.keys())))
    sys.exit(1)

result = payload.get("result")
if not isinstance(result, dict):
    print("[webhook-smoke] FAIL: result is not an object")
    sys.exit(1)
for key in ("play", "requestType", "title", "items", "summary"):
    if key not in result:
        print(f"[webhook-smoke] FAIL: result missing {key}")
        sys.exit(1)
if not isinstance(result["items"], list):
    print("[webhook-smoke] FAIL: result.items is not a list")
    sys.exit(1)
if "email" in payload:
    print("[webhook-smoke] FAIL: webhook response leaked email")
    sys.exit(1)

print("[webhook-smoke] JSON PASS")
print("[webhook-smoke] status=", payload.get("status"))
print("[webhook-smoke] schema_ok=", payload.get("schema_ok"))
print("[webhook-smoke] groundedness_ok=", payload.get("groundedness_ok"))
PY

echo "[webhook-smoke] PASS"
