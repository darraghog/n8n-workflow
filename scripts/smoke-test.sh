#!/usr/bin/env bash
set -euo pipefail

ENVIRONMENT="${1:-}"
TARGET="${2:-}"
HTTPS_CERT_FILE="${HTTPS_CERT_FILE:-}"
HTTPS_KEY_FILE="${HTTPS_KEY_FILE:-}"

if [[ -z "$ENVIRONMENT" ]]; then
  echo "Usage: $(basename "$0") <environment: dev|test|prod> [hostname|local]"
  exit 1
fi

case "$ENVIRONMENT" in
  dev|test|prod) ;;
  *) echo "[smoke] ERROR: environment must be one of: dev, test, prod"; exit 1 ;;
esac

if [[ -z "$TARGET" ]]; then
  if [[ "$ENVIRONMENT" == "dev" || "$ENVIRONMENT" == "test" ]]; then
    TARGET="local"
  else
    echo "[smoke] ERROR: target is required for prod"
    exit 1
  fi
fi

if [[ "$TARGET" == "local" ]]; then
  URL="https://127.0.0.1:8444"
else
  URL="https://$TARGET:8444"
fi

curl_args=(-k -s -o /tmp/n8n-smoke.out -w "%{http_code}")
if [[ "$ENVIRONMENT" == "prod" ]]; then
  [[ -n "$HTTPS_CERT_FILE" && -n "$HTTPS_KEY_FILE" ]] || {
    echo "[smoke] ERROR: prod requires HTTPS_CERT_FILE and HTTPS_KEY_FILE";
    exit 1;
  }
  [[ -r "$HTTPS_CERT_FILE" && -r "$HTTPS_KEY_FILE" ]] || {
    echo "[smoke] ERROR: cannot read HTTPS cert/key files";
    exit 1;
  }
  curl_args+=(--cert "$HTTPS_CERT_FILE" --key "$HTTPS_KEY_FILE")
fi

echo "[smoke] Checking n8n endpoint: $URL"
HTTP_CODE="$(curl "${curl_args[@]}" "$URL" || true)"

if [[ "$HTTP_CODE" =~ ^2|3|401$ ]]; then
  echo "[smoke] PASS (HTTP $HTTP_CODE)"
  exit 0
fi

echo "[smoke] FAIL (HTTP $HTTP_CODE)"
echo "[smoke] Response excerpt:"
sed -n '1,20p' /tmp/n8n-smoke.out 2>/dev/null || true
exit 1
