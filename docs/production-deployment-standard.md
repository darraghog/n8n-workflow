# n8n Production Packaging and Deployment Standard

Standard for packaging, promoting, and deploying n8n workflows to production in the homelab Podman environment.

## 1) Scope

- Applies to all workflows stored in `workflows/*.json`.
- Applies to production deployment targets managed via Podman/podman-compose.
- Goal: deterministic promotion with rollback safety and auditable releases.

## 2) Release model

- Environments: `dev` -> `test` -> `prod`.
- Promote the same workflow artifact across environments (no manual UI edits in prod).
- Every production deployment uses a release ID: `YYYYMMDD-HHMM-<shortsha>`.

## 3) Packaging standard

Each release package must contain:

- `workflows/*.json` (versioned workflow exports)
- `docs/workflow-fields.md` (field contract)
- `docs/credentials.md` (credential requirements)
- `release-manifest.json` (metadata below)

### 3.1 Manifest schema

```json
{
  "release_id": "20260315-1545-a1b2c3d",
  "git_commit": "a1b2c3d4...",
  "workflows": [
    {
      "file": "workflows/shakespeare-play-explorer.json",
      "workflow_name": "Shakespeare Play Explorer",
      "version_note": "email alias mapping hardening"
    }
  ],
  "compatibility": {
    "n8n_min_version": "1.0.0",
    "podman_compose_required": true
  },
  "checks": {
    "workflow_harness": "pass",
    "json_parse": "pass"
  }
}
```

## 4) Required quality gates (pre-prod)

Before promoting to prod, all must pass:

1. `node tests/workflow-harness.mjs`
2. Workflow JSON parse check:
   - `python3 -m json.tool workflows/shakespeare-play-explorer.json >/dev/null`
3. Honest smoke (not UI 401):
   - n8n `/healthz` returns 2xx
   - Ollama `/api/tags` returns 2xx (required in test/prod)
   - Test webhook `POST /webhook/shakespeare-play-explorer-test` returns JSON with `request_id`, `status`, `result.{play,requestType,title,items,summary}` and does **not** send email
4. Recipient allowlist and `SMTP_FROM_EMAIL` / `OPERATOR_EMAIL` are set in n8n env
5. Optional live eval: `node evals/run.mjs` against the test webhook

Automation:

- Run `./scripts/preflight.sh <env>` to execute all required local gates.
- CI runs harness + JSON parse + secret-scan.

## 5) Production deployment procedure

### 5.1 Prepare

1. Tag release in git (optional but recommended).
2. Build/update `release-manifest.json`.
3. Confirm prod env file is current (`envs/prod.env` style if using deployment repo pattern).

### 5.2 Deploy

Use the existing deployment pipeline pattern:

```bash
# Operator entrypoint in this repo
./scripts/deploy-environment.sh <env> [target] [release-id]
```

Rules:

- `dev` and `test` may use `local` target (default if omitted).
- `prod` defaults to **beeblebox** (public URL `https://beeblebox.taile98462.ts.net`).
- Client TLS certs are optional for beeblebox Funnel. Set `HTTPS_REQUIRE_CLIENT_CERT=1` only if the target still uses mTLS.
- Pin SMTP credential binding explicitly:
  - `N8N_SMTP_CREDENTIAL_ID=<credential-id>` (recommended), or
  - `N8N_SMTP_CREDENTIAL_NAME=<exact-name>`
  Required in every environment (no “first SMTP credential” fallback).

Then import/update workflows in n8n from packaged JSON only.
This is automated by `scripts/import-release.sh` in deploy/rollback scripts.

Example invocations:

```bash
# test/local using latest packaged release
./scripts/deploy-environment.sh test

# test/local with explicit release
./scripts/deploy-environment.sh test local 20260315-1631-nogit

# prod (beeblebox Tailscale Funnel)
./scripts/deploy-environment.sh prod beeblebox 20260315-1631-nogit
```

### 5.3 Verify after deploy

- n8n `/healthz` returns **2xx** (homepage 401 is not health).
- Ollama `/api/tags` returns 2xx from the operator host (test/prod).
- Test webhook POST returns expected JSON keys; form GET is not sufficient.
- Optional: allowlisted form submission confirms downstream email delivery.
- Package checksum `*.tar.gz.sha256` is verified before deploy/rollback.

Automation:

- Service check: `./scripts/smoke-test.sh <env> [target]`
- Test webhook JSON check: `EVAL_WEBHOOK_TOKEN=<token> ./scripts/smoke-test-webhook.sh <env> [target]`
- Live evals: `EVAL_WEBHOOK_URL=<url> EVAL_WEBHOOK_TOKEN=<token> node evals/run.mjs`

Gating:

- `test` and `prod`: webhook smoke must pass (override with `REQUIRE_WEBHOOK_SMOKE_PASS=0`).
- `dev`: webhook smoke warnings do not fail deploy unless `REQUIRE_WEBHOOK_SMOKE_PASS=1`.

## 6) Rollback standard

Rollback must use a previous known-good workflow artifact:

1. Select prior release package and manifest.
2. Re-import previous `workflows/*.json` in n8n.
3. Re-activate previous version.
4. Run smoke test and confirm delivery.
5. Record rollback event with reason and timestamp.

Automation:

- Use `./scripts/rollback-release.sh <env> [target] <release-id>`.
- Writes an audit line to `dist/releases/AUDIT.log` (`ROLLBACK_REASON` optional).
- Re-verifies the release `sha256` when the checksum file is present.

Example:

```bash
./scripts/rollback-release.sh test local 20260315-1559-nogit
```

Do not hot-edit production workflow logic unless rollback is impossible.

## 7) Change control rules

- No direct/manual editing in production editor before export to git.
- Any field name changes must update:
  - workflow JSON
  - `docs/workflow-fields.md`
  - test harness assertions
- Credential changes must update `docs/credentials.md`.
- Every production change requires:
  - release manifest
  - test evidence (harness + smoke)

## 8) Security and secrets

- Never commit secrets (`.env`, SMTP passwords, encryption keys).
- Keep sender addresses and credential IDs environment-specific.
- Fail closed: empty `EMAIL_ALLOWLIST` sends no user email. Operator alerts go only to `OPERATOR_EMAIL`.
- Validate that exported workflow JSON contains no embedded secrets (`scripts/secret-scan.sh`).

## 9) Operational SLO checks (recommended)

- Deployment success rate: 100% of prod releases pass `/healthz` + test-webhook smoke.
- Time to rollback: < 15 minutes (checksummed artifact + audit line).
- Field contract regressions: 0 (guarded by harness).
- Eval: track `schema_fail` and `groundedness_fail` from `node evals/run.mjs`.
