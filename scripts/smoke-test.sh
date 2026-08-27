#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib/common.sh"

ENVIRONMENT="${1:-}"
TARGET="${2:-}"
HTTPS_CERT_FILE="${HTTPS_CERT_FILE:-}"
HTTPS_KEY_FILE="${HTTPS_KEY_FILE:-}"
OLLAMA_HEALTH_URL="${OLLAMA_HEALTH_URL:-}"

common::load_project_env "$ROOT"

if [[ -z "$ENVIRONMENT" ]]; then
  echo "Usage: $(basename "$0") <environment: dev|test|prod> [hostname|local]"
  exit 1
fi

common::validate_environment "$ENVIRONMENT" "smoke"
TARGET="$(common::resolve_target "$ENVIRONMENT" "$TARGET" "smoke")"
BASE_URL="$(common::resolve_n8n_base_url "$TARGET")"

tls_args=()
common::build_tls_curl_args "$ENVIRONMENT" "$HTTPS_CERT_FILE" "$HTTPS_KEY_FILE" "smoke" tls_args
out_file="$(mktemp)"
trap 'rm -f "$out_file"' EXIT

probe() {
  local url="$1"
  local code
  code="$(curl -sS -o "$out_file" -w "%{http_code}" "${tls_args[@]}" "$url" || true)"
  echo "$code"
}

echo "[smoke] Environment: $ENVIRONMENT"
echo "[smoke] Target: $TARGET"

health_urls=("${BASE_URL}/healthz")
if [[ "$TARGET" == "local" ]]; then
  health_urls+=("http://127.0.0.1:5678/healthz")
elif [[ "$TARGET" == "beeblebox" || "$TARGET" == "beeblebox.taile98462.ts.net" ]]; then
  health_urls+=("https://beeblebox.taile98462.ts.net:8444/healthz")
  health_urls+=("https://beeblebox:8444/healthz")
fi

health_ok=0
for url in "${health_urls[@]}"; do
  echo "[smoke] Checking n8n health: $url"
  code="$(probe "$url")"
  if [[ "$code" =~ ^2 ]]; then
    echo "[smoke] n8n health PASS (HTTP $code)"
    health_ok=1
    break
  fi
  echo "[smoke] n8n health miss (HTTP $code) at $url"
done

if [[ "$health_ok" != "1" ]]; then
  echo "[smoke] FAIL: n8n /healthz did not return 2xx"
  python3 - "$out_file" <<'PY' || true
import sys
txt = open(sys.argv[1], "r", encoding="utf-8", errors="replace").read()
print(txt[:1200])
PY
  exit 1
fi

if [[ -z "$OLLAMA_HEALTH_URL" ]]; then
  OLLAMA_HEALTH_URL="${OLLAMA_BASE_URL:-http://127.0.0.1:11434}/api/tags"
fi
# host.docker.internal is for containers; probe from the operator host.
OLLAMA_HEALTH_URL="${OLLAMA_HEALTH_URL/host.docker.internal/127.0.0.1}"

echo "[smoke] Checking Ollama: $OLLAMA_HEALTH_URL"
ollama_code="$(curl -sS -o "$out_file" -w "%{http_code}" "$OLLAMA_HEALTH_URL" || true)"
if [[ "$ollama_code" =~ ^2 ]]; then
  echo "[smoke] Ollama PASS (HTTP $ollama_code)"
else
  require_ollama="${REQUIRE_OLLAMA_SMOKE_PASS:-}"
  if [[ -z "$require_ollama" ]]; then
    if [[ "$TARGET" == "local" && "$ENVIRONMENT" != "dev" ]]; then
      require_ollama=1
    else
      require_ollama=0
    fi
  fi
  if [[ "$require_ollama" == "1" ]]; then
    echo "[smoke] FAIL: Ollama /api/tags returned HTTP $ollama_code"
    exit 1
  fi
  echo "[smoke] WARN: Ollama /api/tags returned HTTP $ollama_code (not reachable from this operator host)"
fi

echo "[smoke] PASS"
