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
3. Test environment execution:
   - Form submission succeeds
   - `Build Result` contains canonical fields:
     - `play_name`, `output_type`, `output_type_value`, `email`, `json_content`
   - `Send Email` succeeds with non-empty `toEmail`

Automation:

- Run `./scripts/preflight.sh <env>` to execute all required local gates.

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
- `prod` must provide HTTPS credentials via:
  - `HTTPS_CERT_FILE=/path/client-cert.pem`
  - `HTTPS_KEY_FILE=/path/client-key.pem`
- `prod` should pin SMTP credential binding explicitly:
  - `N8N_SMTP_CREDENTIAL_ID=<credential-id>` (recommended), or
  - `N8N_SMTP_CREDENTIAL_NAME=<exact-name>`

Then import/update workflows in n8n from packaged JSON only.
This is automated by `scripts/import-release.sh` in deploy/rollback scripts.

Example invocations:

```bash
# test/local using latest packaged release
./scripts/deploy-environment.sh test

# test/local with explicit release
./scripts/deploy-environment.sh test local 20260315-1631-nogit

# prod with client TLS credentials
HTTPS_CERT_FILE=/path/client-cert.pem HTTPS_KEY_FILE=/path/client-key.pem \
  ./scripts/deploy-environment.sh prod <prod-hostname> 20260315-1631-nogit
```

### 5.3 Verify after deploy

- n8n service healthy (`/healthz` on backend port).
- Workflow active and production form URL reachable.
- One webhook smoke submission returns expected JSON keys.
- Optional: full end-to-end submission confirms downstream email delivery.

Automation:

- Service check: `./scripts/smoke-test.sh <env> [target]`
- Webhook JSON check (auto-discovery): `N8N_API_KEY=<api-key> ./scripts/smoke-test-webhook.sh <env> [target]`

Discovery details:

- Script resolves workflow by `WORKFLOW_NAME` (default: `Shakespeare Play Explorer`)
- Reads Form Trigger path from `parameters.path` or `parameters.options.path`, fallback `webhookId`
- Builds URL as `https://<target>:8444/form/<path-or-webhookId>`
- Requires workflow to be active by default (`REQUIRE_ACTIVE_WORKFLOW=1`)

Operational note:

- `deploy-environment.sh` performs full automation: deploy stack, import/update workflows via API, activate workflows, then run service + webhook smoke tests.
- Form Trigger smoke verifies endpoint availability (`GET 2xx`) by default.
- For strict JSON webhook assertions, set `SMOKE_STRICT_JSON=1` and point to a JSON webhook endpoint.
- Shared script logic is centralized in `scripts/lib/common.sh`; helper scripts are implementation details behind deploy/rollback entrypoints.

## 6) Rollback standard

Rollback must use a previous known-good workflow artifact:

1. Select prior release package and manifest.
2. Re-import previous `workflows/*.json` in n8n.
3. Re-activate previous version.
4. Run smoke test and confirm delivery.
5. Record rollback event with reason and timestamp.

Automation:

- Use `./scripts/rollback-release.sh <env> [target] <release-id>`.

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
- Validate that exported workflow JSON contains no embedded secrets.

## 9) Operational SLO checks (recommended)

- Deployment success rate: 100% of prod releases pass smoke test.
- Time to rollback: < 15 minutes.
- Field contract regressions: 0 (guarded by harness).
