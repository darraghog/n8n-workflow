# Shakespeare Play Explorer (n8n)

Form in, Ollama JSON out, email only if the recipient is allowlisted.

n8n will not activate a Form Trigger and Respond to Webhook in the same workflow, so this is three workflows:

| Workflow | Trigger | Email |
|----------|---------|-------|
| **Shakespeare Play Explorer** | Form `/form/shakespeare-play-explorer` | Yes, if allowlisted and `SMTP_FROM_EMAIL` is set |
| **Shakespeare Play Explorer Eval** | `POST /webhook/shakespeare-play-explorer-test` | Never |
| **Shakespeare Play Explorer – Operator Errors** | Error Trigger | `OPERATOR_EMAIL` only |

Edit via `scripts/generate-main-workflow.py` (writes the form + eval JSON). Field contract: [docs/workflow-fields.md](docs/workflow-fields.md).

## Live URLs

| Env | Form | Eval webhook |
|-----|------|----------------|
| Local | http://127.0.0.1:5678/form/shakespeare-play-explorer | `POST /webhook/shakespeare-play-explorer-test` |
| Prod (beeblebox) | https://beeblebox.taile98462.ts.net/form/shakespeare-play-explorer | `POST https://beeblebox.taile98462.ts.net/webhook/shakespeare-play-explorer-test` |

Eval auth: header `X-Eval-Token` or JSON `eval_token`, matching `$env.EVAL_WEBHOOK_TOKEN`.

## Form fields

| Field | Description |
|-------|-------------|
| Shakespeare Play | Letters, numbers, spaces, `.,'-`; max 80 |
| What would you like? | Key Characters or Human-centric Themes |
| Your email | Must match `EMAIL_ALLOWLIST` or no mail is sent |

## Output

```json
{
  "play": "Hamlet",
  "requestType": "characters",
  "title": "Key Characters in Hamlet",
  "items": [
    { "name": "Hamlet", "description": "Prince of Denmark..." }
  ],
  "summary": "..."
}
```

Form emails include `request_id`, plain-text JSON, and an HTML table. The eval webhook returns `{ request_id, status, play_name, result, … }` and never includes `email`.

`status` is one of: `ok`, `validation_error`, `email_rejected`, `ollama_unavailable`, `parse_fail`, `schema_fail`, `groundedness_fail`.

## Runtime (n8n container env)

These must be inside the n8n process (`$env`). `localserver-config` `compose/n8n/compose.yaml` passes them through; `N8N_BLOCK_ENV_ACCESS_IN_NODE` must be `false`.

| Variable | Purpose |
|----------|---------|
| `SMTP_FROM_EMAIL` | From address; empty disables form mail |
| `OPERATOR_EMAIL` | Error-workflow recipient |
| `EMAIL_ALLOWLIST` | Exact emails and/or `@domain.com`. Empty denies all. `*` allows all (unsafe). |
| `EVAL_WEBHOOK_TOKEN` | Shared secret for the eval webhook |
| `OLLAMA_BASE_URL` | Default `http://host.docker.internal:11434` |
| `OLLAMA_MODEL` | Default `llama3.2` (use a tag that is **pulled on that host**) |

Create an SMTP credential in n8n (not in git). Import binds it with `N8N_SMTP_CREDENTIAL_ID` or `N8N_SMTP_CREDENTIAL_NAME`. Remote targets resolve **by name** — local credential ids do not exist on beeblebox.

See [docs/credentials.md](docs/credentials.md) and [.env.example](.env.example).

## Deploy

Packaging, promotion, and rollback: [docs/production-deployment-standard.md](docs/production-deployment-standard.md). Homelab n8n is the sibling repo `localserver-config`. Prod host is **beeblebox**.

```bash
./scripts/deploy-environment.sh dev
./scripts/deploy-environment.sh test local
./scripts/deploy-environment.sh prod beeblebox

./scripts/smoke-test.sh test local
EVAL_WEBHOOK_TOKEN=<token> ./scripts/smoke-test-webhook.sh test local

EVAL_WEBHOOK_URL=https://beeblebox.taile98462.ts.net/webhook/shakespeare-play-explorer-test \
EVAL_WEBHOOK_TOKEN=<token> \
  node evals/run.mjs
```

`./scripts/deploy-environment.sh` deploys infra via `localserver-config`, rsyncs the release, smokes `/healthz`, then imports/activates via the n8n REST API.

Prod import needs a **beeblebox** `N8N_API_KEY` (Settings → n8n API). The local key returns 401. Without it, import with `n8n import:workflow` on the host, then `publish:workflow` and restart n8n. Pull `$OLLAMA_MODEL` on that host (`ollama pull llama3.2`).

Webhook smoke is warn-only in `dev` and required in `test`/`prod` unless `REQUIRE_WEBHOOK_SMOKE_PASS` is set.

## Tests

```bash
node tests/workflow-harness.mjs
./scripts/preflight.sh test
bash scripts/secret-scan.sh
```

CI (`.github/workflows/ci.yml`) runs the harness, JSON parse of `workflows/*.json`, and the secret scan.
