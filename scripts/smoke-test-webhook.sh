#!/usr/bin/env bash
set -euo pipefail

ENVIRONMENT="${1:-}"
TARGET="${2:-}"
WEBHOOK_URL="${3:-${SMOKE_WEBHOOK_URL:-}}"
HTTPS_CERT_FILE="${HTTPS_CERT_FILE:-}"
HTTPS_KEY_FILE="${HTTPS_KEY_FILE:-}"
WORKFLOW_NAME="${WORKFLOW_NAME:-Shakespeare Play Explorer}"
SMOKE_EXPECTED_KEYS="${SMOKE_EXPECTED_KEYS:-play,requestType,title,items,summary}"
SMOKE_PAYLOAD="${SMOKE_PAYLOAD:-{\"play_name\":\"Hamlet\",\"output_type\":\"Key Characters\",\"email\":\"smoke@example.com\"}}"
SMOKE_METHOD="${SMOKE_METHOD:-POST}"
SMOKE_CONTENT_TYPE="${SMOKE_CONTENT_TYPE:-application/json}"
SMOKE_BASIC_AUTH_USER="${SMOKE_BASIC_AUTH_USER:-}"
SMOKE_BASIC_AUTH_PASS="${SMOKE_BASIC_AUTH_PASS:-}"
SMOKE_STRICT_JSON="${SMOKE_STRICT_JSON:-0}"

if [[ -z "$ENVIRONMENT" ]]; then
  echo "Usage: $(basename "$0") <environment: dev|test|prod> [target] [webhook-url]"
  echo "Env vars: N8N_API_KEY, WORKFLOW_NAME, SMOKE_WEBHOOK_URL, SMOKE_EXPECTED_KEYS, SMOKE_PAYLOAD"
  exit 1
fi

case "$ENVIRONMENT" in
  dev|test|prod) ;;
  *) echo "[webhook-smoke] ERROR: environment must be one of: dev, test, prod"; exit 1 ;;
esac

[[ -n "$WEBHOOK_URL" ]] || {
  if [[ -z "$TARGET" ]]; then
    if [[ "$ENVIRONMENT" == "dev" || "$ENVIRONMENT" == "test" ]]; then
      TARGET="local"
    else
      echo "[webhook-smoke] ERROR: target is required for prod when URL not provided"
      exit 1
    fi
  fi

  if WEBHOOK_URL="$("$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/get-webhook-url.sh" "$ENVIRONMENT" "$TARGET" "$WORKFLOW_NAME" 2>/tmp/n8n-webhook-discovery.err)"; then
    echo "[webhook-smoke] Discovered webhook URL: $WEBHOOK_URL"
  else
    echo "[webhook-smoke] ERROR: failed to discover webhook URL" >&2
    sed -n '1,20p' /tmp/n8n-webhook-discovery.err >&2 || true
    exit 1
  fi
}

curl_args=(-s -o /tmp/n8n-webhook-smoke.out -w "%{http_code}" -X "$SMOKE_METHOD" -H "Content-Type: $SMOKE_CONTENT_TYPE" --data "$SMOKE_PAYLOAD")

if [[ "$ENVIRONMENT" == "prod" ]]; then
  [[ -n "$HTTPS_CERT_FILE" && -n "$HTTPS_KEY_FILE" ]] || {
    echo "[webhook-smoke] ERROR: prod requires HTTPS_CERT_FILE and HTTPS_KEY_FILE";
    exit 1;
  }
  [[ -r "$HTTPS_CERT_FILE" && -r "$HTTPS_KEY_FILE" ]] || {
    echo "[webhook-smoke] ERROR: cannot read HTTPS cert/key files";
    exit 1;
  }
  curl_args+=(--cert "$HTTPS_CERT_FILE" --key "$HTTPS_KEY_FILE")
else
  # Homelab/local certs are often self-signed.
  curl_args+=(-k)
fi

