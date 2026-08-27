#!/usr/bin/env bash

common::die() {
  local tag="$1"
  shift
  echo "[$tag] ERROR: $*" >&2
  exit 1
}

common::validate_environment() {
  local env="$1"
  local tag="$2"
  case "$env" in
    dev|test|prod) ;;
    *) common::die "$tag" "environment must be one of: dev, test, prod" ;;
  esac
}

common::resolve_target() {
  local env="$1"
  local target="${2:-}"
  local tag="$3"
  if [[ -n "$target" ]]; then
    echo "$target"
    return 0
  fi
  if [[ "$env" == "dev" || "$env" == "test" ]]; then
    echo "local"
    return 0
  fi
  echo "${PROD_TARGET:-beeblebox}"
}

common::resolve_public_host() {
  local target="$1"
  case "$target" in
    local) echo "127.0.0.1" ;;
    beeblebox) echo "beeblebox.taile98462.ts.net" ;;
    *) echo "$target" ;;
  esac
}

common::load_project_env() {
  local root="$1"
  if [[ -f "$root/.env" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$root/.env"
    set +a
  fi
}

common::require_readable_file() {
  local path="$1"
  local tag="$2"
  local label="$3"
  [[ -n "$path" ]] || common::die "$tag" "$label is not set"
  [[ -r "$path" ]] || common::die "$tag" "cannot read $label: $path"
}

common::require_prod_tls() {
  local env="$1"
  local cert="$2"
  local key="$3"
  local tag="$4"
  if [[ -n "$cert" || -n "$key" ]]; then
    common::require_readable_file "$cert" "$tag" "HTTPS_CERT_FILE"
    common::require_readable_file "$key" "$tag" "HTTPS_KEY_FILE"
  elif [[ "$env" == "prod" && "${HTTPS_REQUIRE_CLIENT_CERT:-0}" == "1" ]]; then
    common::die "$tag" "HTTPS_CERT_FILE and HTTPS_KEY_FILE are required when HTTPS_REQUIRE_CLIENT_CERT=1"
  fi
}

common::resolve_n8n_base_url() {
  local target="$1"
  local host
  local override="${N8N_BASE_URL:-${N8N_PUBLIC_BASE_URL:-}}"
  # Loopback overrides are for local operator use; never apply them to remote targets.
  if [[ -n "$override" ]]; then
    if [[ "$target" == "local" ]] || [[ ! "$override" =~ 127\.0\.0\.1|localhost ]]; then
      echo "${override%/}"
      return 0
    fi
  fi
  host="$(common::resolve_public_host "$target")"
  if [[ "$host" == "beeblebox.taile98462.ts.net" ]]; then
    echo "https://beeblebox.taile98462.ts.net"
  elif [[ "$target" == "local" ]]; then
    echo "https://127.0.0.1:8444"
  else
    echo "https://$host:8444"
  fi
}

common::resolve_n8n_api_url() {
  local target="$1"
  local override="${2:-}"
  if [[ -n "$override" ]]; then
    echo "$override"
  else
    echo "$(common::resolve_n8n_base_url "$target")/api/v1"
  fi
}

common::map_infra_environment() {
  local env="$1"
  if [[ "$env" == "dev" || "$env" == "test" ]]; then
    echo "local"
  else
    echo "$env"
  fi
}

common::build_tls_curl_args() {
  local env="$1"
  local cert="$2"
  local key="$3"
  local tag="$4"
  local out_var="$5"
  local -n out="$out_var"
  out=()
  if [[ -n "$cert" && -n "$key" ]]; then
    common::require_readable_file "$cert" "$tag" "HTTPS_CERT_FILE"
    common::require_readable_file "$key" "$tag" "HTTPS_KEY_FILE"
    out+=(--cert "$cert" --key "$key")
  elif [[ "$env" == "prod" ]]; then
    : # public Tailscale Funnel — verify server TLS
  else
    # Homelab/local certs are often self-signed.
    out+=(-k)
  fi
}

common::webhook_smoke_required() {
  local env="$1"
  if [[ -n "${REQUIRE_WEBHOOK_SMOKE_PASS:-}" ]]; then
    echo "$REQUIRE_WEBHOOK_SMOKE_PASS"
    return 0
  fi
  if [[ "$env" == "dev" ]]; then
    echo "0"
  else
    echo "1"
  fi
}

common::verify_release_checksum() {
  local archive="$1"
  local tag="$2"
  local dir base
  dir="$(dirname "$archive")"
  base="$(basename "$archive")"
  [[ -f "$archive" ]] || common::die "$tag" "missing release archive: $archive"
  [[ -f "$dir/$base.sha256" ]] || common::die "$tag" "missing checksum file: $dir/$base.sha256"
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$dir" && sha256sum -c "$base.sha256" --quiet) || common::die "$tag" "checksum mismatch for $archive"
  else
    (cd "$dir" && shasum -a 256 -c "$base.sha256" --quiet) || common::die "$tag" "checksum mismatch for $archive"
  fi
}

common::fetch_paginated_collection() {
  local endpoint="$1"
  local limit="$2"
  local output_file="$3"
  local curl_args_name="$4"
  local tag="$5"
  local -n curl_args="$curl_args_name"

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  local offset=0
  local cursor=""
  local page=0
  local max_pages=40
  local -a page_files=()

  while (( page < max_pages )); do
    local sep='?'
    [[ "$endpoint" == *\?* ]] && sep='&'
    local page_url="${endpoint}${sep}limit=${limit}"
    if [[ -n "$cursor" ]]; then
      page_url="${page_url}&cursor=${cursor}"
    elif (( offset > 0 )); then
      page_url="${page_url}&offset=${offset}"
    fi
    local page_file="$tmp_dir/page-$page.json"

    if ! curl "${curl_args[@]}" "$page_url" -o "$page_file"; then
      rm -rf "$tmp_dir"
      common::die "$tag" "failed to fetch $page_url"
    fi

    local count
    count="$(python3 - "$page_file" <<'PY'
import json, sys
payload = json.load(open(sys.argv[1], "r", encoding="utf-8"))
if isinstance(payload, dict):
    data = payload.get("data")
    if isinstance(data, list):
        print(len(data))
    elif isinstance(payload.get("items"), list):
        print(len(payload["items"]))
    else:
        print(0)
elif isinstance(payload, list):
    print(len(payload))
else:
    print(0)
PY
)"

    local next_cursor
    next_cursor="$(python3 - "$page_file" <<'PY'
import json, sys
payload = json.load(open(sys.argv[1], "r", encoding="utf-8"))
if isinstance(payload, dict) and payload.get("nextCursor"):
    print(str(payload.get("nextCursor")))
PY
)"

    page_files+=("$page_file")
    ((page += 1))

    if [[ -n "$next_cursor" ]]; then
      cursor="$next_cursor"
      continue
    fi

    if [[ "$count" =~ ^[0-9]+$ ]] && (( count < limit )); then
      break
    fi
    cursor=""
    (( offset += limit ))
  done

  python3 - "$output_file" "${page_files[@]}" <<'PY'
import json, sys
out_path = sys.argv[1]
files = sys.argv[2:]

items = []
seen = set()
for p in files:
    payload = json.load(open(p, "r", encoding="utf-8"))
    if isinstance(payload, dict):
        data = payload.get("data")
        if isinstance(data, list):
            entries = data
        elif isinstance(payload.get("items"), list):
            entries = payload["items"]
        else:
            entries = []
    elif isinstance(payload, list):
        entries = payload
    else:
        entries = []

    for item in entries:
        if isinstance(item, dict):
            key = item.get("id")
            if key is not None and key in seen:
                continue
            if key is not None:
                seen.add(key)
        items.append(item)

json.dump({"data": items}, open(out_path, "w", encoding="utf-8"))
PY

  rm -rf "$tmp_dir"
}
