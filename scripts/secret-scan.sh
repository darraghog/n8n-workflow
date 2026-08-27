#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOWS_DIR="$ROOT/workflows"
failed=0

shopt -s nullglob
files=("$WORKFLOWS_DIR"/*.json)
(( ${#files[@]} > 0 )) || { echo "[secret-scan] ERROR: no workflow JSON files"; exit 1; }

for f in "${files[@]}"; do
  hits="$(python3 - "$f" <<'PY'
import json, re, sys
path = sys.argv[1]
raw = open(path, encoding="utf-8").read()
obj = json.loads(raw)
blob = json.dumps(obj)
patterns = [
    r"(?i)\"password\"\s*:\s*\"[^\"]+\"",
    r"(?i)\"api[_-]?key\"\s*:\s*\"[^\"]+\"",
    r"(?i)\"secret\"\s*:\s*\"[^\"]+\"",
    r"BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY",
]
for pat in patterns:
    if re.search(pat, blob):
        print(pat)
PY
)"
  if [[ -n "$hits" ]]; then
    echo "[secret-scan] FAIL $(basename "$f")"
    echo "$hits"
    failed=1
  else
    echo "[secret-scan] OK $(basename "$f")"
  fi
done

exit "$failed"
