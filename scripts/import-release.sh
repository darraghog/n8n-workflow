#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT/dist/releases"

ENVIRONMENT="${1:-}"
TARGET="${2:-}"
RELEASE_ID="${3:-}"

N8N_API_KEY="${N8N_API_KEY:-}"
N8N_API_URL="${N8N_API_URL:-}"
HTTPS_CERT_FILE="${HTTPS_CERT_FILE:-}"
HTTPS_KEY_FILE="${HTTPS_KEY_FILE:-}"
N8N_SMTP_CREDENTIAL_ID="${N8N_SMTP_CREDENTIAL_ID:-}"
N8N_SMTP_CREDENTIAL_NAME="${N8N_SMTP_CREDENTIAL_NAME:-}"

if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ROOT/.env"
  set +a
  N8N_API_KEY="${N8N_API_KEY:-}"
  N8N_SMTP_CREDENTIAL_ID="${N8N_SMTP_CREDENTIAL_ID:-}"
  N8N_SMTP_CREDENTIAL_NAME="${N8N_SMTP_CREDENTIAL_NAME:-}"
fi

if [[ -z "$ENVIRONMENT" ]]; then
  echo "Usage: $(basename "$0") <environment: dev|test|prod> [target] [release-id]"
  exit 1
fi

case "$ENVIRONMENT" in
  dev|test|prod) ;;
  *) echo "[import] ERROR: environment must be one of: dev, test, prod"; exit 1 ;;
esac

if [[ -z "$TARGET" ]]; then
  if [[ "$ENVIRONMENT" == "dev" || "$ENVIRONMENT" == "test" ]]; then
    TARGET="local"
  else
    echo "[import] ERROR: target is required for prod"
    exit 1
  fi
fi

if [[ -z "$RELEASE_ID" ]]; then
  if [[ -f "$DIST_DIR/LATEST" ]]; then
    RELEASE_ID="$(tr -d '\n' < "$DIST_DIR/LATEST")"
  else
    echo "[import] ERROR: release-id missing and no LATEST file found"
    exit 1
  fi
fi

RELEASE_DIR="$DIST_DIR/$RELEASE_ID"
WORKFLOWS_DIR="$RELEASE_DIR/workflows"
[[ -d "$WORKFLOWS_DIR" ]] || { echo "[import] ERROR: workflows not found in release: $WORKFLOWS_DIR"; exit 1; }

[[ -n "$N8N_API_KEY" ]] || { echo "[import] ERROR: N8N_API_KEY is required"; exit 1; }

if [[ -z "$N8N_API_URL" ]]; then
  if [[ "$TARGET" == "local" ]]; then
    N8N_API_URL="https://127.0.0.1:8444/api/v1"
  else
    N8N_API_URL="https://$TARGET:8444/api/v1"
  fi
fi

curl_common=(-sS -H "X-N8N-API-KEY: $N8N_API_KEY" -H "Content-Type: application/json")
if [[ "$ENVIRONMENT" == "prod" ]]; then
  [[ -n "$HTTPS_CERT_FILE" && -n "$HTTPS_KEY_FILE" ]] || {
    echo "[import] ERROR: prod requires HTTPS_CERT_FILE and HTTPS_KEY_FILE";
    exit 1;
  }
  [[ -r "$HTTPS_CERT_FILE" && -r "$HTTPS_KEY_FILE" ]] || {
    echo "[import] ERROR: cannot read HTTPS cert/key files";
    exit 1;
  }
  curl_common+=(--cert "$HTTPS_CERT_FILE" --key "$HTTPS_KEY_FILE")
else
  curl_common+=(-k)
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

echo "[import] Environment: $ENVIRONMENT"
echo "[import] Target: $TARGET"
echo "[import] API: $N8N_API_URL"
echo "[import] Release: $RELEASE_ID"

list_file="$tmp_dir/workflows-list.json"
curl "${curl_common[@]}" "$N8N_API_URL/workflows?limit=250" -o "$list_file"

if [[ -z "$N8N_SMTP_CREDENTIAL_ID" ]]; then
  cred_file="$tmp_dir/credentials-list.json"
  if curl "${curl_common[@]}" "$N8N_API_URL/credentials?limit=250" -o "$cred_file" >/dev/null 2>&1; then
    N8N_SMTP_CREDENTIAL_ID="$(python3 - "$cred_file" "$N8N_SMTP_CREDENTIAL_NAME" <<'PY'
import json, sys
p = json.load(open(sys.argv[1], "r", encoding="utf-8"))
name = sys.argv[2]
data = p.get("data", p if isinstance(p, list) else [])
if name:
    for c in data:
        if c.get("name") == name:
            print(c.get("id", ""))
            raise SystemExit

# Fallback: first smtp credential.
for c in data:
    if str(c.get("type", "")).lower() == "smtp":
        print(c.get("id", ""))
        break
PY
)"
    if [[ -n "$N8N_SMTP_CREDENTIAL_ID" && -z "$N8N_SMTP_CREDENTIAL_NAME" ]]; then
      N8N_SMTP_CREDENTIAL_NAME="$(python3 - "$cred_file" "$N8N_SMTP_CREDENTIAL_ID" <<'PY'
import json, sys
p = json.load(open(sys.argv[1], "r", encoding="utf-8"))
cred_id = sys.argv[2]
data = p.get("data", p if isinstance(p, list) else [])
for c in data:
    if str(c.get("id", "")) == cred_id:
        print(c.get("name", "SMTP account"))
        break
PY
)"
    fi
  fi
fi

if [[ -n "$N8N_SMTP_CREDENTIAL_ID" ]]; then
  echo "[import] SMTP credential binding enabled (id=$N8N_SMTP_CREDENTIAL_ID)"
