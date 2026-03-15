#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib/common.sh"

ENVIRONMENT="${1:-}"
TARGET="${2:-}"
HTTPS_CERT_FILE="${HTTPS_CERT_FILE:-}"
HTTPS_KEY_FILE="${HTTPS_KEY_FILE:-}"

if [[ -z "$ENVIRONMENT" ]]; then
  echo "Usage: $(basename "$0") <environment: dev|test|prod> [hostname|local]"
  exit 1
fi

common::validate_environment "$ENVIRONMENT" "smoke"
TARGET="$(common::resolve_target "$ENVIRONMENT" "$TARGET" "smoke")"
URL="$(common::resolve_n8n_base_url "$TARGET")"

tls_args=()
common::build_tls_curl_args "$ENVIRONMENT" "$HTTPS_CERT_FILE" "$HTTPS_KEY_FILE" "smoke" tls_args
out_file="$(mktemp)"
trap 'rm -f "$out_file"' EXIT
curl_args=(-s -o "$out_file" -w "%{http_code}" "${tls_args[@]}")

echo "[smoke] Checking n8n endpoint: $URL"
HTTP_CODE="$(curl "${curl_args[@]}" "$URL" || true)"

if [[ "$HTTP_CODE" =~ ^(2|3|401) ]]; then
  echo "[smoke] PASS (HTTP $HTTP_CODE)"
  exit 0
fi

echo "[smoke] FAIL (HTTP $HTTP_CODE)"
echo "[smoke] Response excerpt:"
python3 - "$out_file" <<'PY' || true
import sys
txt = open(sys.argv[1], "r", encoding="utf-8", errors="replace").read()
print(txt[:1200])
PY
exit 1
