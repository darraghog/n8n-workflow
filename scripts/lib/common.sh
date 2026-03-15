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
  common::die "$tag" "target is required for prod"
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
  if [[ "$env" == "prod" ]]; then
    common::require_readable_file "$cert" "$tag" "HTTPS_CERT_FILE"
    common::require_readable_file "$key" "$tag" "HTTPS_KEY_FILE"
  fi
}

common::resolve_n8n_base_url() {
  local target="$1"
  if [[ "$target" == "local" ]]; then
    echo "https://127.0.0.1:8444"
  else
    echo "https://$target:8444"
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
  if [[ "$env" == "prod" ]]; then
    common::require_prod_tls "$env" "$cert" "$key" "$tag"
    out+=(--cert "$cert" --key "$key")
  else
    # Homelab/local certs are often self-signed.
    out+=(-k)
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
  local page=0
  local max_pages=40
  local -a page_files=()

  while (( page < max_pages )); do
    local sep='?'
    [[ "$endpoint" == *\?* ]] && sep='&'
    local page_url="${endpoint}${sep}limit=${limit}&offset=${offset}"
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

    page_files+=("$page_file")
    ((page += 1))

    if [[ "$count" =~ ^[0-9]+$ ]] && (( count < limit )); then
      break
    fi
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