else
  echo "[import] WARN: no SMTP credential found; workflows with Send Email node may fail activation"
fi

shopt -s nullglob
workflow_files=("$WORKFLOWS_DIR"/*.json)
(( ${#workflow_files[@]} > 0 )) || { echo "[import] ERROR: no workflow JSON files found"; exit 1; }

for wf in "${workflow_files[@]}"; do
  payload_file="$tmp_dir/payload-$(basename "$wf")"

  workflow_name="$(python3 - "$wf" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    wf = json.load(f)
print(wf.get("name", ""))
PY
)"
  [[ -n "$workflow_name" ]] || { echo "[import] ERROR: workflow missing name: $wf"; exit 1; }

  python3 - "$wf" "$payload_file" "$N8N_SMTP_CREDENTIAL_ID" "$N8N_SMTP_CREDENTIAL_NAME" <<'PY'
import json, sys
src, dst, smtp_cred_id, smtp_cred_name = sys.argv[1:5]
with open(src, "r", encoding="utf-8") as f:
    wf = json.load(f)

payload = {
    "name": wf.get("name"),
    "nodes": wf.get("nodes", []),
    "connections": wf.get("connections", {}),
    "settings": wf.get("settings", {}),
}

if smtp_cred_id:
    for node in payload["nodes"]:
        if node.get("type") == "n8n-nodes-base.emailSend":
            creds = node.setdefault("credentials", {})
            creds["smtp"] = {
                "id": smtp_cred_id,
                "name": smtp_cred_name or "SMTP account"
            }

with open(dst, "w", encoding="utf-8") as f:
    json.dump(payload, f)
PY

  existing_id="$(python3 - "$list_file" "$workflow_name" <<'PY'
import json, sys
payload = json.load(open(sys.argv[1], "r", encoding="utf-8"))
name = sys.argv[2]
data = payload.get("data", payload if isinstance(payload, list) else [])
# Prefer non-archived workflow with matching name.
for w in data:
    if w.get("name") == name and not bool(w.get("isArchived")):
        print(w.get("id", ""))
        break
PY
)"

  if [[ -n "$existing_id" ]]; then
    echo "[import] Updating workflow: $workflow_name (id=$existing_id)"
    curl "${curl_common[@]}" -X PUT "$N8N_API_URL/workflows/$existing_id" --data @"$payload_file" >/dev/null
    wf_id="$existing_id"
  else
    echo "[import] Creating workflow: $workflow_name"
    create_file="$tmp_dir/create-$(basename "$wf").json"
    curl "${curl_common[@]}" -X POST "$N8N_API_URL/workflows" --data @"$payload_file" -o "$create_file"
    wf_id="$(python3 - "$create_file" <<'PY'
import json, sys
payload = json.load(open(sys.argv[1], "r", encoding="utf-8"))
if isinstance(payload, dict):
    if isinstance(payload.get("data"), dict):
        print(payload["data"].get("id", ""))
    elif isinstance(payload.get("data"), list) and payload["data"]:
        first = payload["data"][0]
        if isinstance(first, dict):
            print(first.get("id", ""))
    else:
        print(payload.get("id", ""))
PY
)"
    if [[ -z "$wf_id" ]]; then
      echo "[import] ERROR: could not read created workflow id for $workflow_name"
      echo "[import] Create response:"
      sed -n '1,30p' "$create_file" || true
      exit 1
    fi
  fi

  echo "[import] Activating workflow: $workflow_name (id=$wf_id)"
  # Force webhook re-registration cycle.
  curl "${curl_common[@]}" -X POST "$N8N_API_URL/workflows/$wf_id/deactivate" >/dev/null 2>&1 || true
  activate_resp="$tmp_dir/activate-$wf_id.json"
  activate_code="$(curl "${curl_common[@]}" -o "$activate_resp" -w "%{http_code}" -X POST "$N8N_API_URL/workflows/$wf_id/activate" || true)"

  # Fallback for older API behavior.
  if [[ ! "$activate_code" =~ ^2 ]]; then
    echo "[import] WARN: /activate returned HTTP $activate_code"
    echo "[import] WARN: activate response:"
    sed -n '1,20p' "$activate_resp" || true
    echo "[import] WARN: trying PUT active=true fallback"
    patch_resp="$tmp_dir/activate-patch-$wf_id.json"
    patch_code="$(curl "${curl_common[@]}" -o "$patch_resp" -w "%{http_code}" -X PUT "$N8N_API_URL/workflows/$wf_id" --data '{"active": true}' || true)"
    if [[ ! "$patch_code" =~ ^2 ]]; then
      echo "[import] WARN: PATCH returned HTTP $patch_code"
      echo "[import] WARN: patch response:"
      sed -n '1,20p' "$patch_resp" || true
    fi
  fi

  # Poll briefly to ensure active flag is visible before downstream discovery/smoke.
  active_ok=0
  for _ in 1 2 3 4 5; do
    state_file="$tmp_dir/state-$wf_id.json"
    curl "${curl_common[@]}" "$N8N_API_URL/workflows/$wf_id" -o "$state_file" >/dev/null
    is_active="$(python3 - "$state_file" <<'PY'
import json, sys
p = json.load(open(sys.argv[1], "r", encoding="utf-8"))
d = p.get("data", p if isinstance(p, dict) else {})
print("1" if bool(d.get("active")) else "0")
PY
)"
    if [[ "$is_active" == "1" ]]; then
      active_ok=1
      break
    fi
    sleep 1
  done

  if [[ "$active_ok" != "1" ]]; then
    echo "[import] ERROR: workflow did not become active: $workflow_name (id=$wf_id)"
    exit 1
  fi
done

echo "[import] PASS: workflows imported/updated and activated from release $RELEASE_ID"