if [[ -n "$SMOKE_BASIC_AUTH_USER" ]]; then
  curl_args+=(-u "$SMOKE_BASIC_AUTH_USER:$SMOKE_BASIC_AUTH_PASS")
fi

echo "[webhook-smoke] Invoking webhook: $WEBHOOK_URL"

if [[ "$WEBHOOK_URL" == *"/form/"* && "$SMOKE_STRICT_JSON" != "1" ]]; then
  echo "[webhook-smoke] Detected Form Trigger endpoint; running availability check (GET)."
  get_args=(-s -o /tmp/n8n-webhook-smoke.out -w "%{http_code}")
  if [[ "$ENVIRONMENT" == "prod" ]]; then
    get_args+=(--cert "$HTTPS_CERT_FILE" --key "$HTTPS_KEY_FILE")
  else
    get_args+=(-k)
  fi
  if [[ -n "$SMOKE_BASIC_AUTH_USER" ]]; then
    get_args+=(-u "$SMOKE_BASIC_AUTH_USER:$SMOKE_BASIC_AUTH_PASS")
  fi
  get_code="$(curl "${get_args[@]}" "$WEBHOOK_URL" || true)"
  if [[ "$get_code" =~ ^2 ]]; then
    echo "[webhook-smoke] PASS (Form endpoint reachable, HTTP $get_code)"
    exit 0
  fi
  echo "[webhook-smoke] FAIL (Form endpoint unavailable, HTTP $get_code)"
  sed -n '1,40p' /tmp/n8n-webhook-smoke.out 2>/dev/null || true
  exit 1
fi

HTTP_CODE="$(curl "${curl_args[@]}" "$WEBHOOK_URL" || true)"

if [[ ! "$HTTP_CODE" =~ ^2 ]]; then
  echo "[webhook-smoke] FAIL (HTTP $HTTP_CODE)"
  echo "[webhook-smoke] Response excerpt:"
  sed -n '1,40p' /tmp/n8n-webhook-smoke.out 2>/dev/null || true
  exit 1
fi

echo "[webhook-smoke] HTTP PASS (HTTP $HTTP_CODE)"
echo "[webhook-smoke] Validating response..."

if python3 - "$SMOKE_EXPECTED_KEYS" <<'PY'
import json
import sys
from pathlib import Path

expected = [k.strip() for k in sys.argv[1].split(",") if k.strip()]
body = Path("/tmp/n8n-webhook-smoke.out").read_text(encoding="utf-8").strip()

try:
    payload = json.loads(body)
except Exception as e:
    print(f"[webhook-smoke] RESPONSE_NOT_JSON: {e}")
    sys.exit(2)

missing = [k for k in expected if k not in payload]
if missing:
    print(f"[webhook-smoke] FAIL: missing expected keys: {', '.join(missing)}")
    print("[webhook-smoke] Response keys:", ", ".join(sorted(payload.keys())))
    sys.exit(1)

if "items" in payload and not isinstance(payload["items"], list):
    print("[webhook-smoke] FAIL: 'items' exists but is not a list")
    sys.exit(1)

print("[webhook-smoke] JSON PASS")
PY
then
  echo "[webhook-smoke] PASS"
else
  rc=$?
  if [[ $rc -eq 2 ]]; then
    if [[ "$SMOKE_STRICT_JSON" == "1" ]]; then
      echo "[webhook-smoke] FAIL: strict JSON mode enabled but response is not JSON"
      sed -n '1,40p' /tmp/n8n-webhook-smoke.out 2>/dev/null || true
      exit 1
    fi
    if [[ "$WEBHOOK_URL" == *"/form/"* ]]; then
      echo "[webhook-smoke] WARN: Form endpoints can return HTML; treating as pass in non-strict mode."
      echo "[webhook-smoke] PASS"
      exit 0
    fi
    echo "[webhook-smoke] FAIL: non-JSON response from non-form endpoint"
    sed -n '1,40p' /tmp/n8n-webhook-smoke.out 2>/dev/null || true
    exit 1
  fi
  exit $rc
fi

