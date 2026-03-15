#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT/dist/releases"
mkdir -p "$DIST_DIR"
ENVIRONMENT="${1:-dev}"

case "$ENVIRONMENT" in
  dev|test|prod) ;;
  *) echo "[package] ERROR: environment must be one of: dev, test, prod"; exit 1 ;;
esac

SHORT_SHA="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || true)"
if [[ -z "$SHORT_SHA" ]]; then
  SHORT_SHA="nogit"
fi

RELEASE_ID="${2:-$(date +%Y%m%d-%H%M)-$SHORT_SHA}"
OUT_DIR="$DIST_DIR/$RELEASE_ID"
mkdir -p "$OUT_DIR/workflows" "$OUT_DIR/docs"

echo "[package] Running preflight checks..."
"$ROOT/scripts/preflight.sh" "$ENVIRONMENT"

echo "[package] Copying artifacts..."
cp "$ROOT"/workflows/*.json "$OUT_DIR/workflows/"
cp "$ROOT/docs/workflow-fields.md" "$OUT_DIR/docs/"
cp "$ROOT/docs/credentials.md" "$OUT_DIR/docs/"
cp "$ROOT/docs/production-deployment-standard.md" "$OUT_DIR/docs/"

echo "[package] Building release-manifest.json..."
python3 - "$ROOT" "$OUT_DIR" "$RELEASE_ID" "$SHORT_SHA" "$ENVIRONMENT" <<'PY'
import json
import os
import sys
from pathlib import Path

root = Path(sys.argv[1])
out_dir = Path(sys.argv[2])
release_id = sys.argv[3]
short_sha = sys.argv[4]
environment = sys.argv[5]

workflow_entries = []
for wf_path in sorted((root / "workflows").glob("*.json")):
    with wf_path.open("r", encoding="utf-8") as f:
        wf = json.load(f)
    workflow_entries.append({
        "file": f"workflows/{wf_path.name}",
        "workflow_name": wf.get("name", wf_path.stem),
        "version_note": "packaged release artifact"
    })

manifest = {
    "release_id": release_id,
    "git_commit": short_sha,
    "environment": environment,
    "workflows": workflow_entries,
    "compatibility": {
        "n8n_min_version": "1.0.0",
        "podman_compose_required": True
    },
    "checks": {
        "workflow_harness": "pass",
        "json_parse": "pass"
    }
}

with (out_dir / "release-manifest.json").open("w", encoding="utf-8") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")
PY

echo "$RELEASE_ID" > "$DIST_DIR/LATEST"
tar -czf "$DIST_DIR/$RELEASE_ID.tar.gz" -C "$DIST_DIR" "$RELEASE_ID"

echo "[package] PASS"
echo "[package] Release ID: $RELEASE_ID"
echo "[package] Directory: $OUT_DIR"
echo "[package] Archive: $DIST_DIR/$RELEASE_ID.tar.gz"
