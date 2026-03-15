# Shakespeare Play Explorer (n8n)

An n8n workflow that lets users enter a Shakespeare play name, choose between key characters or human-centric themes, and receive a JSON-formatted result via email. Uses Ollama for local LLM responses.

## Prerequisites

- n8n instance (see [PROJECT-INSTRUCTIONS.md](PROJECT-INSTRUCTIONS.md) for homelab deployment)
- Ollama running on the host with a model (e.g. `ollama run llama3.2`)
- SMTP credentials for sending email

## Setup

1. **Import the workflow**

   - In n8n: Workflows → Import from File → select `workflows/shakespeare-play-explorer.json`

2. **Configure Send Email node**

   - Create SMTP credentials in n8n (Settings → Credentials)
   - Open the Send Email node and select your SMTP credential
   - Update the "From Email" address to your desired sender

3. **Configure Ollama connection**

   - With n8n in Docker/podman, Ollama on the host: the workflow uses `http://host.docker.internal:11434`
   - If n8n runs on the host: change the Ollama node URL to `http://localhost:11434`
   - Ensure a model is pulled: `ollama run llama3.2`

4. **Activate the workflow**

   - Save and activate. Use the Form Trigger’s Production URL to share the form.

## Form fields

| Field        | Description                                                              |
|-------------|----------------------------------------------------------------------------|
| Shakespeare Play | Play name (e.g. Hamlet, Macbeth, Romeo and Juliet)                       |
| What would you like? | Key Characters or Human-centric Themes                             |
| Your email   | Where to send the result                                                  |

## Output format

The workflow returns JSON suitable for web pages or email, e.g.:

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

## Credentials

See [docs/credentials.md](docs/credentials.md) for required credentials.

## Production standard

Use [docs/production-deployment-standard.md](docs/production-deployment-standard.md) as the source of truth for packaging, promotion, deployment, verification, and rollback.

## Production scripts

From project root:

```bash
# 1) Run required gates
./scripts/preflight.sh <env>

# 2) Build release artifact + manifest
./scripts/package-release.sh <env>

# 3) Deploy infra baseline and sync release bundle
./scripts/deploy-production.sh <env> [target] [release-id]

# 4) Roll back to a prior release if needed
./scripts/rollback-release.sh <env> [target] <release-id>

# 5) Webhook smoke test (auto-discovers URL via n8n API)
N8N_API_KEY=<api-key> ./scripts/smoke-test-webhook.sh <env> [target]

# 6) Import or upsert workflows from a release (usually called by deploy script)
./scripts/import-release.sh <env> [target] [release-id]
```

Examples:

```bash
# dev/test can default to localhost
./scripts/deploy-production.sh dev
./scripts/deploy-production.sh test local

# prod requires HTTPS credentials
HTTPS_CERT_FILE=/path/client-cert.pem HTTPS_KEY_FILE=/path/client-key.pem \
  ./scripts/deploy-production.sh prod <prod-hostname>

# webhook smoke with discovery (dev/test)
N8N_API_KEY=<api-key> \
SMOKE_PAYLOAD='{"play_name":"Hamlet","output_type":"Key Characters","email":"smoke@example.com"}' \
  ./scripts/smoke-test-webhook.sh test local

# optional: override workflow name used for discovery
N8N_API_KEY=<api-key> WORKFLOW_NAME="Shakespeare Play Explorer" \
  ./scripts/smoke-test-webhook.sh test
```

Automation note:
- `deploy-production.sh` now runs full flow automatically: infra deploy -> workflow import/update -> activation -> service smoke -> webhook smoke.
- Manual JSON upload in target n8n UI is no longer required.
- By default, webhook smoke failures are warnings; set `REQUIRE_WEBHOOK_SMOKE_PASS=1` to fail deployment on webhook smoke failure.

## Test harness

Run a local consistency harness for workflow structure and dataflow:

```bash
node tests/workflow-harness.mjs
```

What it validates:
- Required nodes and connections (Form -> Ollama + Merge -> Build Result -> Send Email)
- Canonical form fields (`play_name`, `output_type`, `email`)
- Send Email references `json_content`
- `Build Result` code behavior with mock form + Ollama inputs
